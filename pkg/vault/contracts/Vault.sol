// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import { Proxy } from "@openzeppelin/contracts/proxy/Proxy.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IAuthorizer } from "@balancer-labs/v3-interfaces/contracts/vault/IAuthorizer.sol";
import { IVaultAdmin } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import { IVaultExtension } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultExtension.sol";
import { IVaultMain } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultMain.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IPoolHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IPoolHooks.sol";
import { IPoolLiquidity } from "@balancer-labs/v3-interfaces/contracts/vault/IPoolLiquidity.sol";
import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/vault/IRateProvider.sol";

import { BasePoolMath } from "@balancer-labs/v3-solidity-utils/contracts/math/BasePoolMath.sol";
import { EVMCallModeHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/EVMCallModeHelpers.sol";
import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ArrayHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { EnumerableMap } from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/EnumerableMap.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BasePoolMath } from "@balancer-labs/v3-solidity-utils/contracts/math/BasePoolMath.sol";

import { PoolConfigBits, PoolConfigLib } from "./lib/PoolConfigLib.sol";
import { PackedTokenBalance } from "./lib/PackedTokenBalance.sol";
import { VaultCommon } from "./VaultCommon.sol";

contract Vault is IVaultMain, VaultCommon, Proxy {
    using EnumerableMap for EnumerableMap.IERC20ToBytes32Map;
    using PackedTokenBalance for bytes32;
    using InputHelpers for uint256;
    using FixedPoint for *;
    using ArrayHelpers for uint256[];
    using Address for *;
    using SafeERC20 for IERC20;
    using SafeCast for *;
    using PoolConfigLib for PoolConfig;
    using ScalingHelpers for *;

    constructor(IVaultExtension vaultExtension, IAuthorizer authorizer) {
        if (address(vaultExtension.vault()) != address(this)) {
            revert WrongVaultExtensionDeployment();
        }

        _vaultExtension = vaultExtension;

        _vaultPauseWindowEndTime = IVaultAdmin(address(vaultExtension)).getPauseWindowEndTime();
        _vaultBufferPeriodDuration = IVaultAdmin(address(vaultExtension)).getBufferPeriodDuration();
        _vaultBufferPeriodEndTime = IVaultAdmin(address(vaultExtension)).getBufferPeriodEndTime();

        _authorizer = authorizer;
    }

    /*******************************************************************************
                              Transient Accounting
    *******************************************************************************/

    /**
     * @dev This modifier is used for functions that temporarily modify the `_tokenDeltas`
     * of the Vault but expect to revert or settle balances by the end of their execution.
     * It works by tracking the lockers involved in the execution and ensures that the
     * balances are properly settled by the time the last locker is executed.
     *
     * This is useful for functions like `lock`, which perform arbitrary external calls:
     * we can keep track of temporary deltas changes, and make sure they are settled by the
     * time the external call is complete.
     */
    modifier transient() {
        // Add the current locker to the list
        _lockers.push(msg.sender);

        // The caller does everything here and has to settle all outstanding balances
        _;

        // Check if it's the last locker
        if (_lockers.length == 1) {
            // Ensure all balances are settled
            if (_nonzeroDeltaCount != 0) revert BalanceNotSettled();

            // Reset the lockers list
            delete _lockers;

            // Reset the counter
            delete _nonzeroDeltaCount;
        } else {
            // If it's not the last locker, simply remove it from the list
            _lockers.pop();
        }
    }

    /// @inheritdoc IVaultMain
    function lock(bytes calldata data) external payable transient returns (bytes memory result) {
        // Executes the function call with value to the msg.sender.
        return (msg.sender).functionCallWithValue(data, msg.value);
    }

    /// @inheritdoc IVaultMain
    function settle(IERC20 token) public nonReentrant withLocker returns (uint256 paid) {
        uint256 reservesBefore = _tokenReserves[token];
        _tokenReserves[token] = token.balanceOf(address(this));
        paid = _tokenReserves[token] - reservesBefore;
        // subtraction must be safe
        _supplyCredit(token, paid, msg.sender);
    }

    /// @inheritdoc IVaultMain
    function sendTo(IERC20 token, address to, uint256 amount) public nonReentrant withLocker {
        // effects
        _takeDebt(token, amount, msg.sender);
        _tokenReserves[token] -= amount;
        // interactions
        token.safeTransfer(to, amount);
    }

    /// @inheritdoc IVaultMain
    function takeFrom(IERC20 token, address from, uint256 amount) public nonReentrant withLocker onlyTrustedRouter {
        // effects
        _supplyCredit(token, amount, msg.sender);
        _tokenReserves[token] += amount;
        // interactions
        token.safeTransferFrom(from, address(this), amount);
    }

    /*******************************************************************************
                                    Pool Operations
    *******************************************************************************/

    // The Vault performs all upscaling and downscaling (due to token decimals, rates, etc.), so that the pools
    // don't have to. However, scaling inevitably leads to rounding errors, so we take great care to ensure that
    // any rounding errors favor the Vault. An important invariant of the system is that there is no repeatable
    // path where tokensOut > tokensIn.
    //
    // In general, this means rounding up any values entering the Vault, and rounding down any values leaving
    // the Vault, so that external users either pay a little extra or receive a little less in the case of a
    // rounding error.
    //
    // However, it's not always straightforward to determine the correct rounding direction, given the presence
    // and complexity of intermediate steps. An "amountIn" sounds like it should be rounded up: but only if that
    // is the amount actually being transferred. If instead it is an amount sent to the pool math, where rounding
    // up would result in a *higher* calculated amount out, that would favor the user instead of the Vault. So in
    // that case, amountIn should be rounded down.
    //
    // See comments justifying the rounding direction in each case.
    //
    // TODO: this reasoning applies to Weighted Pool math, and is likely to apply to others as well, but of course
    // it's possible a new pool type might not conform. Duplicate the tests for new pool types (e.g., Stable Math).
    // Also, the final code should ensure that we are not relying entirely on the rounding directions here,
    // but have enough additional layers (e.g., minimum amounts, buffer wei on all transfers) to guarantee safety,
    // even if it turns out these directions are incorrect for a new pool type.

    /*******************************************************************************
                                          Swaps
    *******************************************************************************/

    struct SwapLocals {
        // Inline the shared struct fields vs. nesting, trading off verbosity for gas/memory/bytecode savings.
        uint256 indexIn;
        uint256 indexOut;
        uint256 tokenInBalance;
        uint256 tokenOutBalance;
        uint256 amountGivenScaled18;
        uint256 amountCalculatedScaled18;
        uint256 swapFeeAmountScaled18;
        uint256 swapFeePercentage;
        uint256 protocolSwapFeeAmountRaw;
        IBasePool.SwapParams poolSwapParams;
    }

    /// @inheritdoc IVaultMain
    function swap(
        SwapParams memory params
    )
        public
        withLocker
        withInitializedPool(params.pool)
        whenPoolNotPaused(params.pool)
        returns (uint256 amountCalculated, uint256 amountIn, uint256 amountOut)
    {
        if (params.amountGivenRaw == 0) {
            revert AmountGivenZero();
        }

        if (params.tokenIn == params.tokenOut) {
            revert CannotSwapSameToken();
        }

        // Fill in the PoolData structure, writing to the raw and last live balance storage, as well as protocol fees
        // storage, if yield fees are due. Since the swap callbacks are reentrant and could do anything, including
        // change these balances, we cannot simply store the pending yield fees (and balance changes) in the poolData
        // struct, to be settled in non-reentrant _swap with the rest of the accounting.
        PoolData memory poolData = _computePoolDataUpdatingBalancesAndFees(params.pool, Rounding.ROUND_DOWN);

        // if the sender is the buffer pool, swaps are allowed as this is part of the rebalance mechanism.
        if (
            poolData.poolConfig.isBufferPool &&
            _wrappedTokenBuffers[IERC4626(address(poolData.tokenConfig[0].token))] != msg.sender
        ) {
            revert CannotSwapWithBufferPool(params.pool);
        }

        // Use the storage map only for translating token addresses to indices. Raw balances can be read from poolData.
        EnumerableMap.IERC20ToBytes32Map storage poolBalances = _poolTokenBalances[params.pool];
        SwapLocals memory vars;

        // EnumerableMap stores indices *plus one* to use the zero index as a sentinel value for non-existence.
        vars.indexIn = poolBalances.unchecked_indexOf(params.tokenIn);
        vars.indexOut = poolBalances.unchecked_indexOf(params.tokenOut);

        // If either are zero, revert because the token wasn't registered to this pool.
        if (vars.indexIn == 0 || vars.indexOut == 0) {
            // We require the pool to be initialized, which means it's also registered.
            // This can only happen if the tokens are not registered.
            revert TokenNotRegistered();
        }

        // Convert to regular 0-based indices now, since we've established the tokens are valid.
        unchecked {
            vars.indexIn -= 1;
            vars.indexOut -= 1;
        }

        vars.tokenInBalance = poolData.balancesRaw[vars.indexIn];
        vars.tokenOutBalance = poolData.balancesRaw[vars.indexOut];

        // If the amountGiven is entering the pool math (ExactIn), round down, since a lower apparent amountIn leads
        // to a lower calculated amountOut, favoring the pool.
        _updateAmountGivenInVars(vars, params, poolData);

        vars.swapFeePercentage = _getSwapFeePercentage(poolData.poolConfig);

        if (vars.swapFeePercentage > 0 && params.kind == SwapKind.EXACT_OUT) {
            // Round up to avoid losses during precision loss.
            vars.swapFeeAmountScaled18 =
                vars.amountGivenScaled18.divUp(vars.swapFeePercentage.complement()) -
                vars.amountGivenScaled18;
        }

        // Create the pool hook params (used for both beforeSwap, if required, and the main swap hooks).
        // Function and inclusion in SwapLocals needed to avoid "stack too deep".
        vars.poolSwapParams = _buildSwapHookParams(params, vars, poolData);

        if (poolData.poolConfig.hooks.shouldCallBeforeSwap) {
            if (IPoolHooks(params.pool).onBeforeSwap(vars.poolSwapParams) == false) {
                revert BeforeSwapHookFailed();
            }

            _updatePoolDataLiveBalancesAndRates(poolData, Rounding.ROUND_DOWN);
            // The call to _buildSwapHookParams also modifies poolSwapParams.balancesScaled18.
            // Set here again explicitly to avoid relying on a side effect.
            // TODO: ugliness necessitated by the stack issues; revisit on any refactor to see if this can be cleaner.
            vars.poolSwapParams.balancesScaled18 = poolData.balancesLiveScaled18;

            // Also update amountGivenScaled18, as it will now be used in the swap, and the rates might have changed.
            _updateAmountGivenInVars(vars, params, poolData);
            vars.poolSwapParams.amountGivenScaled18 = vars.amountGivenScaled18;
        }

        // Non-reentrant call that updates accounting.
        (amountCalculated, amountIn, amountOut) = _swap(params, vars, poolData);

        if (poolData.poolConfig.hooks.shouldCallAfterSwap) {
            // Adjust balances for the AfterSwap hook.
            (uint256 amountInScaled18, uint256 amountOutScaled18) = params.kind == SwapKind.EXACT_IN
                ? (vars.amountGivenScaled18, vars.amountCalculatedScaled18)
                : (vars.amountCalculatedScaled18, vars.amountGivenScaled18);
            if (
                IPoolHooks(params.pool).onAfterSwap(
                    IPoolHooks.AfterSwapParams({
                        kind: params.kind,
                        tokenIn: params.tokenIn,
                        tokenOut: params.tokenOut,
                        amountInScaled18: amountInScaled18,
                        amountOutScaled18: amountOutScaled18,
                        tokenInBalanceScaled18: poolData.balancesLiveScaled18[vars.indexIn],
                        tokenOutBalanceScaled18: poolData.balancesLiveScaled18[vars.indexOut],
                        sender: msg.sender,
                        userData: params.userData
                    }),
                    vars.amountCalculatedScaled18
                ) == false
            ) {
                revert AfterSwapHookFailed();
            }
        }

        // Swap fee is always deducted from tokenOut.
        // Since the swapFeeAmountScaled18 (derived from scaling up either the amountGiven or amountCalculated)
        // also contains the rate, undo it when converting to raw.
        uint256 swapFeeAmountRaw = vars.swapFeeAmountScaled18.toRawUndoRateRoundDown(
            poolData.decimalScalingFactors[vars.indexOut],
            poolData.tokenRates[vars.indexOut]
        );

        emit Swap(params.pool, params.tokenIn, params.tokenOut, amountIn, amountOut, swapFeeAmountRaw);
    }

    function _buildSwapHookParams(
        SwapParams memory params,
        SwapLocals memory vars,
        PoolData memory poolData
    ) private view returns (IBasePool.SwapParams memory) {
        return
            IBasePool.SwapParams({
                kind: params.kind,
                amountGivenScaled18: vars.amountGivenScaled18 + vars.swapFeeAmountScaled18,
                balancesScaled18: poolData.balancesLiveScaled18,
                indexIn: vars.indexIn,
                indexOut: vars.indexOut,
                sender: msg.sender,
                userData: params.userData
            });
    }

    /// @dev Mutates `amountGivenScaled18` in vars, given the swap `params` and current rates in `poolData`.
    function _updateAmountGivenInVars(
        SwapLocals memory vars,
        SwapParams memory params,
        PoolData memory poolData
    ) private pure {
        vars.amountGivenScaled18 = params.kind == SwapKind.EXACT_IN
            ? params.amountGivenRaw.toScaled18ApplyRateRoundDown(
                poolData.decimalScalingFactors[vars.indexIn],
                poolData.tokenRates[vars.indexIn]
            )
            : params.amountGivenRaw.toScaled18ApplyRateRoundUp(
                poolData.decimalScalingFactors[vars.indexOut],
                poolData.tokenRates[vars.indexOut]
            );
    }

    /// @dev Non-reentrant portion of the swap, which calls the main hook and updates accounting.
    function _swap(
        SwapParams memory vaultSwapParams,
        SwapLocals memory vars,
        PoolData memory poolData
    ) internal nonReentrant returns (uint256 amountCalculated, uint256 amountIn, uint256 amountOut) {
        // Add swap fee to the amountGiven to account for the fee taken in EXACT_OUT swap on tokenOut
        // Perform the swap request hook and compute the new balances for 'token in' and 'token out' after the swap
        // If it's an ExactIn swap, vars.swapFeeAmountScaled18 will be zero here, and set based on the amountCalculated.

        vars.amountCalculatedScaled18 = IBasePool(vaultSwapParams.pool).onSwap(vars.poolSwapParams);

        if (vars.swapFeePercentage > 0 && vaultSwapParams.kind == SwapKind.EXACT_IN) {
            // Swap fee is a percentage of the amountCalculated for the EXACT_IN swap
            // Round up to avoid losses during precision loss.
            vars.swapFeeAmountScaled18 = vars.amountCalculatedScaled18.mulUp(vars.swapFeePercentage);
            // Should subtract the fee from the amountCalculated for EXACT_IN swap
            vars.amountCalculatedScaled18 -= vars.swapFeeAmountScaled18;
        }

        if (vaultSwapParams.kind == SwapKind.EXACT_IN) {
            // For `ExactIn` the amount calculated is leaving the Vault, so we round down.
            amountCalculated = vars.amountCalculatedScaled18.toRawUndoRateRoundDown(
                poolData.decimalScalingFactors[vars.indexOut],
                poolData.tokenRates[vars.indexOut]
            );
            (amountIn, amountOut) = (vaultSwapParams.amountGivenRaw, amountCalculated);

            if (amountOut < vaultSwapParams.limitRaw) {
                revert SwapLimit(amountOut, vaultSwapParams.limitRaw);
            }
        } else {
            // Round up when entering the Vault on `ExactOut`.
            amountCalculated = vars.amountCalculatedScaled18.toRawUndoRateRoundUp(
                poolData.decimalScalingFactors[vars.indexIn],
                poolData.tokenRates[vars.indexIn]
            );
            (amountIn, amountOut) = (amountCalculated, vaultSwapParams.amountGivenRaw);

            if (amountIn > vaultSwapParams.limitRaw) {
                revert SwapLimit(amountIn, vaultSwapParams.limitRaw);
            }
        }

        // Compute and charge protocol fees
        vars.protocolSwapFeeAmountRaw = _computeAndChargeProtocolFees(
            poolData,
            vars.swapFeeAmountScaled18,
            vaultSwapParams.pool,
            vaultSwapParams.tokenOut,
            vars.indexOut
        );

        poolData.balancesRaw[vars.indexIn] = vars.tokenInBalance + amountIn;
        poolData.balancesRaw[vars.indexOut] = vars.tokenOutBalance - amountOut - vars.protocolSwapFeeAmountRaw;

        // Set both raw and last live balances.
        _setPoolBalances(vaultSwapParams.pool, poolData);

        // Account amountIn of tokenIn
        _takeDebt(vaultSwapParams.tokenIn, amountIn, msg.sender);
        // Account amountOut of tokenOut
        _supplyCredit(vaultSwapParams.tokenOut, amountOut, msg.sender);
    }

    /// @dev Returns swap fee for the pool.
    function _getSwapFeePercentage(PoolConfig memory config) internal pure returns (uint256) {
        if (config.hasDynamicSwapFee) {
            // TODO: Fetch dynamic swap fee from the pool using hook
            return 0;
        } else {
            return config.staticSwapFeePercentage;
        }
    }

    /*******************************************************************************
                            Pool Registration and Initialization
    *******************************************************************************/

    /**
     * @notice Fetches the balances for a given pool, with decimal and rate scaling factors applied.
     * @dev Utilizes an enumerable map to obtain pool tokens and raw balances.
     * The function is structured to minimize storage reads by leveraging the `unchecked_at` method.
     * It is typically called after a reentrant callback (e.g., a "before" liquidity operation callback),
     * to refresh the poolData struct with any balances (or rates) that might have changed.
     *
     * @param poolData The corresponding poolData to be read and updated
     * @param roundingDirection Whether balance scaling should round up or down
     */
    function _updatePoolDataLiveBalancesAndRates(PoolData memory poolData, Rounding roundingDirection) internal view {
        _updateTokenRatesInPoolData(poolData);

        for (uint256 i = 0; i < poolData.tokenConfig.length; ++i) {
            _updateLiveTokenBalanceInPoolData(poolData, roundingDirection, i);
        }
    }

    /*******************************************************************************
                                Pool Operations
    *******************************************************************************/

    /// @dev Rejects routers not approved by governance and users
    modifier onlyTrustedRouter() {
        _onlyTrustedRouter(msg.sender);
        _;
    }

    /// @inheritdoc IVaultMain
    function addLiquidity(
        AddLiquidityParams memory params
    )
        external
        withLocker
        withInitializedPool(params.pool)
        whenPoolNotPaused(params.pool)
        returns (uint256[] memory amountsIn, uint256 bptAmountOut, bytes memory returnData)
    {
        // Round balances up when adding liquidity:
        // If proportional, higher balances = higher proportional amountsIn, favoring the pool.
        // If unbalanced, higher balances = lower invariant ratio with fees.
        // bptOut = supply * (ratio - 1), so lower ratio = less bptOut, favoring the pool.
        PoolData memory poolData = _computePoolDataUpdatingBalancesAndFees(params.pool, Rounding.ROUND_UP);
        InputHelpers.ensureInputLengthMatch(poolData.tokenConfig.length, params.maxAmountsIn.length);

        // Amounts are entering pool math, so round down.
        // Introducing amountsInScaled18 here and passing it through to _addLiquidity is not ideal,
        // but it avoids the even worse options of mutating amountsIn inside AddLiquidityParams,
        // or cluttering the AddLiquidityParams interface by adding amountsInScaled18.
        uint256[] memory maxAmountsInScaled18 = params.maxAmountsIn.copyToScaled18ApplyRateRoundDownArray(
            poolData.decimalScalingFactors,
            poolData.tokenRates
        );

        if (poolData.poolConfig.hooks.shouldCallBeforeAddLiquidity) {
            if (
                IPoolHooks(params.pool).onBeforeAddLiquidity(
                    params.to,
                    params.kind,
                    maxAmountsInScaled18,
                    params.minBptAmountOut,
                    poolData.balancesLiveScaled18,
                    params.userData
                ) == false
            ) {
                revert BeforeAddLiquidityHookFailed();
            }

            // The hook might alter the balances, so we need to read them again to ensure that the data is
            // fresh moving forward.
            // We also need to upscale (adding liquidity, so round up) again.
            _updatePoolDataLiveBalancesAndRates(poolData, Rounding.ROUND_UP);

            // Also update maxAmountsInScaled18, as the rates might have changed.
            maxAmountsInScaled18 = params.maxAmountsIn.copyToScaled18ApplyRateRoundDownArray(
                poolData.decimalScalingFactors,
                poolData.tokenRates
            );
        }

        // The bulk of the work is done here: the corresponding Pool hook is called, and the final balances
        // are computed. This function is non-reentrant, as it performs the accounting updates.
        // Note that poolData is mutated to update the Raw and Live balances, so they are accurate when passed
        // into the AfterAddLiquidity hook.
        // `amountsInScaled18` will be overwritten in the custom case, so we need to pass it back and forth to
        // encapsulate that logic in `_addLiquidity`.
        uint256[] memory amountsInScaled18;
        (amountsIn, amountsInScaled18, bptAmountOut, returnData) = _addLiquidity(
            poolData,
            params,
            maxAmountsInScaled18
        );

        if (poolData.poolConfig.hooks.shouldCallAfterAddLiquidity) {
            if (
                IPoolHooks(params.pool).onAfterAddLiquidity(
                    params.to,
                    amountsInScaled18,
                    bptAmountOut,
                    poolData.balancesLiveScaled18,
                    params.userData
                ) == false
            ) {
                revert AfterAddLiquidityHookFailed();
            }
        }
    }

    /**
     * @dev Calls the appropriate pool hook and calculates the required inputs and outputs for the operation
     * considering the given kind, and updates the vault's internal accounting. This includes:
     * - Setting pool balances
     * - Taking debt from the liquidity provider
     * - Minting pool tokens
     * - Emitting events
     *
     * It is non-reentrant, as it performs external calls and updates the vault's state accordingly. This is the only
     * place where the state is updated within `addLiquidity`.
     */
    function _addLiquidity(
        PoolData memory poolData,
        AddLiquidityParams memory params,
        uint256[] memory maxAmountsInScaled18
    )
        internal
        nonReentrant
        returns (
            uint256[] memory amountsInRaw,
            uint256[] memory amountsInScaled18,
            uint256 bptAmountOut,
            bytes memory returnData
        )
    {
        uint256 numTokens = poolData.tokenConfig.length;

        uint256[] memory swapFeeAmountsScaled18;
        if (params.kind == AddLiquidityKind.UNBALANCED) {
            amountsInScaled18 = maxAmountsInScaled18;
            (bptAmountOut, swapFeeAmountsScaled18) = BasePoolMath.computeAddLiquidityUnbalanced(
                poolData.balancesLiveScaled18,
                maxAmountsInScaled18,
                _totalSupply(params.pool),
                _getSwapFeePercentage(poolData.poolConfig),
                IBasePool(params.pool).computeInvariant
            );
        } else if (params.kind == AddLiquidityKind.SINGLE_TOKEN_EXACT_OUT) {
            bptAmountOut = params.minBptAmountOut;
            uint256 tokenIndex = InputHelpers.getSingleInputIndex(maxAmountsInScaled18);

            amountsInScaled18 = maxAmountsInScaled18;
            (amountsInScaled18[tokenIndex], swapFeeAmountsScaled18) = BasePoolMath
                .computeAddLiquiditySingleTokenExactOut(
                    poolData.balancesLiveScaled18,
                    tokenIndex,
                    bptAmountOut,
                    _totalSupply(params.pool),
                    _getSwapFeePercentage(poolData.poolConfig),
                    IBasePool(params.pool).computeBalance
                );
        } else if (params.kind == AddLiquidityKind.CUSTOM) {
            _poolConfig[params.pool].requireSupportsAddLiquidityCustom();

            (amountsInScaled18, bptAmountOut, swapFeeAmountsScaled18, returnData) = IPoolLiquidity(params.pool)
                .onAddLiquidityCustom(
                    params.to,
                    maxAmountsInScaled18,
                    params.minBptAmountOut,
                    poolData.balancesLiveScaled18,
                    params.userData
                );
        } else {
            revert InvalidAddLiquidityKind();
        }

        // At this point we have the calculated BPT amount.
        if (bptAmountOut < params.minBptAmountOut) {
            revert BptAmountOutBelowMin(bptAmountOut, params.minBptAmountOut);
        }

        amountsInRaw = new uint256[](numTokens);
        IERC20[] memory tokens = new IERC20[](numTokens);

        for (uint256 i = 0; i < numTokens; ++i) {
            IERC20 token = poolData.tokenConfig[i].token;
            tokens[i] = token;

            // Compute and charge protocol fees
            uint256 protocolSwapFeeAmountRaw = _computeAndChargeProtocolFees(
                poolData,
                swapFeeAmountsScaled18[i],
                params.pool,
                token,
                i
            );

            // amountsInRaw are amounts actually entering the Pool, so we round up.
            // Do not mutate in place yet, as we need them scaled for the `onAfterAddLiquidity` hook
            uint256 amountInRaw = amountsInScaled18[i].toRawUndoRateRoundUp(
                poolData.decimalScalingFactors[i],
                poolData.tokenRates[i]
            );

            // The limits must be checked for raw amounts
            if (amountInRaw > params.maxAmountsIn[i]) {
                revert AmountInAboveMax(token, amountInRaw, params.maxAmountsIn[i]);
            }

            // Debit of token[i] for amountInRaw
            _takeDebt(token, amountInRaw, msg.sender);

            // We need regular balances to complete the accounting, and the upscaled balances
            // to use in the `after` hook later on.
            poolData.balancesRaw[i] += (amountInRaw - protocolSwapFeeAmountRaw);
            poolData.balancesLiveScaled18[i] += (amountsInScaled18[i] -
                swapFeeAmountsScaled18[i].mulUp(_protocolSwapFeePercentage));

            amountsInRaw[i] = amountInRaw;
        }

        // Store the new raw and last live pool balances.
        _setPoolBalances(params.pool, poolData);

        // When adding liquidity, we must mint tokens concurrently with updating pool balances,
        // as the pool's math relies on totalSupply.
        _mint(address(params.pool), params.to, bptAmountOut);

        emit PoolBalanceChanged(params.pool, params.to, tokens, amountsInRaw.unsafeCastToInt256(true));
    }

    /// @inheritdoc IVaultMain
    function removeLiquidity(
        RemoveLiquidityParams memory params
    )
        external
        withLocker
        withInitializedPool(params.pool)
        whenPoolNotPaused(params.pool)
        returns (uint256 bptAmountIn, uint256[] memory amountsOut, bytes memory returnData)
    {
        // Round down when removing liquidity:
        // If proportional, lower balances = lower proportional amountsOut, favoring the pool.
        // If unbalanced, lower balances = lower invariant ratio without fees.
        // bptIn = supply * (1 - ratio), so lower ratio = more bptIn, favoring the pool.
        PoolData memory poolData = _computePoolDataUpdatingBalancesAndFees(params.pool, Rounding.ROUND_DOWN);
        InputHelpers.ensureInputLengthMatch(poolData.tokenConfig.length, params.minAmountsOut.length);

        // Amounts are entering pool math; higher amounts would burn more BPT, so round up to favor the pool.
        // Do not mutate minAmountsOut, so that we can directly compare the raw limits later, without potentially
        // losing precision by scaling up and then down.
        uint256[] memory minAmountsOutScaled18 = params.minAmountsOut.copyToScaled18ApplyRateRoundUpArray(
            poolData.decimalScalingFactors,
            poolData.tokenRates
        );

        if (poolData.poolConfig.hooks.shouldCallBeforeRemoveLiquidity) {
            if (
                IPoolHooks(params.pool).onBeforeRemoveLiquidity(
                    params.from,
                    params.kind,
                    params.maxBptAmountIn,
                    minAmountsOutScaled18,
                    poolData.balancesLiveScaled18,
                    params.userData
                ) == false
            ) {
                revert BeforeRemoveLiquidityHookFailed();
            }
            // The hook might alter the balances, so we need to read them again to ensure that the data is
            // fresh moving forward.
            // We also need to upscale (removing liquidity, so round down) again.
            _updatePoolDataLiveBalancesAndRates(poolData, Rounding.ROUND_DOWN);

            // Also update minAmountsOutScaled18, as the rates might have changed.
            minAmountsOutScaled18 = params.minAmountsOut.copyToScaled18ApplyRateRoundUpArray(
                poolData.decimalScalingFactors,
                poolData.tokenRates
            );
        }

        // The bulk of the work is done here: the corresponding Pool hook is called, and the final balances
        // are computed. This function is non-reentrant, as it performs the accounting updates.
        // Note that poolData is mutated to update the Raw and Live balances, so they are accurate when passed
        // into the AfterRemoveLiquidity hook.
        uint256[] memory amountsOutScaled18;
        (bptAmountIn, amountsOut, amountsOutScaled18, returnData) = _removeLiquidity(
            poolData,
            params,
            minAmountsOutScaled18
        );

        if (poolData.poolConfig.hooks.shouldCallAfterRemoveLiquidity) {
            if (
                IPoolHooks(params.pool).onAfterRemoveLiquidity(
                    params.from,
                    bptAmountIn,
                    amountsOutScaled18,
                    poolData.balancesLiveScaled18,
                    params.userData
                ) == false
            ) {
                revert AfterRemoveLiquidityHookFailed();
            }
        }
    }

    /**
     * @dev Calls the appropriate pool hook and calculates the required inputs and outputs for the operation
     * considering the given kind, and updates the vault's internal accounting. This includes:
     * - Setting pool balances
     * - Supplying credit to the liquidity provider
     * - Burning pool tokens
     * - Emitting events
     *
     * It is non-reentrant, as it performs external calls and updates the vault's state accordingly. This is the only
     * place where the state is updated within `removeLiquidity`.
     */
    function _removeLiquidity(
        PoolData memory poolData,
        RemoveLiquidityParams memory params,
        uint256[] memory minAmountsOutScaled18
    )
        internal
        nonReentrant
        returns (
            uint256 bptAmountIn,
            uint256[] memory amountsOutRaw,
            uint256[] memory amountsOutScaled18,
            bytes memory returnData
        )
    {
        uint256 tokenOutIndex;
        uint256[] memory swapFeeAmountsScaled18;

        if (params.kind == RemoveLiquidityKind.PROPORTIONAL) {
            bptAmountIn = params.maxBptAmountIn;
            swapFeeAmountsScaled18 = new uint256[](poolData.balancesLiveScaled18.length);
            amountsOutScaled18 = BasePoolMath.computeProportionalAmountsOut(
                poolData.balancesLiveScaled18,
                _totalSupply(params.pool),
                bptAmountIn
            );
        } else if (params.kind == RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN) {
            bptAmountIn = params.maxBptAmountIn;

            amountsOutScaled18 = minAmountsOutScaled18;
            tokenOutIndex = InputHelpers.getSingleInputIndex(params.minAmountsOut);
            (amountsOutScaled18[tokenOutIndex], swapFeeAmountsScaled18) = BasePoolMath
                .computeRemoveLiquiditySingleTokenExactIn(
                    poolData.balancesLiveScaled18,
                    tokenOutIndex,
                    bptAmountIn,
                    _totalSupply(params.pool),
                    _getSwapFeePercentage(poolData.poolConfig),
                    IBasePool(params.pool).computeBalance
                );
        } else if (params.kind == RemoveLiquidityKind.SINGLE_TOKEN_EXACT_OUT) {
            amountsOutScaled18 = minAmountsOutScaled18;
            tokenOutIndex = InputHelpers.getSingleInputIndex(params.minAmountsOut);

            (bptAmountIn, swapFeeAmountsScaled18) = BasePoolMath.computeRemoveLiquiditySingleTokenExactOut(
                poolData.balancesLiveScaled18,
                tokenOutIndex,
                amountsOutScaled18[tokenOutIndex],
                _totalSupply(params.pool),
                _getSwapFeePercentage(poolData.poolConfig),
                IBasePool(params.pool).computeInvariant
            );
        } else if (params.kind == RemoveLiquidityKind.CUSTOM) {
            _poolConfig[params.pool].requireSupportsRemoveLiquidityCustom();
            (bptAmountIn, amountsOutScaled18, swapFeeAmountsScaled18, returnData) = IPoolLiquidity(params.pool)
                .onRemoveLiquidityCustom(
                    params.from,
                    params.maxBptAmountIn,
                    minAmountsOutScaled18,
                    poolData.balancesLiveScaled18,
                    params.userData
                );
        } else {
            revert InvalidRemoveLiquidityKind();
        }

        if (bptAmountIn > params.maxBptAmountIn) {
            revert BptAmountInAboveMax(bptAmountIn, params.maxBptAmountIn);
        }

        uint256 numTokens = poolData.tokenConfig.length;
        IERC20[] memory tokens = new IERC20[](numTokens);
        amountsOutRaw = new uint256[](numTokens);

        for (uint256 i = 0; i < numTokens; ++i) {
            IERC20 token = poolData.tokenConfig[i].token;
            // Compute and charge protocol fees
            uint256 protocolSwapFeeAmountRaw = _computeAndChargeProtocolFees(
                poolData,
                swapFeeAmountsScaled18[i],
                params.pool,
                token,
                i
            );

            // Subtract protocol fees charged from the pool's balances
            poolData.balancesRaw[i] -= protocolSwapFeeAmountRaw;
            poolData.balancesLiveScaled18[i] -= (amountsOutScaled18[i] +
                swapFeeAmountsScaled18[i].mulUp(_protocolSwapFeePercentage));
            tokens[i] = token;

            // amountsOut are amounts exiting the Pool, so we round down.
            amountsOutRaw[i] = amountsOutScaled18[i].toRawUndoRateRoundDown(
                poolData.decimalScalingFactors[i],
                poolData.tokenRates[i]
            );

            if (amountsOutRaw[i] < params.minAmountsOut[i]) {
                revert AmountOutBelowMin(tokens[i], amountsOutRaw[i], params.minAmountsOut[i]);
            }

            // Credit token[i] for amountOut
            _supplyCredit(tokens[i], amountsOutRaw[i], msg.sender);

            // Compute the new Pool balances. A Pool's token balance always decreases after an exit
            // (potentially by 0).
            poolData.balancesRaw[i] -= amountsOutRaw[i];
        }

        _setPoolBalances(params.pool, poolData);

        // Trusted routers use Vault's allowances, which are infinite anyways for pool tokens.
        if (!_isTrustedRouter(msg.sender)) {
            _spendAllowance(address(params.pool), params.from, msg.sender, bptAmountIn);
        }

        if (!_isQueryDisabled && EVMCallModeHelpers.isStaticCall()) {
            // Increase `from` balance to ensure the burn function succeeds.
            _queryModeBalanceIncrease(params.pool, params.from, bptAmountIn);
        }
        // When removing liquidity, we must burn tokens concurrently with updating pool balances,
        // as the pool's math relies on totalSupply.
        // Burning will be reverted if it results in a total supply less than the _MINIMUM_TOTAL_SUPPLY.
        _burn(address(params.pool), params.from, bptAmountIn);

        emit PoolBalanceChanged(
            params.pool,
            params.from,
            tokens,
            // We can unsafely cast to int256 because balances are stored as uint128 (see PackedTokenBalance).
            amountsOutRaw.unsafeCastToInt256(false)
        );
    }

    function _onlyTrustedRouter(address sender) internal pure {
        if (!_isTrustedRouter(sender)) {
            revert RouterNotTrusted();
        }
    }

    function _computeAndChargeProtocolFees(
        PoolData memory poolData,
        uint256 swapFeeAmountScaled18,
        address pool,
        IERC20 token,
        uint256 index
    ) internal returns (uint256 protocolSwapFeeAmountRaw) {
        // If swapFeeAmount equals zero no need to charge anything
        if (
            swapFeeAmountScaled18 > 0 &&
            _protocolSwapFeePercentage > 0 &&
            poolData.poolConfig.isPoolInRecoveryMode == false
        ) {
            // Always charge fees on token. Store amount in native decimals.
            // Since the swapFeeAmountScaled18 also contains the rate, undo it when converting to raw.
            protocolSwapFeeAmountRaw = swapFeeAmountScaled18.mulUp(_protocolSwapFeePercentage).toRawUndoRateRoundDown(
                poolData.decimalScalingFactors[index],
                poolData.tokenRates[index]
            );

            _protocolFees[token] += protocolSwapFeeAmountRaw;
            emit ProtocolSwapFeeCharged(pool, address(token), protocolSwapFeeAmountRaw);
        }
    }

    /*******************************************************************************
                                    Pool Information
    *******************************************************************************/

    /// @inheritdoc IVaultMain
    function getPoolTokenCountAndIndexOfToken(
        address pool,
        IERC20 token
    ) external view withRegisteredPool(pool) returns (uint256, uint256) {
        EnumerableMap.IERC20ToBytes32Map storage poolTokenBalances = _poolTokenBalances[pool];
        uint256 tokenCount = poolTokenBalances.length();
        // unchecked indexOf returns index + 1, or 0 if token is not present.
        uint256 index = poolTokenBalances.unchecked_indexOf(token);
        if (index == 0) {
            revert TokenNotRegistered();
        }

        unchecked {
            return (tokenCount, index - 1);
        }
    }

    /*******************************************************************************
                                    Authentication
    *******************************************************************************/

    /// @inheritdoc IVaultMain
    function getAuthorizer() external view returns (IAuthorizer) {
        return _authorizer;
    }

    /*******************************************************************************
                                     Default handlers
    *******************************************************************************/

    receive() external payable {
        revert CannotReceiveEth();
    }

    // solhint-disable no-complex-fallback

    /**
     * @inheritdoc Proxy
     * @dev Override proxy implementation of `fallback` to disallow incoming ETH transfers.
     * This function actually returns whatever the Vault Extension does when handling the request.
     */
    fallback() external payable override {
        if (msg.value > 0) {
            revert CannotReceiveEth();
        }

        _fallback();
    }

    /// @inheritdoc IVaultMain
    function getVaultExtension() external view returns (address) {
        return _implementation();
    }

    /**
     * @inheritdoc Proxy
     * @dev Returns Vault Extension, where fallback requests are forwarded.
     */
    function _implementation() internal view override returns (address) {
        return address(_vaultExtension);
    }
}

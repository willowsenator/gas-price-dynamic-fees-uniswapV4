// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

contract GasPriceFeesHook is BaseHook {
    using LPFeeLibrary for uint24;

    // Moving average gas price used to adjust fees
    uint128 public movingAverageGasPrice;

    // Number of samples used to calculate the moving average gas price
    uint104 public movingAverageGasPriceCount;

    // Base fee for the pool, in hundredths of a bip (1e-6)
    uint24 public constant BASE_FEE = 5000; // 0.5%

    error MustUseDynamicFees();

    constructor(IPoolManager _manager) BaseHook(_manager) {
        updateMovingAverage();
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) {
            revert MustUseDynamicFees();
        }
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = getFee();

        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    // Updates the moving average gas price with the current transaction's gas price
    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);

        movingAverageGasPrice =
            (movingAverageGasPrice * movingAverageGasPriceCount + gasPrice) / (movingAverageGasPriceCount + 1);
        movingAverageGasPriceCount++;
    }

    function getFee() internal returns (uint24) {
        // Example fee adjustment logic based on gas price
        uint128 currentGasPrice = uint128(tx.gasprice);

        // Move the average gas price 1.1% towards the current gas price
        if (currentGasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEE / 2;
        }
        // Move the average gas price 0.9% lower than the current gas price
        else if (currentGasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEE * 2;
        }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}

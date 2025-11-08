// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {GasPriceFeesHook} from "../src/GasPriceFeesHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";

contract TestGasPriceFeesHook is Test, Deployers {
    GasPriceFeesHook public hook;

    function setUp() public {
        // Deploy a fresh PoolManager for each test
        deployFreshManagerAndRouters();

        // Deploy
        deployMintAndApprove2Currencies();

        address hookAddress =
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));

        // Deploy the GasPriceFeesHook to the expected address
        vm.txGasPrice(10 gwei);
        deployCodeTo("GasPriceFeesHook.sol", abi.encode(manager), hookAddress);

        hook = GasPriceFeesHook(hookAddress);

        // Init pool
        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 100 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_feeUpdatesWithGasPrice() public {
        // Swap parameters
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -0.00001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // First swap with 10 gwei gas price
        uint128 gasPrice = uint128(tx.gasprice);
        uint128 movingAverageGasPrice = hook.movingAverageGasPrice();
        uint104 movingAverageGasPriceCount = hook.movingAverageGasPriceCount();

        assertEq(gasPrice, 10 gwei);
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 1);

        // Swap at 10 gwei gas price
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, settings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();

        uint256 outputFromBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // Moving average gas price should remain the same
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();

        assertLe(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 2);

        // Second swap with 4 gwei gas price
        vm.txGasPrice(4 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, settings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();

        uint256 outputFromIncreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // Moving average gas price should decrease to around 8 gwei
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();

        console.log("movingAverageGasPrice:", uint256(movingAverageGasPrice));
        console.log("Expected around 8 gwei:", uint256(8 gwei));
        assertLe(movingAverageGasPrice, 8 gwei);
        assertEq(movingAverageGasPriceCount, 3);

        // Third swap with 12 gwei gas price
        vm.txGasPrice(12 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, settings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();

        uint256 outputFromDecreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // Moving average gas price should increase
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertLe(movingAverageGasPrice, 9 gwei);
        assertEq(movingAverageGasPriceCount, 4);

        console.log("Base Fee Output", outputFromBaseFeeSwap);
        console.log("Low Gas (4 gwei) Output", outputFromIncreasedFeeSwap);
        console.log("High Gas (12 gwei) Output", outputFromDecreasedFeeSwap);

        // Base fee output should be highest (no fee adjustment)
        // Low gas (4 gwei) should have highest fee, thus lowest output
        // High gas (12 gwei) should have medium fee, thus medium output
        assertGt(outputFromBaseFeeSwap, outputFromDecreasedFeeSwap);
        assertGt(outputFromDecreasedFeeSwap, outputFromIncreasedFeeSwap);
    }
}

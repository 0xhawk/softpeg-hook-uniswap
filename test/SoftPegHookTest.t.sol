// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SoftPegHook, IOracle, IPSM} from "../src/SoftPegHook.sol";
import {MockOracle}            from "../src/MockOracle.sol";
import {MockPSM}               from "../src/MockPSM.sol";
import {IPoolManager}          from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}               from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams}            from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract MockStateView is IStateView {
    function getSlot0(PoolId) external pure override returns (uint160, int24, uint24, uint24) { return (uint160(1 << 96), 0, 0, 0); }
    function getTickInfo(PoolId, int24) external pure override returns (uint128, int128, uint256, uint256) { return (0, 0, 0, 0); }
    function getTickLiquidity(PoolId, int24) external pure override returns (uint128, int128) { return (0, 0); }
    function getTickFeeGrowthOutside(PoolId, int24) external pure override returns (uint256, uint256) { return (0, 0); }
    function getFeeGrowthGlobals(PoolId) external pure override returns (uint256, uint256) { return (0, 0); }
    function getLiquidity(PoolId) external pure override returns (uint128) { return 0; }
    function getTickBitmap(PoolId, int16) external pure override returns (uint256) { return 0; }
    function getPositionInfo(PoolId, address, int24, int24, bytes32) external pure override returns (uint128, uint256, uint256) { return (0, 0, 0); }
    function getPositionInfo(PoolId, bytes32) external pure override returns (uint128, uint256, uint256) { return (0, 0, 0); }
    function getPositionLiquidity(PoolId, bytes32) external pure override returns (uint128) { return 0; }
    function getFeeGrowthInside(PoolId, int24, int24) external pure override returns (uint256, uint256) { return (0, 0); }
    function poolManager() external pure override returns (IPoolManager) { return IPoolManager(address(0)); }
}

// Helper contract to call afterSwap as PoolManager
contract MockPoolManager {
    function callAfterSwap(
        SoftPegHook hook,
        PoolKey memory key,
        SwapParams memory params,
        BalanceDelta delta,
        bytes memory data
    ) external {
        hook.afterSwap(address(this), key, params, delta, data);
    }
}

contract SoftPegHookTest is Test {
    SoftPegHook hook;
    MockOracle  oracle;
    MockPSM     psm;
    MockStateView stateView;
    PoolKey key;
    MockPoolManager mockPoolManager;

    function setUp() public {
        mockPoolManager = new MockPoolManager();
        oracle = new MockOracle();
        oracle.setPrice(1e18);
        psm   = new MockPSM();
        stateView = new MockStateView();
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        hook  = new SoftPegHook(IPoolManager(address(mockPoolManager)), key, IOracle(address(oracle)), IPSM(address(psm)), IStateView(address(stateView)));
    }

    /// @dev price deviates only 0.05 % → inside ±0.30 % band
    function testWithinBand() public {
        uint256 p = 1_000_500_000_000_000_000; // 1.0005
        assertTrue(hook.isWithinBand(p));
    }

    /// @dev price deviates 0.50 % → outside band, expect false
    function testOutsideBand() public {
        uint256 p = 1_005_000_000_000_000_000; // 1.005
        assertFalse(hook.isWithinBand(p));
    }

    function testFeeZeroInsideBand() public {
        uint256 p = 999_800_000_000_000_000; // −0.02 % (inside)
        assertEq(hook.feeOverride(p), 0);
    }

    function testFeeDiscouragementOutsideBand() public {
        uint256 p = 1_003_500_000_000_000_000; // +0.35 % (between 0.30 & 1.00)
        uint24 fee = hook.feeOverride(p);
        uint24 feeBps = fee & 0x3FFFFF; // lower 22 bits = fee
        bool flagSet  = (fee & 0x400000) == 0x400000;
        assertEq(feeBps, 500);   // 5 %
        assertTrue(flagSet);
    }

    function testRevertBeyondHardCap() public {
        uint256 p = 1_011_000_000_000_000_000; // +1.1 %
        vm.expectRevert();
        hook.feeOverride(p);
    }

    function testAfterSwapSellsWhenPriceHigh() public {
        hook.setMockPoolPrice(1_004_000_000_000_000_000); // +0.4 %
        PoolKey memory swapKey;
        SwapParams memory params;
        vm.expectEmit(true, true, true, true);
        emit MockPSM.Sell(1e18, 1_004_000_000_000_000_000);
        mockPoolManager.callAfterSwap(hook, swapKey, params, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function testAfterSwapBuysWhenPriceLow() public {
        hook.setMockPoolPrice(996_000_000_000_000_000); // ‑0.4 %
        PoolKey memory swapKey;
        SwapParams memory params;
        vm.expectEmit(true, true, true, true);
        emit MockPSM.Buy(1e18, 996_000_000_000_000_000);
        mockPoolManager.callAfterSwap(hook, swapKey, params, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function testAfterSwapDoesNothingInsideBand() public {
        hook.setMockPoolPrice(1_000_100_000_000_000_000); // +0.01 %
        PoolKey memory swapKey;
        SwapParams memory params;
        mockPoolManager.callAfterSwap(hook, swapKey, params, BalanceDeltaLibrary.ZERO_DELTA, "");
        // no event expected; pass if no revert
    }

    function testPriceConversionIs1e18() public {
        uint160 sqrt = uint160(1) << 96; // 2^96
        uint256 price = hook.price1e18FromSqrt(sqrt);
        assertEq(price, 1e18);
    }
}
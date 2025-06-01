// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SoftPegHook, IOracle, IPSM} from "../src/SoftPegHook.sol";
import {MockOracle}            from "../src/MockOracle.sol";
import {MockPSM}               from "../src/MockPSM.sol";
import {IPoolManager}          from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}               from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams}            from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract SoftPegHookTest is Test {
    SoftPegHook hook;
    MockOracle  oracle;
    MockPSM     psm;

    function setUp() public {
        oracle = new MockOracle();
        oracle.setPrice(1e18);
        psm   = new MockPSM();
        hook  = new SoftPegHook(IPoolManager(address(0)), IOracle(address(oracle)), IPSM(address(psm)));
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
        PoolKey memory key;
        SwapParams memory params;
        vm.expectEmit(true, true, true, true);
        emit MockPSM.Sell(1e18, 1_004_000_000_000_000_000);
        hook.afterSwap(address(this), key, params, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function testAfterSwapBuysWhenPriceLow() public {
        hook.setMockPoolPrice(996_000_000_000_000_000); // ‑0.4 %
        PoolKey memory key;
        SwapParams memory params;
        vm.expectEmit(true, true, true, true);
        emit MockPSM.Buy(1e18, 996_000_000_000_000_000);
        hook.afterSwap(address(this), key, params, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function testAfterSwapDoesNothingInsideBand() public {
        hook.setMockPoolPrice(1_000_100_000_000_000_000); // +0.01 %
        PoolKey memory key;
        SwapParams memory params;
        hook.afterSwap(address(this), key, params, BalanceDeltaLibrary.ZERO_DELTA, "");
        // no event expected; pass if no revert
    }
}
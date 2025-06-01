// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {SoftPegHook, IOracle} from "../src/SoftPegHook.sol";
import {MockOracle}           from "../src/MockOracle.sol";
import {IPoolManager}         from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract SoftPegHookTest is Test {
    SoftPegHook hook;
    MockOracle  oracle;

    function setUp() public {
        oracle = new MockOracle();
        oracle.setPrice(1e18); // $1.00 in 1e18 scale
        hook   = new SoftPegHook(IPoolManager(address(0)), IOracle(address(oracle)));
    }

    /// @dev price deviates only 0.05 % → inside ±0.30 % band
    function testWithinBand() public {
        uint256 p = 1_000_500_000_000_000_000; // 1.0005
        assertTrue(hook.isWithinBand(p));
    }

    /// @dev price deviates 0.50 % → outside band, expect false
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
}
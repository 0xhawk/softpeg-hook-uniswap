// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SoftPegHook} from "../src/SoftPegHook.sol";
import {MockOracle}  from "../src/MockOracle.sol";
import {MockPSM} from "../src/MockPSM.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";

contract SoftPegHookTest is Test {
    SoftPegHook hook;
    MockOracle oracle;
    MockPSM psm;

    // NOTE: Replace with TestPoolManager or deployed instance on anvil‑fork
    IPoolManager manager = IPoolManager(address(0xdead));

    function setUp() public {
        oracle = new MockOracle();
        oracle.setPrice(1e18); // $1.00
        psm = new MockPSM();
        hook = new SoftPegHook(manager, address(oracle), address(psm));
    }

    function test_NoFeeInsideBand() public {
        PoolKey memory key; // dummy
        IPoolManager.SwapParams memory p;
        ( , , uint24 fee) = hook.beforeSwap(address(this), key, p, "");
        assertEq(fee & 0x3FFFFF, 0, "Fee should be zero inside band");
    }

    function test_FeeAppliedNearEdge() public {
        oracle.setPrice(1.0031e18); // 0.31 % above
        PoolKey memory key;
        IPoolManager.SwapParams memory p;
        ( , , uint24 fee) = hook.beforeSwap(address(this), key, p, "");
        assertEq(fee & 0x3FFFFF, 500, "500 bps fee encoded");
    }

    function test_RevertBeyondHardCap() public {
        oracle.setPrice(1.011e18); // 1.1 %
        PoolKey memory key;
        IPoolManager.SwapParams memory p;
        vm.expectRevert();
        hook.beforeSwap(address(this), key, p, "");
    }
}
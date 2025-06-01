// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks}    from "@uniswap/v4-core/src/libraries/Hooks.sol";

interface IOracle {
    function price() external view returns (uint256);
}

error PegOutOfRange();

contract SoftPegHook is BaseHook {
    IPoolManager public immutable poolManager;
    IOracle      public immutable oracle;

    // soft band ±0.30 % = 30 bps
    uint256 public constant MAX_BAND_BPS  = 30;
    // hard cap  ±1.00 %  = 100 bps ⇒ revert
    uint256 public constant HARD_CAP_BPS = 100;

    // Uniswap v4 fee‑override flag (0x400000) to indicate custom fee
    uint24 private constant OVERRIDE_FLAG = 0x400000;

    constructor(IPoolManager _poolManager, IOracle _oracle)
        BaseHook(_poolManager)
    {
        oracle = _oracle;
    }

    function getHookPermissions() public pure override returns (uint8) {
        // we only implement beforeSwap for now
        return Hooks.BEFORE_SWAP_FLAG;
    }

    function beforeSwap(
        address /*sender*/,
        PoolKey calldata /*key*/,
        IPoolManager.SwapParams calldata /*params*/,
        bytes calldata /*hookData*/
    )
        external
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24 fee)
    {
        // Use mock price if set (tests) otherwise fall back to oracle price
        uint256 poolP = mockPoolPrice != 0 ? mockPoolPrice : oracle.price();
        fee = _feeOverride(poolP);
        return (SoftPegHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    // afterSwap not used yet but must exist – return default selector
    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata,
        int128
    ) external pure override returns (bytes4) {
        return SoftPegHook.afterSwap.selector;
    }

    function isWithinBand(uint256 poolPrice) public view returns (bool) {
        uint256 target = oracle.price();
        uint256 diff   = target > poolPrice ? target - poolPrice : poolPrice - target;
        return diff * 10_000 <= target * MAX_BAND_BPS;
    }

    function feeOverride(uint256 poolPrice) public view returns (uint24) {
        (uint256 target, uint256 diffBps) = _diffBps(poolPrice);

        if (diffBps > HARD_CAP_BPS) revert PegOutOfRange();
        if (diffBps <= MAX_BAND_BPS) return 0; // inside band

        // between 0.30 % and 1.00 % → 5 % fee, set override flag
        uint24 feeBps = 500; // 500 bps = 5 %
        return feeBps | OVERRIDE_FLAG;
    }

    function _diffBps(uint256 poolPrice) internal view returns (uint256 target, uint256 bps) {
        target = oracle.price();
        uint256 diff = target > poolPrice ? target - poolPrice : poolPrice - target;
        bps = diff * 10_000 / target;
    }
}
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks}    from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IOracle {
    function price() external view returns (uint256);
}

interface IPSM {
    function sellSPT(uint256 target, uint256 price) external;
    function buySPT(uint256 target, uint256 price) external;
}

error PegOutOfRange();

contract SoftPegHook is BaseHook {
    IOracle      public immutable oracle;
    IPSM   public immutable psm;  

    uint256 public constant MAX_BAND_BPS  = 30;
    uint256 public constant HARD_CAP_BPS = 100;
    uint24  private constant OVERRIDE_FLAG = 0x400000; // Uniswap v4 custom‑fee flag
    /*---------------- Testing aids (mock overrides) --------------*/
    uint256 public mockPoolPrice;               // if non‑zero, overrides pool price
    function setMockPoolPrice(uint256 p) external { mockPoolPrice = p; }

    constructor(IPoolManager _pm, IOracle _oracle, IPSM _psm) BaseHook(_pm) {
        oracle = _oracle;
        psm    = _psm;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory perms) {
        perms.beforeSwap = true;
        perms.afterSwap  = true;
    }

    function _beforeSwap(
        address /*sender*/,
        PoolKey calldata /*key*/,
        SwapParams calldata /*params*/,
        bytes calldata /*hookData*/
    )
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24 fee)
    {
        // Use mock price if set (tests) otherwise fall back to oracle price
        uint256 poolP = mockPoolPrice > 0 ? mockPoolPrice : oracle.price();
        fee = feeOverride(poolP);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        uint256 poolP  = _currentPoolPrice();
        uint256 target = oracle.price();
        uint256 diff   = poolP > target ? poolP - target : target - poolP;
        uint256 bps    = diff * 10_000 / target;

        if (bps > MAX_BAND_BPS && bps <= HARD_CAP_BPS) {
            if (poolP > target) {
                // price high → mint SPT & sell into pool
                psm.sellSPT(target, poolP);
            } else {
                // price low → buy & burn SPT
                psm.buySPT(target, poolP);
            }
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function isWithinBand(uint256 poolPrice) public view returns (bool) {
        uint256 target = oracle.price();
        uint256 diff   = target > poolPrice ? target - poolPrice : poolPrice - target;
        return diff * 10_000 <= target * MAX_BAND_BPS;
    }

    function feeOverride(uint256 poolPrice) public view returns (uint24) {
        (, uint256 diff) = _diffBps(poolPrice);
        if (diff > HARD_CAP_BPS) revert PegOutOfRange();
        if (diff <= MAX_BAND_BPS) return 0;                 // inside band
        return uint24(500) | OVERRIDE_FLAG;                 // 5 % fee + flag
    }

    function _diffBps(uint256 poolPrice) internal view returns (uint256 target, uint256 bps) {
        target = oracle.price();
        uint256 diff = target > poolPrice ? target - poolPrice : poolPrice - target;
        bps = diff * 10_000 / target;
    }

    function _currentPoolPrice() internal view returns (uint256) {
        return mockPoolPrice != 0 ? mockPoolPrice : oracle.price();
    }

    // Override for testing: disables hook address validation
    function validateHookAddress(BaseHook) internal pure override {}
}
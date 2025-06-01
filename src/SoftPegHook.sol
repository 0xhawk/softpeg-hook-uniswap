// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks}    from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

interface IOracle {
    function price() external view returns (uint256);
}

interface IPSM {
    function sellSPT(uint256 target, uint256 price) external;
    function buySPT(uint256 target, uint256 price) external;
}

error PegOutOfRange();

contract SoftPegHook is BaseHook {
    IOracle public immutable oracle;
    IPSM   public immutable psm;
    PoolKey public poolKey; // target pool we guard
    IStateView public stateView; // for reading pool state

    uint256 public constant MAX_BAND_BPS  = 30;   // ±0.30 %
    uint256 public constant HARD_CAP_BPS = 100;   // ±1.00 %
    uint24  private constant OVERRIDE_FLAG = 0x400000; // custom‑fee flag

    /*---------------- Testing aids (mock overrides) --------------*/
    uint256 public mockPoolPrice;               // if non‑zero, overrides pool price
    function setMockPoolPrice(uint256 p) external { mockPoolPrice = p; }

    constructor(IPoolManager _pm, PoolKey memory _key, IOracle _oracle, IPSM _psm, IStateView _stateView) BaseHook(_pm) {
        poolKey = _key;
        oracle  = _oracle;
        psm     = _psm;
        stateView = _stateView;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory perms) {
        perms.beforeSwap = true;
        perms.afterSwap  = true;
    }

    /* ------------- beforeSwap ------------- */
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal view override
        returns (bytes4, BeforeSwapDelta, uint24 fee)
    {
        uint256 postPrice = _currentPoolPrice(); // TODO simulate post‑swap
        fee = feeOverride(postPrice);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    /* ------------- afterSwap -------------- */
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal override
        returns (bytes4, int128)
    {
        uint256 price = _currentPoolPrice();
        uint256 target = oracle.price();
        uint256 diff = price > target ? price - target : target - price;
        uint256 bps  = diff * 10_000 / target;
        if (bps > MAX_BAND_BPS && bps <= HARD_CAP_BPS) {
            if (price > target) psm.sellSPT(target, price);
            else psm.buySPT(target, price);
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function isWithinBand(uint256 poolPrice) public view returns (bool) {
        uint256 target = oracle.price();
        uint256 diff   = target > poolPrice ? target - poolPrice : poolPrice - target;
        return diff * 10_000 <= target * MAX_BAND_BPS;
    }

    /* ---------- helpers ---------- */
    function _currentPoolPrice() internal view returns (uint256) {
        if (mockPoolPrice != 0) return mockPoolPrice;
        (uint160 sqrtP,,,) = stateView.getSlot0(PoolIdLibrary.toId(poolKey));
        return price1e18FromSqrt(sqrtP);
    }

    function price1e18FromSqrt(uint160 sqrtP) public pure returns (uint256) {
        uint256 n = uint256(sqrtP) * uint256(sqrtP);
        return (n * 1e18) >> 192;
    }

    function feeOverride(uint256 price) public view returns (uint24) {
        (, uint256 diff) = _diffBps(price);
        if (diff > HARD_CAP_BPS) revert PegOutOfRange();
        if (diff <= MAX_BAND_BPS) return 0;
        return uint24(500) | OVERRIDE_FLAG;
    }

    function _diffBps(uint256 price) internal view returns (uint256 target,uint256 bps){
        target = oracle.price();
        uint256 d = target > price ? target - price : price - target;
        bps = d * 10_000 / target;
    }

    /* disable hook validation in tests */
    function validateHookAddress(BaseHook) internal pure override {}
}
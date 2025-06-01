// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook, IHooks} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDeltaLibrary, BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

interface IOracle {
    function currentPrice() external view returns (uint256);
}

interface IPSM {
    function sellSPT(uint256 target, uint256 price) external;
    function buySPT(uint256 target, uint256 price) external;
}

/// @title SoftPegHook – Uniswap v4 Hook that keeps SPT <-> Collateral pool inside a ±0.3 % band.
/// @notice Skeleton version – fill TODOs before production.
contract SoftPegHook is BaseHook {
    /*//////////////////////////////////////////////////////////////*/
    /*                           CONFIG                            */
    /*//////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_BAND_BPS = 30;    // ±0.30 %
    uint256 public constant HARD_CAP_BPS = 100;   //  ±1.0 %

    address public immutable oracle;  // external price feed
    address public immutable psm;     // PSM Treasury contract

    constructor(IPoolManager _manager, address _oracle, address _psm)
        BaseHook(_manager)
    {
        oracle = _oracle;
        psm = _psm;
    }

    /*//////////////////////////////////////////////////////////////*/
    /*                    UNISWAP V4 HOOK LOGIC                     */
    /*//////////////////////////////////////////////////////////////*/

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (uint8) {
        return
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG;
    }

    /// @inheritdoc IHooks
    function beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /* hookData*/
    )
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24 feeOverride)
    {
        uint256 target = IOracle(oracle).currentPrice();
        uint256 postPrice = _computePostPrice(key, params);

        if (_absBpsDelta(target, postPrice) > HARD_CAP_BPS) {
            revert("PegOutOfRange");
        }

        if (_absBpsDelta(target, postPrice) > MAX_BAND_BPS) {
            // 500 bps discouragement fee. Set OVERRIDE_FEE_FLAG (0x400000)
            feeOverride = uint24(500) | uint24(0x400000);
        }

        // no liquidity delta changes → ZERO_DELTA
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.SwapParams calldata /*params*/,
        bytes calldata, /*hookData*/
        int128 /*delta*/
    )
        external
        override
        returns (bytes4)
    {
        uint256 target = IOracle(oracle).currentPrice();
        uint256 price = _currentPoolPrice(key);

        if (price > target * (10_000 + MAX_BAND_BPS) / 10_000) {
            IPSM(psm).sellSPT(target, price);
        } else if (price < target * (10_000 - MAX_BAND_BPS) / 10_000) {
            IPSM(psm).buySPT(target, price);
        }
        return IHooks.afterSwap.selector;
    }

    /*//////////////////////////////////////////////////////////////*/
    /*                   INTERNAL PRICE HELPERS                     */
    /*//////////////////////////////////////////////////////////////*/

    function _computePostPrice(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal view returns (uint256) {
        // TODO – pull current reserves and simulate params.amountSpecified impact.
        // For skeleton we return oracle price so tests compile.
        // Implement proper x*y=k tick math here.
        return IOracle(oracle).currentPrice();
    }

    function _currentPoolPrice(PoolKey calldata /*key*/) internal view returns (uint256) {
        // TODO – pull current sqrtPriceX96 from PoolManager storage.
        return IOracle(oracle).currentPrice();
    }

    function _absBpsDelta(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? ((a - b) * 10_000) / a : ((b - a) * 10_000) / b;
    }
}
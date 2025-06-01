// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @dev trivial on‑chain oracle used only in tests
contract MockOracle {
    uint256 private _p;

    function setPrice(uint256 p) external { _p = p; }
    function price() external view returns (uint256) { return _p; }
}
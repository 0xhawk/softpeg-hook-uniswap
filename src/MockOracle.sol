// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockOracle {
    uint256 public price;  // 1e18 scale

    function setPrice(uint256 _p) external { price = _p; }
    function currentPrice() external view returns (uint256) { return price; }
}
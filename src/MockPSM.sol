// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockPSM {
    event Sell(uint256 target, uint256 price);
    event Buy(uint256 target, uint256 price);

    function sellSPT(uint256 t, uint256 p) external { emit Sell(t, p); }
    function buySPT(uint256 t, uint256 p) external { emit Buy(t, p); }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @title MockPool
/// @notice Mock Aerodrome Pool for testing
contract MockPool {
    address public token0;
    address public token1;
    address public lpToken;

    uint256 private _claimable0;
    uint256 private _claimable1;

    bool public stable = false;
    uint256 public fee = 30; // 0.3%

    constructor(address _token0, address _token1, address _lpToken) {
        token0 = _token0;
        token1 = _token1;
        lpToken = _lpToken;
    }

    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        claimed0 = _claimable0;
        claimed1 = _claimable1;

        if (claimed0 > 0) {
            MockERC20(token0).transfer(msg.sender, claimed0);
        }
        if (claimed1 > 0) {
            MockERC20(token1).transfer(msg.sender, claimed1);
        }

        _claimable0 = 0;
        _claimable1 = 0;
    }

    function claimable0(address) external view returns (uint256) {
        return _claimable0;
    }

    function claimable1(address) external view returns (uint256) {
        return _claimable1;
    }

    function setClaimableFees(uint256 amount0, uint256 amount1) external {
        _claimable0 = amount0;
        _claimable1 = amount1;
    }

    function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast) {
        return (1000 ether, 1000 ether, block.timestamp);
    }

    function totalSupply() external pure returns (uint256) {
        return 1000 ether;
    }

    function balanceOf(address account) external view returns (uint256) {
        return MockERC20(lpToken).balanceOf(account);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return MockERC20(lpToken).transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return MockERC20(lpToken).transferFrom(from, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        return MockERC20(lpToken).approve(spender, amount);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return MockERC20(lpToken).allowance(owner, spender);
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function name() external pure returns (string memory) {
        return "Mock Pool";
    }

    function symbol() external pure returns (string memory) {
        return "MOCK-LP";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function mint(address) external pure returns (uint256) {
        return 0;
    }

    function burn(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function swap(uint256, uint256, address, bytes calldata) external pure {}

    function skim(address) external pure {}

    function sync() external pure {}
}


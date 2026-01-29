// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockKickoffFactory
/// @notice Mock factory for testing LPLocker's pool validation
contract MockKickoffFactory {
    mapping(address => bool) public isPool;

    /// @notice Register an address as a valid pool
    function setPool(address pool, bool valid) external {
        isPool[pool] = valid;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KickoffVoteSalePool} from "./KickoffVoteSalePool.sol";

/// @title VoteSalePoolDeployer
/// @notice Deploys KickoffVoteSalePool instances on behalf of KickoffFactory
/// @dev Separated from KickoffFactory to keep both contracts under EIP-170 bytecode limit.
///      The factory's runtime bytecode no longer embeds the pool's initcode (~23KB).
///      Access restricted: only the linked KickoffFactory can call deploy().
///      Uses the same one-time setFactory() pattern as LPLocker.
contract VoteSalePoolDeployer {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotDeployer();
    error NotFactory();
    error ZeroAddress();
    error FactoryAlreadySet();

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The address that deployed this contract (can call setFactory)
    address public immutable deployer;

    /// @notice The KickoffFactory address (only caller allowed to deploy pools)
    address public factory;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        deployer = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Link this deployer to a KickoffFactory (one-time setup)
    /// @param _factory The KickoffFactory address
    /// @dev Can only be called once by the original deployer
    function setFactory(address _factory) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (_factory == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = _factory;
    }

    /*//////////////////////////////////////////////////////////////
                            POOL DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a new KickoffVoteSalePool
    /// @dev Only callable by the linked KickoffFactory
    function deploy(
        address projectToken,
        address admin,
        address projectOwner,
        uint256 totalAllocation,
        uint256 minVotingPower,
        address lpLocker,
        address votingEscrow,
        address voter,
        address router,
        address weth,
        address priceArbitrageur
    ) external returns (address pool) {
        if (msg.sender != factory) revert NotFactory();

        pool = address(
            new KickoffVoteSalePool(
                projectToken,
                admin,
                projectOwner,
                totalAllocation,
                minVotingPower,
                lpLocker,
                votingEscrow,
                voter,
                router,
                weth,
                priceArbitrageur
            )
        );
    }
}

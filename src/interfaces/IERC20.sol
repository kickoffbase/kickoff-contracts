// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC20
/// @notice Interface for ERC20 tokens
interface IERC20 {
    /// @notice Get the total supply
    /// @return The total supply
    function totalSupply() external view returns (uint256);

    /// @notice Get the balance of an account
    /// @param account The account address
    /// @return The balance
    function balanceOf(address account) external view returns (uint256);

    /// @notice Transfer tokens
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @return True if successful
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Get the allowance
    /// @param owner Owner address
    /// @param spender Spender address
    /// @return The allowance amount
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Approve spending of tokens
    /// @param spender Spender address
    /// @param amount Amount to approve
    /// @return True if successful
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Transfer tokens from another account
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @return True if successful
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Get the name
    /// @return The name
    function name() external view returns (string memory);

    /// @notice Get the symbol
    /// @return The symbol
    function symbol() external view returns (string memory);

    /// @notice Get the decimals
    /// @return The decimals
    function decimals() external view returns (uint8);

    /// @notice Emitted when tokens are transferred
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when allowance is set
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}


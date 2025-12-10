// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPool
/// @notice Interface for Aerodrome's Pool contract (LP token)
interface IPool {
    /// @notice Claim accumulated trading fees
    /// @return claimed0 Amount of token0 fees claimed
    /// @return claimed1 Amount of token1 fees claimed
    function claimFees() external returns (uint256 claimed0, uint256 claimed1);

    /// @notice Get token0 of the pool
    /// @return The token0 address
    function token0() external view returns (address);

    /// @notice Get token1 of the pool
    /// @return The token1 address
    function token1() external view returns (address);

    /// @notice Get the reserves of the pool
    /// @return _reserve0 Reserve of token0
    /// @return _reserve1 Reserve of token1
    /// @return _blockTimestampLast Last update timestamp
    function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast);

    /// @notice Get the total supply of LP tokens
    /// @return The total supply
    function totalSupply() external view returns (uint256);

    /// @notice Get the balance of an account
    /// @param account The account address
    /// @return The balance
    function balanceOf(address account) external view returns (uint256);

    /// @notice Transfer LP tokens
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @return True if successful
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Transfer LP tokens from another account
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @return True if successful
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Approve spending of LP tokens
    /// @param spender Spender address
    /// @param amount Amount to approve
    /// @return True if successful
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Get the allowance
    /// @param owner Owner address
    /// @param spender Spender address
    /// @return The allowance amount
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Check if the pool is stable
    /// @return True if stable
    function stable() external view returns (bool);

    /// @notice Get the fee of the pool
    /// @return The fee (basis points)
    function fee() external view returns (uint256);

    /// @notice Get claimable token0 fees for an account
    /// @param account The account address
    /// @return Claimable token0 fees
    function claimable0(address account) external view returns (uint256);

    /// @notice Get claimable token1 fees for an account
    /// @param account The account address
    /// @return Claimable token1 fees
    function claimable1(address account) external view returns (uint256);

    /// @notice Get the factory address
    /// @return The factory address
    function factory() external view returns (address);

    /// @notice Mint LP tokens
    /// @param to Recipient address
    /// @return liquidity Amount of LP tokens minted
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Burn LP tokens
    /// @param to Recipient of underlying tokens
    /// @return amount0 Amount of token0 returned
    /// @return amount1 Amount of token1 returned
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swap tokens
    /// @param amount0Out Amount of token0 to receive
    /// @param amount1Out Amount of token1 to receive
    /// @param to Recipient address
    /// @param data Callback data
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /// @notice Skim excess tokens
    /// @param to Recipient address
    function skim(address to) external;

    /// @notice Sync reserves with balances
    function sync() external;

    /// @notice Get the name of the LP token
    /// @return The name
    function name() external view returns (string memory);

    /// @notice Get the symbol of the LP token
    /// @return The symbol
    function symbol() external view returns (string memory);

    /// @notice Get the decimals of the LP token
    /// @return The decimals
    function decimals() external view returns (uint8);
}


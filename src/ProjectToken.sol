// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ProjectToken
/// @notice Standard ERC20 token for project launches via Kickoff
/// @dev Fully compatible with Aerodrome, Uniswap, and any DEX
/// - 18 decimals (standard)
/// - No fee-on-transfer
/// - No rebase mechanics
/// - No blacklist/whitelist
/// - Fixed supply minted at deployment
contract ProjectToken {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when tokens are transferred
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when allowance is set
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Token name
    string public name;

    /// @notice Token symbol
    string public symbol;

    /// @notice Token decimals (always 18)
    uint8 public constant decimals = 18;

    /// @notice Total supply of tokens
    uint256 public totalSupply;

    /// @notice Balance of each account
    mapping(address => uint256) public balanceOf;

    /// @notice Allowance from owner to spender
    mapping(address => mapping(address => uint256)) public allowance;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new project token
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _totalSupply Total supply to mint
    /// @param _mintTo Address to receive all minted tokens
    constructor(string memory _name, string memory _symbol, uint256 _totalSupply, address _mintTo) {
        if (_mintTo == address(0)) revert ZeroAddress();

        name = _name;
        symbol = _symbol;
        totalSupply = _totalSupply;
        balanceOf[_mintTo] = _totalSupply;

        emit Transfer(address(0), _mintTo, _totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer tokens to a recipient
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @return True if successful
    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();

        unchecked {
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Approve spender to spend tokens
    /// @param spender Spender address
    /// @param amount Amount to approve
    /// @return True if successful
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer tokens from one address to another
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @return True if successful
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();

        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }

        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
        return true;
    }
}


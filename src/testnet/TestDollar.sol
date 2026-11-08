// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title TestDollar (testnet only)
/// @notice A plain 6-decimal ERC-20 used as the heartbeat + estate token on testnets when no faucet USDC is at hand.
///         Heirloom watches ANY allowlisted ERC-20 `Transfer`; Circle USDC stays allowlisted beside it, so the
///         zero-value spoof is still shown on the real token. Never deployed on mainnet.
contract TestDollar {
    string public constant name = "Heirloom Test Dollar (testnet)";
    string public constant symbol = "tHTD";
    uint8 public constant decimals = 6;
    address public immutable minter;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 v) external {
        require(msg.sender == minter, "minter");
        totalSupply += v;
        balanceOf[to] += v;
        emit Transfer(address(0), to, v);
    }

    function approve(address spender, uint256 v) external returns (bool) {
        allowance[msg.sender][spender] = v;
        emit Approval(msg.sender, spender, v);
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        _move(msg.sender, to, v);
        return true;
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= v, "allowance");
            allowance[from][msg.sender] = a - v;
        }
        _move(from, to, v);
        return true;
    }

    function _move(address from, address to, uint256 v) internal {
        require(balanceOf[from] >= v, "balance");
        balanceOf[from] -= v;
        balanceOf[to] += v;
        emit Transfer(from, to, v);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// @notice Custom errors to save gas
error TransferFailed();
error TokenNotAllowed(address token);
error NeedsMoreThanZero();

// @title Lending Contract
// @author Aiman Nazmi
// @notice This is a lending smart contract - a program that can be be deployed into Ethereum

contract Lending is ReentrancyGuard, Ownable {
    mapping(address => address) public s_tokenToPriceFeed;
    address[] public s_allowedTokens;
    mapping(address => mapping(address => uint256)) public s_accountToTokenDeposits;
    mapping(address => mapping(address => uint256)) public s_accountToTokenBorrows;

    // @notice 5% Liquidation Reward
    uint256 public constant LIQUIDATION_REWARD = 5;
    // @notice 80% Liquidation Threshold
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    // @notice Events to log
    event AllowedTokenSet(address indexed token, address indexed priceFeed);
    event Deposit(address indexed account, address indexed token, uint256 indexed amount);
    event Borrow(address indexed account, address indexed token, uint256 indexed amount);
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);
    event Repay(address indexed account, address indexed token, uint indexed amount);
    event Liquidate(
        address indexed account,
        address indexed repayToken,
        address indexed rewardToken,
        uint256 halfDebtInEth,
        address liquidator
    );
}

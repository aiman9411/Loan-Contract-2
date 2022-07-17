// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

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

    // @notice Modifier to check allowed tokens
    modifier isAllowedToken(address token) {
        if (s_tokenToPriceFeed[token] == address(0)) revert TokenNotAllowed(token);
        _;
    }

    // @notice Modifier to check value more than zero
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert NeedsMoreThanZero();
        _;
    }

    // @notice Deposit function for user
    function deposit(address token, uint256 amount) external nonReentrant isAllowedToken(token) moreThanZero(amount) {
        s_accountToTokenDeposits[msg.sender][token] += amount;
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        emit Deposit(msg.sender, token, amount);
    }

    // @notice Withdraw function
    function withdraw(address token, uint256 amount) external nonReentrant moreThanZero(amount) {
        require(s_accountToTokenDeposits[msg.sender][token] >= 0, "Insufficient token");
        _pullFunds(msg.sender, token, amount);
        require(healthFactor(msg.sender) >= MIN_HEALTH_FACTOR, "Platform will go insolvent");
    }

    // @notice Pull fund function
    function _pullFunds(address account, address token, uint256 amount) private {
        require(s_accountToTokenDeposits[account][token] >= amount, "Insufficient Balance");
        s_accountToTokenDeposits[account][token] -= amount;
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
    }

    // @notice Function to borrow
    function borrow(address token, uint256 amount) external nonReentrant isAllowedToken(token) moreThanZero(amount) {
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient token");
        require(healthFactor(msg.sender) > MIN_HEALTH_FACTOR, "Platform will go insolvent");
        s_accountToTokenBorrows[msg.sender][token] += amount;
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
        emit Borrow(msg.sender, token, amount);
    }

    // @notice Function to liquidate
    function liquidate(address account, address repayToken, address rewardToken) external nonReentrant {
        require(healthFactor(msg.sender) < MIN_HEALTH_FACTOR, "Account cannot be liquidated");
        uint256 halfDebt = s_accountToTokenBorrows[account][repayToken] / 2;
        uint256 halfDebtInEth = getEthValue(repayToken, halfDebt);
        require(halfDebtInEth > 0, "Choose another repay token!");
        uint256 rewardAmountInEth = (halfDebtInEth * LIQUIDATION_REWARD) / 100;
        uint256 totalRewardAmountInRewardToken = getTokenValueFromEth(rewardToken, rewardAmountInEth + halfDebtInEth);
        emit Liquidate(account, repayToken, rewardToken, halfDebtInEth, msg.sender);
        _repay(account, repayToken, halfDebt);
        _pullFunds(account, rewardToken, totalRewardAmountInRewardToken);
    }

    function repay(address token, uint256 amount) external nonReentrant isAllowedToken(token) moreThanZero(amount) {
        
    }

    // @notice Helper functions
    function getEthValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (uint256(price) * amount) / 1e18;
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInEth = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            uint256 amount = s_accountToTokenDeposits[user][token];
            uint256 valueInEth = getEthValue(token, amount);
            totalCollateralValueInEth += valueInEth;
        }
        return totalCollateralValueInEth;
    }

    function getAccountBorrowedValue(address user) public view returns (uint256) {
        uint256 totalBorrowsInEth = 0;
        for(uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            uint256 amount = s_accountToTokenBorrows[user][token];
            uint256 valueInEth = getEthValue(token, amount);
            totalBorrowsInEth += valueInEth;
        }
        return totalBorrowsInEth;
    }

    function getAccountInformation(address user) public view returns (uint256 borrowedValueInEth, uint256 collateralValueInEth) {
        borrowedValueInEth = getAccountBorrowedValue(user);
        collateralValueInEth = getAccountCollateralValue(user);
    }

    function getTokenValueFromEth(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (,int256 price, , , ) = priceFeed.latestRoundData();
        return (amount * 1e18 / uint256(price));
    }

    function healthFactor(address account) public view returns (uint256) {
        (uint256 borrowedValueInEth, uint256 collateralValueInEth) = getAccountInformation(account);
        uint256 collateralAdjustedForThreshold = (collateralValueInEth * LIQUIDATION_THRESHOLD) / 100;
        if (borrowedValueInEth == 0) return 100e18;
        return (collateralAdjustedForThreshold * 1e18)/ borrowedValueInEth;
    }
}

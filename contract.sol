// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract WalletCommitment {
    address public owner;
    uint256 public commitmentAmount;
    uint256 public totalPaid;
    uint256 public startTime;
    uint256 public callInterval;
    uint8 public totalCalls;

    AggregatorV3Interface internal ethUsdPriceFeed;

    mapping(uint8 => bool) public callExecuted;

    event PaymentMade(address indexed payer, uint256 amount, uint256 timestamp);
    event CallExecuted(uint8 indexed callNumber, uint256 timestamp);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    modifier validCall(uint8 callNumber) {
        require(
            callNumber > 0 && callNumber <= totalCalls,
            "Invalid call number"
        );
        require(!callExecuted[callNumber], "Call already executed");
        require(
            block.timestamp >= startTime + callNumber * callInterval,
            "Call not yet due"
        );
        _;
    }

    constructor(
        uint256 _commitmentAmount,
        uint256 _callInterval,
        uint8 _totalCalls
    ) {
        ethUsdPriceFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);
        require(
            _commitmentAmount >= 1_000_000 ether,
            "Commitment amount must be at least $1M in USD"
        );
        require(_totalCalls > 0, "There must be at least one call for cash");

        //Sepolia testnet: 0x694AA1769357215DE4FAC081bf1f309aDC325306
        //Ethereum mainnet: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419

        owner = msg.sender;
        commitmentAmount = _commitmentAmount;
        callInterval = _callInterval;
        totalCalls = _totalCalls;
        startTime = block.timestamp;
    }

    function makePayment() external payable {
        require(msg.value > 0, "Payment must be greater than 0");
        totalPaid += msg.value;
        emit PaymentMade(msg.sender, msg.value, block.timestamp);
    }

    function getETHUSDCExchangeRate() public view returns (uint256) {
        (, int256 ethUsdPrice, , , ) = ethUsdPriceFeed.latestRoundData();

        require(ethUsdPrice > 0, "Invalid price data");

        // Chainlink price feeds typically return prices with 8 decimals.
        // To maintain precision, we scale the result by 1e18.
        uint256 ethUsd = uint256(ethUsdPrice);

        return ethUsd;
    }

    function executeCall(
        uint8 callNumber
    ) external onlyOwner validCall(callNumber) {
        callExecuted[callNumber] = true;
        emit CallExecuted(callNumber, block.timestamp);
    }

    function getRemainingCommitment() public view returns (uint256) {
        if (totalPaid >= commitmentAmount) {
            return 0;
        }
        return commitmentAmount - totalPaid;
    }

    function isCallDue(uint8 callNumber) public view returns (bool) {
        if (callExecuted[callNumber]) return false;
        return block.timestamp >= startTime + callNumber * callInterval;
    }

    // Function to receive ETH into the contract
    receive() external payable {}

    function disburseETH(address payable recipient, uint256 amount) external onlyOwner {
        require(recipient != address(0), "Invalid recipient address");
        require(address(this).balance >= amount, "Insufficient balance in contract");

        // Transfer ETH to the recipient
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Transfer failed");
    }
}

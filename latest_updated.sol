// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract LPManagement is Ownable(msg.sender), Pausable, ReentrancyGuard {
    // Aggregator for ETH-USD price feed
    AggregatorV3Interface internal ethUsdPriceFeed;

    // Struct to store Limited Partner data
    struct LPData {
        uint256 commitmentAmount;  // Total commitment by the LP
        uint256 totalPaid;         // Amount already paid
        uint256 remainingCommitment; // Remaining amount to be paid
        mapping(uint8 => uint256) trancheCommitments; // Commitment amount per tranche
        mapping(uint8 => uint256) tranchePayments;    // Payments made per tranche
    }

    // Struct to store Cash Call data
    struct CashCall {
        uint256 amount;   // Amount requested in the cash call
        uint256 callInterval;  // Call interval duration
        bool executed;    // Whether the cash call has been executed
    }

    // Mappings
    mapping(address => LPData) public lpData;         // LP data by address
    mapping(uint256 => CashCall) public cashCalls;    // Cash calls by ID

    uint256 public totalCashCalls; // Total number of cash calls created

    // Events
    event CommitmentSet(address indexed lp, uint256 amount);
    event PaymentMade(address indexed lp, uint256 amount, uint8 tranche);
    event CashCallCreated(uint256 indexed callId, uint256 amount, uint256 callInterval);
    event CashCallExecuted(uint256 indexed callId);
    event PenaltyApplied(address indexed lp, uint256 penaltyAmount);
    event TranchesForfeited(address indexed lp);
    event AccessRevoked(address indexed lp);
    event Withdrawal(address indexed to, uint256 amount);

    constructor(address _aggregatorAddress) {
        require(_aggregatorAddress != address(0), "Invalid aggregator address");
        ethUsdPriceFeed = AggregatorV3Interface(_aggregatorAddress);
    }

    // Get ETH-USD exchange rate
    function getETHUSDCExchangeRate() public view returns (uint256) {
        (, int256 ethUsdPrice, , , ) = ethUsdPriceFeed.latestRoundData();
        require(ethUsdPrice > 0, "Invalid ETH/USD price data");

        // Chainlink price feeds typically return prices with 8 decimals.
        return uint256(ethUsdPrice) * 1e10; // Adjust to 18 decimals for consistency
    }

    // Set commitment for a Limited Partner (Admin only)
    function setCommitment(address lp, uint256 amount, uint8 totalTranches) external onlyOwner whenNotPaused {
        require(lp != address(0), "Invalid LP address");
        require(amount > 0, "Commitment amount must be greater than zero");
        require(totalTranches > 0, "Total tranches must be greater than zero");

        LPData storage lpInfo = lpData[lp];
        lpInfo.commitmentAmount = amount;
        lpInfo.totalPaid = 0;
        lpInfo.remainingCommitment = amount;

        uint256 trancheAmount = amount / totalTranches;
        for (uint8 i = 0; i < totalTranches; i++) {
            lpInfo.trancheCommitments[i] = trancheAmount;
        }

        emit CommitmentSet(lp, amount);
    }

    // Create a new cash call (Admin only)
    function createCashCall(uint256 amount, uint256 callInterval) external onlyOwner whenNotPaused {
        require(amount > 0, "Cash call amount must be greater than zero");
        require(callInterval > 0, "Call interval must be greater than zero");

        cashCalls[totalCashCalls] = CashCall({
            amount: amount,
            callInterval: callInterval,
            executed: false
        });

        emit CashCallCreated(totalCashCalls, amount, callInterval);
        totalCashCalls++;
    }

    // Make a payment as an LP
    function makePayment(uint8 tranche) external payable whenNotPaused nonReentrant {
        LPData storage lp = lpData[msg.sender];
        require(lp.commitmentAmount > 0, "You are not an LP");
        require(lp.trancheCommitments[tranche] > 0, "Invalid tranche");
        require(lp.trancheCommitments[tranche] >= lp.tranchePayments[tranche] + msg.value, "Overpayment not allowed");

        lp.totalPaid += msg.value;
        lp.remainingCommitment -= msg.value;
        lp.tranchePayments[tranche] += msg.value;

        emit PaymentMade(msg.sender, msg.value, tranche);
    }

    // Execute a cash call (Admin only)
    function executeCashCall(uint256 callId) external onlyOwner whenNotPaused {
        CashCall storage call = cashCalls[callId];
        require(call.amount > 0, "Cash call does not exist");
        require(!call.executed, "Cash call already executed");
        require(block.timestamp >= call.callInterval, "Cash call is not yet due");

        call.executed = true;

        emit CashCallExecuted(callId);
    }

    // Apply penalties for missed deadlines
    function applyPenalty(address lp, uint8 tranche, uint256 penaltyAmount, bool revokeAccess) external onlyOwner whenNotPaused {
        LPData storage lpInfo = lpData[lp];
        require(lpInfo.commitmentAmount > 0, "Invalid LP");
        require(lpInfo.trancheCommitments[tranche] > 0, "Invalid tranche");

        // Forfeit prior tranches
        for (uint8 i = 0; i < tranche; i++) {
            lpInfo.trancheCommitments[i] = 0;
            lpInfo.tranchePayments[i] = 0;
        }
        emit TranchesForfeited(lp);

        // Apply late fee
        lpInfo.remainingCommitment += penaltyAmount;
        emit PenaltyApplied(lp, penaltyAmount);

        // Revoke access if applicable
        if (revokeAccess) {
            lpInfo.commitmentAmount = 0;
            lpInfo.remainingCommitment = 0;
            emit AccessRevoked(lp);
        }
    }

    // Check if a cash call is due
    function isCallDue(uint256 callId) external view whenNotPaused returns (bool) {
        CashCall storage call = cashCalls[callId];
        return block.timestamp >= call.callInterval && !call.executed;
    }

    // Pause the contract (Admin only)
    function pause() external onlyOwner {
        _pause();
    }

    // Unpause the contract (Admin only)
    function unpause() external onlyOwner {
        _unpause();
    }

    // Withdraw Ether from the contract (Admin only)
    function withdraw(uint256 amount) external onlyOwner whenNotPaused nonReentrant {
        require(amount <= address(this).balance, "Insufficient balance in contract");
        payable(owner()).transfer(amount);
        emit Withdrawal(owner(), amount);
    }

    // Fallback function to receive Ether
    receive() external payable whenNotPaused {}
}
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
        mapping(uint8 => uint256) tranchePayments;    // Payments made per tranche
    }

    // Struct to store tranche details
    struct TrancheDetails {
        uint256 percentage; // Percentage of the commitment for this tranche
        uint256 deadline;     // Period (in seconds) after which this tranche is due
    }

    uint256 public minCommitmentAmountUSD = 1000 * 10**18;

    // Struct to store Cash Call data
    struct CashCall {
        uint256 amount;   // Amount requested in the cash call
        uint256 callInterval;  // Call interval duration
        bool executed;    // Whether the cash call has been executed
    }

    // Mappings
    mapping(address => LPData) public lpData;         // LP data by address
    mapping(address => TrancheDetails[]) public lpTranches;   // Tranche details per LP
    mapping(uint256 => CashCall) public cashCalls;    // Cash calls by ID

    uint256 public totalCashCalls; // Total number of cash calls created

    // Events
    event CommitmentSet(address indexed lp, uint256 amountETH);
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
    function setCommitment(
        address lp,
        uint256 amountETH,
        uint8[] memory percentages,
        uint256[] memory periods
    ) external onlyOwner whenNotPaused {
        require(lp != address(0), "Invalid LP address");
        require(amountETH * getETHUSDCExchangeRate() >= minCommitmentAmountUSD * 10**18, "Commitment amount must be greater than minimum amount");
        require(percentages.length > 0, "Percentages must not be empty");
        require(percentages.length == periods.length, "Percentages and periods must match");

        uint256 totalPercentage;
        for (uint8 i = 0; i < percentages.length; i++) {
            totalPercentage += percentages[i];
        }
        require(totalPercentage == 100, "Total percentage must equal 100");

        // Initialize LP data
        LPData storage lpInfo = lpData[lp];
        lpInfo.commitmentAmount = amountETH;
        lpInfo.totalPaid = 0;
        lpInfo.remainingCommitment = amountETH;

        // Set tranche details
        delete lpTranches[lp]; // Reset existing tranche details for the LP
        for (uint8 i = 0; i < percentages.length; i++) {
            lpTranches[lp].push(TrancheDetails({
                percentage: percentages[i],
                deadline: block.timestamp + (periods[i] * 1 days)
            }));
        }

        emit CommitmentSet(lp, amountETH);
    }

    // Get all tranches periods and amounts
    function getLPTranches(address lp) external view returns (uint256[] memory trancheDeadlines, uint256[] memory trancheAmounts) {
        TrancheDetails[] storage tranches = lpTranches[lp];
        LPData storage lpInfo = lpData[lp];
        require(lpInfo.commitmentAmount > 0, "Invalid LP");

        uint256 trancheCount = tranches.length;

        trancheDeadlines = new uint256[](trancheCount);
        trancheAmounts = new uint256[](trancheCount);

        for (uint8 i = 0; i < trancheCount; i++) {
            // Get tranche period
            trancheDeadlines[i] = tranches[i].deadline;

            // Calculate tranche amount based on the percentage
            trancheAmounts[i] = (lpInfo.commitmentAmount * tranches[i].percentage) / 100;
        }

        return (trancheDeadlines, trancheAmounts);
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
        require(tranche < lpTranches[msg.sender].length, "Invalid tranche");

        TrancheDetails memory trancheDetails = lpTranches[msg.sender][tranche];
        uint256 trancheCommitment = (lp.commitmentAmount * trancheDetails.percentage) / 100;

        require(lp.tranchePayments[tranche] + msg.value <= trancheCommitment, "Overpayment not allowed");
        require(block.timestamp <= trancheDetails.deadline, "Tranche date was expired");

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

        // Forfeit prior tranches
        for (uint8 i = 0; i < tranche; i++) {
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

    // Set the minimun amount of commitment
    function setMinCommitmentAmountUSD(uint256 minAmount) external onlyOwner whenNotPaused {
        require(minAmount > 0, "Minimum commitment amount must be greater than zero");
        minCommitmentAmountUSD = minAmount;
    }

    // Get next tranche data
    function getNextTranche(address lp) external view returns (uint256 nextPercentage, uint256 nextDeadline) {
        TrancheDetails[] storage tranches = lpTranches[lp];
        require(tranches.length > 0, "No tranches set for this LP");

        for (uint8 i = 0; i < tranches.length; i++) {
            if (block.timestamp < tranches[i].deadline) {
                return (tranches[i].percentage, tranches[i].deadline);
            }
        }

        revert("No upcoming tranche found");
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
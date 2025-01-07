// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract LPManagement is Pausable, ReentrancyGuard {
    // Store the list of admins
    address[] private admins;
    mapping(address => bool) private isAdmin;

    // Address of the default admin (can only add/remove admins and set new default admin)
    address private defaultAdmin;

    // Aggregator for ETH-USD price feed
    AggregatorV3Interface internal ethUsdPriceFeed;

    // Struct to store Limited Partner data
    struct LPData {
        uint256 commitmentAmount;  // Total commitment by the LP
        uint256 totalPaid;         // Amount already paid
        uint256 endTime; // Commitment Period
    }

    uint256 public minCommitmentAmountUSD = 1000 * 10**18;

    // Struct to store Cash Call data
    struct CashCall {
        uint256 amount;   // Amount requested in the cash call
        uint256 paidAmount;   // Amount paid towards the cash call
        uint256 deadline;  // Call interval duration
        bool executed;    // Whether the cash call has been executed
    }

    // Mappings
    mapping(address => LPData) public lpData;         // LP data by address
    mapping(address => CashCall[]) public cashCalls;    // Cash calls by LP address

    // Events
    event CommitmentSet(address indexed lp, uint256 amountETH, uint256 endTime);
    event PaymentMade(address indexed lp, uint256 amount, uint256 callId);
    event CashCallCreated(uint256 callId, uint256 amount, uint256 deadline);
    event CashCallExecuted(address indexed lp, uint256 callId);
    event CashCallExecutionReverted(address indexed lp, uint256 callId);
    event PenaltyApplied(address indexed lp, uint256 penaltyAmount);
    event AccessRevoked(address indexed lp);
    event Withdrawal(address indexed to, uint256 amount);
    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event DefaultAdminChanged(address indexed oldAdmin, address indexed newAdmin);

    constructor(address _aggregatorAddress, address _defaultAdmin) {
        require(_aggregatorAddress != address(0), "Invalid aggregator address");
        require(_defaultAdmin != address(0), "Invalid default admin address");
        
        ethUsdPriceFeed = AggregatorV3Interface(_aggregatorAddress);
        defaultAdmin = _defaultAdmin;

        // Initially, set the default admin as the only admin
        addAdmin(_defaultAdmin);
    }

    // Check if sender is the default admin
    modifier onlyDefaultAdmin() {
        require(msg.sender == defaultAdmin, "Not authorized: Only default admin can perform this action");
        _;
    }

    // Check if sender is an admin
    function isAdminRole() public view returns (bool) {
        return isAdmin[msg.sender];
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
        address _lp,
        uint256 _amountETH,
        uint256 _endTime
    ) external whenNotPaused {
        require(isAdminRole(), "Not authorized");
        require(_lp != address(0), "Invalid LP address");
        require(!isLP(_lp), "LP already exists");
        require(_amountETH * getETHUSDCExchangeRate() >= minCommitmentAmountUSD * 10**18, "Commitment amount must be greater than minimum amount");
        require(_endTime > block.timestamp, "End Time must be later than the current time.");

        // Initialize LP data
        LPData storage lpInfo = lpData[_lp];
        lpInfo.commitmentAmount = _amountETH;
        lpInfo.totalPaid = 0;
        lpInfo.endTime = _endTime;

        emit CommitmentSet(_lp, _amountETH, _endTime);
    }

    // Create a new cash call (Admin only)
    function createCashCall(address _lp, uint256 _amount, uint256 _deadline) external whenNotPaused {
        require(isAdminRole(), "Not authorized");
        require(isLP(_lp), "Not an LP!");
        require(_amount > 0, "Cash call amount must be greater than zero");
        require(_deadline > block.timestamp && _deadline <= lpData[_lp].endTime, "Deadline must be later than the current time.");
        // Check if there are existing cash calls and compare with the last one
        CashCall[] storage existingCalls = cashCalls[_lp];
        if (existingCalls.length > 0) {
            uint256 lastDeadline = existingCalls[existingCalls.length - 1].deadline;
            require(_deadline > lastDeadline, "New deadline must be after the last deadline");
        }

        // Add the new CashCall
        cashCalls[_lp].push(CashCall(_amount, 0, _deadline, false));  // Add the new CashCall with initial values
        emit CashCallCreated(existingCalls.length, _amount, _deadline);
    }

    // Make a payment (LP only)
    function makePayment(address _lp, uint256 _callId) external payable whenNotPaused nonReentrant {
        require(isLP(_lp), "You are not an LP");

        // Retrieve the cash call for the LP and call ID
        CashCall storage cashCall = cashCalls[_lp][_callId];
        require(cashCall.amount > 0, "Cash call does not exist");

        // Check if the cash call has been executed or if the deadline has passed
        require(!cashCall.executed, "Cash call already executed");

        // Update the paid amount for the cash call
        cashCall.paidAmount += msg.value;

        // Update LP Data
        lpData[msg.sender].totalPaid += msg.value;

        // Emit an event to notify that payment has been made
        emit PaymentMade(_lp, msg.value, _callId);
    }

    // Execute a cash call (Admin only)
    function executeCashCall(address _lp, uint256 _callId) external whenNotPaused {
        require(isAdminRole(), "Not authorized");
        CashCall storage call = cashCalls[_lp][_callId];
        require(call.amount > 0, "Cash call does not exist");
        require(!call.executed, "Cash call already executed");

        // Execute the cash call logic
        call.executed = true;

        emit CashCallExecuted(_lp, _callId);
    }

    // Revert the execution of a cash call (Admin only)
    function revertExecution(address _lp, uint256 _callId) external whenNotPaused {
        require(isAdminRole(), "Not authorized");
        require(isLP(_lp), "Not an LP!");
        CashCall storage call = cashCalls[_lp][_callId];
        require(call.amount > 0, "Cash call does not exist");
        require(call.executed, "Cash call not executed yet");

        // Revert the executed flag back to false
        call.executed = false;

        emit CashCallExecutionReverted(_lp, _callId);
    }

    // Apply penalties for missed deadlines (Admin only)
    function applyPenalty(address _lp, uint256 _penaltyAmount, bool _revokeAccess) external whenNotPaused {
        require(isAdminRole(), "Not authorized");
        LPData storage lpInfo = lpData[_lp];
        require(lpInfo.commitmentAmount > 0, "Invalid LP");

        // Apply late fee
        lpInfo.totalPaid -= _penaltyAmount;
        emit PenaltyApplied(_lp, _penaltyAmount);

        // Revoke access if applicable
        if (_revokeAccess) {
            lpInfo.commitmentAmount = 0;
            lpInfo.totalPaid = 0;
            emit AccessRevoked(_lp);
        }
    }

    // Add a new admin (only default admin)
    function addAdmin(address _account) public onlyDefaultAdmin {
        require(_account != address(0), "Invalid address");
        require(!isAdmin[_account], "Already an admin");

        // Add the new admin
        admins.push(_account);
        isAdmin[_account] = true;

        emit AdminAdded(_account);
    }

    // Remove an admin (only default admin)
    function removeAdmin(address _account) public onlyDefaultAdmin {
        require(isAdmin[_account], "Not an admin");

        // Prevent removing the last admin
        require(admins.length > 1, "Cannot remove the last admin");

        // Remove admin
        isAdmin[_account] = false;

        // Remove from the admins array
        for (uint256 i = 0; i < admins.length; i++) {
            if (admins[i] == _account) {
                admins[i] = admins[admins.length - 1];
                admins.pop();
                break;
            }
        }

        emit AdminRemoved(_account);
    }

    // Set a new default admin (only the current default admin)
    function setDefaultAdmin(address _newDefaultAdmin) public onlyDefaultAdmin {
        require(_newDefaultAdmin != address(0), "Invalid address for new default admin");

        address oldAdmin = defaultAdmin;
        defaultAdmin = _newDefaultAdmin;

        emit DefaultAdminChanged(oldAdmin, _newDefaultAdmin);
    }

    // Check if an LP address exists in lpData
    function isLP(address _lp) public view returns (bool) {
        return lpData[_lp].commitmentAmount > 0;
    }

    // Pause the contract (Admin only)
    function pause() external {
        require(isAdminRole(), "Not authorized");
        _pause();
    }

    // Unpause the contract (Admin only)
    function unpause() external {
        require(isAdminRole(), "Not authorized");
        _unpause();
    }

    // Withdraw Ether from the contract (Admin only)
    function withdraw(uint256 _amount, address _to) external nonReentrant {
        require(isAdminRole(), "Not authorized");
        require(_amount <= address(this).balance, "Insufficient balance in contract");
        payable(_to).transfer(_amount);
        emit Withdrawal(_to, _amount);
    }

    // Fallback function to receive Ether
    receive() external payable whenNotPaused {}
}

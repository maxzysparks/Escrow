// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract EnhancedEscrowContract is 
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable 
{
    using Counters for Counters.Counter;

    // Version control
    string public constant VERSION = "1.0.0";
    
    // Constants
    uint256 public constant MINIMUM_INVESTMENT = 0.1 ether;
    uint256 public constant MAXIMUM_INVESTMENT = 1000 ether;
    uint256 public constant PLATFORM_FEE_PERCENTAGE = 2;
    uint256 public constant MINIMUM_FUNDING_PERIOD = 1 days;
    uint256 public constant MAXIMUM_FUNDING_PERIOD = 30 days;
    uint256 public constant COOLING_PERIOD = 1 days;
    uint256 public constant MAX_TRANSACTIONS_PER_HOUR = 100;
    uint256 public constant EMERGENCY_WITHDRAWAL_TIMELOCK = 2 days;

    // State variables
    Counters.Counter private _investmentIds;
    address public feeCollector;
    mapping(address => uint256) public hourlyTransactionCount;
    mapping(address => uint256) public lastTransactionTimestamp;
    mapping(address => uint256) public userInvestmentCount;
    uint256 public maxInvestmentsPerUser;
    bool private _emergencyWithdrawalInitiated;
    uint256 private _emergencyWithdrawalTimestamp;
    
    // Optimized struct packing
    struct Investment {
        uint96 amount;             // 12 bytes
        uint8 equityPercentage;    // 1 byte
        uint8 status;              // 1 byte
        uint8 disputeStatus;       // 1 byte
        bool isActive;             // 1 byte
        // Start new slot
        uint256 fundingDeadline;   // 32 bytes
        uint256 valuation;         // 32 bytes
        uint256 createdAt;         // 32 bytes
        uint256 lastUpdated;       // 32 bytes
        bytes32 startupName;       // 32 bytes
        bytes32 description;       // 32 bytes
        address payable investor;   // 20 bytes
        address payable startup;    // 20 bytes
    }

    struct Dispute {
        string reason;
        address initiator;
        uint256 timestamp;
        string resolution;
    }

    // Mappings
    mapping(uint256 => Investment) public investments;
    mapping(uint256 => Dispute) public disputes;
    mapping(address => uint256[]) public userInvestments;
    mapping(bytes32 => bool) public commitments;
    mapping(uint256 => uint256) public investmentCoolingPeriod;
    
    // Events
    event InvestmentCreated(
        uint256 indexed investmentId,
        uint256 amount,
        uint8 equityPercentage,
        address indexed investor,
        address indexed startup
    );
    event InvestmentFunded(uint256 indexed investmentId, address funder, uint256 amount);
    event InvestmentRepaid(uint256 indexed investmentId, uint256 amount);
    event DisputeRaised(uint256 indexed investmentId, address indexed raiser, string reason);
    event DisputeResolved(uint256 indexed investmentId, string resolution);
    event FeeCollected(uint256 indexed investmentId, uint256 amount);
    event EmergencyWithdrawalInitiated(address indexed initiator, uint256 timestamp);
    event EmergencyWithdrawalExecuted(address indexed executor, uint256 amount);
    event RateLimitExceeded(address indexed user, uint256 attemptedAt);

    // Custom errors
    error InvalidAmount(uint256 amount, uint256 minimum, uint256 maximum);
    error InvalidEquityPercentage(uint8 percentage);
    error InvalidFundingPeriod(uint256 period);
    error UnauthorizedAccess();
    error RateLimitReached();
    error CoolingPeriodActive();
    error MaxInvestmentsReached();
    error EmergencyWithdrawalNotReady();
    error InvalidAddress();
    error ContractPaused();

    // Modifiers
    modifier rateLimited() {
        if (block.timestamp - lastTransactionTimestamp[msg.sender] >= 1 hours) {
            hourlyTransactionCount[msg.sender] = 0;
        }
        if (hourlyTransactionCount[msg.sender] >= MAX_TRANSACTIONS_PER_HOUR) {
            emit RateLimitExceeded(msg.sender, block.timestamp);
            revert RateLimitReached();
        }
        hourlyTransactionCount[msg.sender]++;
        lastTransactionTimestamp[msg.sender] = block.timestamp;
        _;
    }

    modifier coolingPeriodComplete(uint256 _investmentId) {
        if (block.timestamp < investmentCoolingPeriod[_investmentId]) {
            revert CoolingPeriodActive();
        }
        _;
    }

    modifier validAddress(address _address) {
        if (_address == address(0)) {
            revert InvalidAddress();
        }
        _;
    }

    function initialize(address _feeCollector) public initializer {
        __ReentrancyGuard_init();
        __Ownable_init();
        __Pausable_init();
        
        if (_feeCollector == address(0)) revert InvalidAddress();
        feeCollector = _feeCollector;
        maxInvestmentsPerUser = 5; // Default value
    }

    function createInvestment(
        uint96 _amount,
        uint8 _equityPercentage,
        bytes32 _startupName,
        bytes32 _description,
        uint256 _valuation,
        uint256 _fundingPeriod
    ) 
        external 
        payable 
        whenNotPaused
        nonReentrant
        rateLimited
        validAddress(msg.sender)
    {
        if (_amount < MINIMUM_INVESTMENT || _amount > MAXIMUM_INVESTMENT) {
            revert InvalidAmount(_amount, MINIMUM_INVESTMENT, MAXIMUM_INVESTMENT);
        }
        if (_equityPercentage == 0 || _equityPercentage > 100) {
            revert InvalidEquityPercentage(_equityPercentage);
        }
        if (userInvestmentCount[msg.sender] >= maxInvestmentsPerUser) {
            revert MaxInvestmentsReached();
        }

        uint256 investmentId = _investmentIds.current();
        _investmentIds.increment();

        investments[investmentId] = Investment({
            amount: _amount,
            equityPercentage: _equityPercentage,
            status: 0, // Active
            disputeStatus: 0, // None
            isActive: true,
            fundingDeadline: block.timestamp + _fundingPeriod,
            valuation: _valuation,
            createdAt: block.timestamp,
            lastUpdated: block.timestamp,
            startupName: _startupName,
            description: _description,
            investor: payable(msg.sender),
            startup: payable(address(0))
        });

        userInvestments[msg.sender].push(investmentId);
        userInvestmentCount[msg.sender]++;
        investmentCoolingPeriod[investmentId] = block.timestamp + COOLING_PERIOD;

        emit InvestmentCreated(
            investmentId,
            _amount,
            _equityPercentage,
            msg.sender,
            address(0)
        );
    }

    function initiateEmergencyWithdrawal() external onlyOwner whenPaused {
        _emergencyWithdrawalInitiated = true;
        _emergencyWithdrawalTimestamp = block.timestamp + EMERGENCY_WITHDRAWAL_TIMELOCK;
        emit EmergencyWithdrawalInitiated(msg.sender, _emergencyWithdrawalTimestamp);
    }

    function executeEmergencyWithdrawal() external onlyOwner whenPaused {
        if (!_emergencyWithdrawalInitiated || 
            block.timestamp < _emergencyWithdrawalTimestamp) {
            revert EmergencyWithdrawalNotReady();
        }

        uint256 balance = address(this).balance;
        payable(owner()).transfer(balance);
        
        _emergencyWithdrawalInitiated = false;
        emit EmergencyWithdrawalExecuted(msg.sender, balance);
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function isContract(address _addr) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }

    // Prevent direct transfers
    receive() external payable {
        revert("Direct transfers not allowed");
    }

    function getVersion() external pure returns (string memory) {
        return VERSION;
    }

    // Gap for future upgrades
    uint256[50] private __gap;
}
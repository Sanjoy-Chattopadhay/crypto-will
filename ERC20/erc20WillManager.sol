// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC20WillManager is Ownable, ReentrancyGuard {
    
    // Death detection timeout (30 days for production, 1 minute for testing)
    uint256 public deathTimeout = 30 days;
    
    // Struct to store will information
    struct Will {
        address tokenContract;          // ERC20 token contract address
        address heir;                   // Designated heir address
        uint256 lastHeartbeat;         // Timestamp of owner's last heartbeat
        bool isActive;                 // Will activation status
        bool inheritanceExecuted;      // Prevents double execution
        bool heirConfirmed;           // Heir acceptance confirmation
        uint256 inheritanceAmount;    // Amount to inherit (0 = all balance)
        string willMessage;           // Optional message to heir
    }
    
    // Mapping of owner address to their will
    mapping(address => Will) public wills;
    
    // Mapping to track trustees for multi-sig approval
    mapping(address => address[]) public trustees;
    mapping(address => mapping(address => bool)) public trusteeApprovals;
    mapping(address => uint256) public requiredTrusteeSignatures;
    
    // Events
    event WillCreated(address indexed owner, address indexed heir, address tokenContract);
    event HeartbeatRecorded(address indexed owner, uint256 timestamp);
    event InheritanceExecuted(address indexed owner, address indexed heir, uint256 amount);
    event HeirConfirmed(address indexed heir, address indexed owner);
    event TrusteeAdded(address indexed owner, address indexed trustee);
    event TrusteeApproval(address indexed trustee, address indexed owner, bool approved);
    event DeathTimeoutUpdated(uint256 newTimeout);
    
    constructor() Ownable(msg.sender) {
        // Set testing timeout (1 minute for quick testing)
        deathTimeout = 1 minutes;
    }
    
    /**
     * @dev Create a will for ERC20 tokens
     * @param _tokenContract ERC20 token contract address
     * @param _heir Designated heir address
     * @param _inheritanceAmount Amount to inherit (0 for full balance)
     * @param _willMessage Optional message to heir
     */
    function createWill(
        address _tokenContract,
        address _heir,
        uint256 _inheritanceAmount,
        string memory _willMessage
    ) external {
        require(_tokenContract != address(0), "Invalid token contract");
        require(_heir != address(0), "Invalid heir address");
        require(_heir != msg.sender, "Cannot be your own heir");
        
        IERC20 token = IERC20(_tokenContract);
        require(token.balanceOf(msg.sender) > 0, "Must own tokens to create will");
        
        wills[msg.sender] = Will({
            tokenContract: _tokenContract,
            heir: _heir,
            lastHeartbeat: block.timestamp,
            isActive: true,
            inheritanceExecuted: false,
            heirConfirmed: false,
            inheritanceAmount: _inheritanceAmount,
            willMessage: _willMessage
        });
        
        emit WillCreated(msg.sender, _heir, _tokenContract);
        emit HeartbeatRecorded(msg.sender, block.timestamp);
    }
    
    /**
     * @dev Record heartbeat to prove owner is alive
     */
    function recordHeartbeat() external {
        require(wills[msg.sender].isActive, "No active will found");
        
        wills[msg.sender].lastHeartbeat = block.timestamp;
        emit HeartbeatRecorded(msg.sender, block.timestamp);
    }
    
    /**
     * @dev Heir confirms acceptance of inheritance
     * @param _owner Address of the will owner
     */
    function confirmHeirship(address _owner) external {
        require(wills[_owner].heir == msg.sender, "Not the designated heir");
        require(wills[_owner].isActive, "Will is not active");
        require(!wills[_owner].heirConfirmed, "Already confirmed");
        
        wills[_owner].heirConfirmed = true;
        emit HeirConfirmed(msg.sender, _owner);
    }
    
    /**
     * @dev Add trustee for multi-signature approval
     * @param _trustee Address of the trustee
     */
    function addTrustee(address _trustee) external {
        require(_trustee != address(0), "Invalid trustee address");
        require(_trustee != msg.sender, "Cannot be your own trustee");
        require(wills[msg.sender].isActive, "No active will found");
        
        trustees[msg.sender].push(_trustee);
        emit TrusteeAdded(msg.sender, _trustee);
    }
    
    /**
    * @dev Set required number of trustee signatures (can be zero for no trustee approvals)
    * @param _required Number of required signatures
    */
    function setRequiredTrusteeSignatures(uint256 _required) external {
        require(wills[msg.sender].isActive, "No active will found");
        require(_required <= trustees[msg.sender].length, "Cannot require more signatures than trustees");
        
        // Allow zero required signatures to mean no trustee approvals needed
        requiredTrusteeSignatures[msg.sender] = _required;
    }

    
    /**
     * @dev Trustee approves inheritance execution
     * @param _owner Address of the will owner
     * @param _approve True to approve, false to deny
     */
    function trusteeApproval(address _owner, bool _approve) external {
        require(wills[_owner].isActive, "Will is not active");
        require(isTrustee(_owner, msg.sender), "Not a trustee for this will");
        
        trusteeApprovals[_owner][msg.sender] = _approve;
        emit TrusteeApproval(msg.sender, _owner, _approve);
    }
    
    /**
     * @dev Check if address is a trustee for owner
     * @param _owner Will owner address
     * @param _trustee Potential trustee address
     * @return bool True if trustee
     */
    function isTrustee(address _owner, address _trustee) public view returns (bool) {
        address[] memory ownerTrustees = trustees[_owner];
        for (uint256 i = 0; i < ownerTrustees.length; i++) {
            if (ownerTrustees[i] == _trustee) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @dev Check if enough trustees have approved
     * @param _owner Will owner address
     * @return bool True if sufficient approvals
     */
    function hasSufficientTrusteeApprovals(address _owner) public view returns (bool) {
        uint256 required = requiredTrusteeSignatures[_owner];
        if (required == 0) return true; // No trustees required
        
        uint256 approvals = 0;
        address[] memory ownerTrustees = trustees[_owner];
        
        for (uint256 i = 0; i < ownerTrustees.length; i++) {
            if (trusteeApprovals[_owner][ownerTrustees[i]]) {
                approvals++;
            }
        }
        
        return approvals >= required;
    }
    
    /**
     * @dev Check if owner is considered dead
     * @param _owner Address to check
     * @return bool True if dead
     */
    function isOwnerDead(address _owner) public view returns (bool) {
        Will memory will = wills[_owner];
        if (!will.isActive) return false;
        return (block.timestamp - will.lastHeartbeat) >= deathTimeout;
    }
    
    /**
     * @dev Execute inheritance transfer
     * @param _deadOwner Address of deceased owner
     */
    function executeInheritance(address _deadOwner) external nonReentrant {
        Will storage will = wills[_deadOwner];
        
        require(will.isActive, "Will is not active");
        require(will.heir == msg.sender, "Only heir can execute");
        require(isOwnerDead(_deadOwner), "Owner is not dead yet");
        require(!will.inheritanceExecuted, "Already executed");
        require(will.heirConfirmed, "Heir must confirm first");
        require(hasSufficientTrusteeApprovals(_deadOwner), "Insufficient trustee approvals");
        
        IERC20 token = IERC20(will.tokenContract);
        uint256 ownerBalance = token.balanceOf(_deadOwner);
        require(ownerBalance > 0, "No tokens to inherit");
        
        uint256 transferAmount = will.inheritanceAmount == 0 ? ownerBalance : will.inheritanceAmount;
        require(transferAmount <= ownerBalance, "Insufficient balance");
        
        // Mark as executed
        will.inheritanceExecuted = true;
        
        // Transfer tokens from dead owner to heir
        // Note: This requires the dead owner to have previously approved this contract
        require(token.transferFrom(_deadOwner, msg.sender, transferAmount), "Transfer failed");
        
        emit InheritanceExecuted(_deadOwner, msg.sender, transferAmount);
    }
    
    /**
     * @dev Update will details
     * @param _heir New heir address
     * @param _inheritanceAmount New inheritance amount
     * @param _willMessage New will message
     */
    function updateWill(
        address _heir,
        uint256 _inheritanceAmount,
        string memory _willMessage
    ) external {
        require(wills[msg.sender].isActive, "No active will found");
        require(_heir != address(0), "Invalid heir address");
        require(_heir != msg.sender, "Cannot be your own heir");
        
        Will storage will = wills[msg.sender];
        will.heir = _heir;
        will.inheritanceAmount = _inheritanceAmount;
        will.willMessage = _willMessage;
        will.lastHeartbeat = block.timestamp;
        will.heirConfirmed = false; // New heir needs to confirm
        
        emit WillCreated(msg.sender, _heir, will.tokenContract);
        emit HeartbeatRecorded(msg.sender, block.timestamp);
    }
    
    /**
     * @dev Deactivate will
     */
    function deactivateWill() external {
        require(wills[msg.sender].isActive, "Will already inactive");
        
        wills[msg.sender].isActive = false;
    }
    
    // /**
    //  * @dev Get will information
    //  * @param _owner Will owner address
    //  * @return All will details
    //  */
    function getWillInfo(address _owner) external view returns (
        address tokenContract,
        address heir,
        uint256 lastHeartbeat,
        bool isActive,
        bool inheritanceExecuted,
        bool heirConfirmed,
        uint256 inheritanceAmount,
        string memory willMessage
    ) {
        Will memory will = wills[_owner];
        return (
            will.tokenContract,
            will.heir,
            will.lastHeartbeat,
            will.isActive,
            will.inheritanceExecuted,
            will.heirConfirmed,
            will.inheritanceAmount,
            will.willMessage);
    }
    
    /**
     * @dev Get time until death
     * @param _owner Will owner address
     * @return Seconds remaining
     */
    function getTimeUntilDeath(address _owner) external view returns (uint256) {
        Will memory will = wills[_owner];
        if (!will.isActive) return 0;
        
        uint256 timePassed = block.timestamp - will.lastHeartbeat;
        if (timePassed >= deathTimeout) return 0;
        
        return deathTimeout - timePassed;
    }
    
    /**
     * @dev Update death timeout (owner only)
     * @param _newTimeout New timeout in seconds
     */
    function setDeathTimeout(uint256 _newTimeout) external onlyOwner {
        require(_newTimeout > 0, "Timeout must be positive");
        deathTimeout = _newTimeout;
        emit DeathTimeoutUpdated(_newTimeout);
    }
    
    /**
     * @dev Get trustees for an owner
     * @param _owner Will owner address
     * @return Array of trustee addresses
     */
    function getTrustees(address _owner) external view returns (address[] memory) {
        return trustees[_owner];
    }
}

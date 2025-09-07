// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract ERC721WillManager is Ownable, ReentrancyGuard {
    
    // Death detection timeout (30 days for production, 1 minute for testing)
    uint256 public deathTimeout = 1 minutes;

    // Struct to store will information for a single NFT
    struct Will {
        address tokenContract;      // ERC721 contract address
        uint256 tokenId;           // Specific NFT ID
        address heir;              // Designated heir address
        uint256 lastHeartbeat;     // Timestamp of owner's last heartbeat
        bool isActive;             // Will activation status
        bool inheritanceExecuted;   // Prevents double execution
        bool heirConfirmed;        // Heir acceptance confirmation
        string willMessage;        // Optional message to heir
        uint256 creationTime;      // When will was created
        bool requiresTrusteeApproval; // Flag for trustee requirement
    }

    // Mapping: owner -> tokenContract -> tokenId -> Will
    mapping(address => mapping(address => mapping(uint256 => Will))) public wills;
    
    // Track which tokens are in active wills to prevent duplicates
    mapping(address => mapping(uint256 => bool)) public isTokenInActiveWill;
    
    // Mapping to track trustees for multi-sig approval
    mapping(address => address[]) public trustees;
    mapping(address => mapping(address => bool)) public trusteeApprovals;
    mapping(address => uint256) public requiredTrusteeSignatures;

    // Events
    event WillCreated(
        address indexed owner, 
        address indexed heir, 
        address indexed tokenContract, 
        uint256 tokenId
    );
    event HeartbeatRecorded(address indexed owner, uint256 timestamp);
    event InheritanceExecuted(
        address indexed deadOwner, 
        address indexed heir, 
        address indexed tokenContract, 
        uint256 tokenId
    );
    event HeirConfirmed(address indexed heir, address indexed owner, address tokenContract, uint256 tokenId);
    event TrusteeAdded(address indexed owner, address indexed trustee);
    event TrusteeApproval(address indexed trustee, address indexed owner, bool approved);
    event DeathTimeoutUpdated(uint256 newTimeout);
    event WillDeactivated(address indexed owner, address tokenContract, uint256 tokenId);

    constructor() Ownable(msg.sender) {
        // Set testing timeout (1 minute for quick testing)
        deathTimeout = 1 minutes;
    }

    /**
     * @dev Create a will for a specific NFT
     * @param _tokenContract ERC721 contract address
     * @param _tokenId Specific NFT token ID
     * @param _heir Designated heir address
     * @param _willMessage Optional message to heir
     * @param _requiresTrusteeApproval Whether trustee approval is required
     */
    function createWill(
        address _tokenContract,
        uint256 _tokenId,
        address _heir,
        string memory _willMessage,
        bool _requiresTrusteeApproval
    ) external {
        require(_tokenContract != address(0), "Invalid token contract");
        require(_heir != address(0), "Invalid heir address");
        require(_heir != msg.sender, "Cannot be your own heir");
        
        // Validate ownership and approval
        IERC721 nft = IERC721(_tokenContract);
        require(nft.ownerOf(_tokenId) == msg.sender, "Not token owner");
        require(!isTokenInActiveWill[_tokenContract][_tokenId], "Token already in active will");
        require(canTransferNFT(_tokenContract, _tokenId, msg.sender), "Contract not approved for transfer");

        // Mark token as being in an active will
        isTokenInActiveWill[_tokenContract][_tokenId] = true;

        wills[msg.sender][_tokenContract][_tokenId] = Will({
            tokenContract: _tokenContract,
            tokenId: _tokenId,
            heir: _heir,
            lastHeartbeat: block.timestamp,
            isActive: true,
            inheritanceExecuted: false,
            heirConfirmed: false,
            willMessage: _willMessage,
            creationTime: block.timestamp,
            requiresTrusteeApproval: _requiresTrusteeApproval
        });

        emit WillCreated(msg.sender, _heir, _tokenContract, _tokenId);
        emit HeartbeatRecorded(msg.sender, block.timestamp);
    }

    /**
     * @dev Record heartbeat to prove owner is alive
     */
    function recordHeartbeat() external {
        // Update heartbeat for all active wills of this owner
        // (In production, you might want to optimize this)
        emit HeartbeatRecorded(msg.sender, block.timestamp);
    }

    /**
     * @dev Record heartbeat for specific will
     * @param _tokenContract NFT contract address
     * @param _tokenId NFT token ID
     */
    function recordHeartbeatForWill(address _tokenContract, uint256 _tokenId) external {
        Will storage will = wills[msg.sender][_tokenContract][_tokenId];
        require(will.isActive, "No active will found");

        will.lastHeartbeat = block.timestamp;
        emit HeartbeatRecorded(msg.sender, block.timestamp);
    }

    /**
     * @dev Heir confirms acceptance of inheritance
     * @param _owner Address of the will owner
     * @param _tokenContract NFT contract address
     * @param _tokenId NFT token ID
     */
    function confirmHeirship(address _owner, address _tokenContract, uint256 _tokenId) external {
        Will storage will = wills[_owner][_tokenContract][_tokenId];
        require(will.heir == msg.sender, "Not the designated heir");
        require(will.isActive, "Will is not active");
        require(!will.heirConfirmed, "Already confirmed");

        will.heirConfirmed = true;
        emit HeirConfirmed(msg.sender, _owner, _tokenContract, _tokenId);
    }

    /**
     * @dev Add trustee for multi-signature approval
     * @param _trustee Address of the trustee
     */
    function addTrustee(address _trustee) external {
        require(_trustee != address(0), "Invalid trustee address");
        require(_trustee != msg.sender, "Cannot be your own trustee");

        trustees[msg.sender].push(_trustee);
        emit TrusteeAdded(msg.sender, _trustee);
    }

    /**
     * @dev Set required number of trustee signatures
     * @param _required Number of required signatures
     */
    function setRequiredTrusteeSignatures(uint256 _required) external {
        require(_required <= trustees[msg.sender].length, "Cannot require more signatures than trustees");
        requiredTrusteeSignatures[msg.sender] = _required;
    }

    /**
     * @dev Trustee approves inheritance execution
     * @param _owner Address of the will owner
     * @param _approve True to approve, false to deny
     */
    function trusteeApproval(address _owner, bool _approve) external {
        require(isTrustee(_owner, msg.sender), "Not a trustee for this owner");
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
     * @dev Check if owner is considered dead for a specific will
     * @param _owner Address to check
     * @param _tokenContract NFT contract address
     * @param _tokenId NFT token ID
     * @return bool True if dead
     */
    function isOwnerDead(address _owner, address _tokenContract, uint256 _tokenId) public view returns (bool) {
        Will memory will = wills[_owner][_tokenContract][_tokenId];
        if (!will.isActive) return false;
        return (block.timestamp - will.lastHeartbeat) >= deathTimeout;
    }

    /**
     * @dev Execute inheritance transfer for specific NFT
     * @param _deadOwner Address of deceased owner
     * @param _tokenContract NFT contract address
     * @param _tokenId NFT token ID
     */
    function executeInheritance(
        address _deadOwner, 
        address _tokenContract, 
        uint256 _tokenId
    ) external nonReentrant {
        Will storage will = wills[_deadOwner][_tokenContract][_tokenId];

        require(will.isActive, "Will is not active");
        require(will.heir == msg.sender, "Only heir can execute");
        require(isOwnerDead(_deadOwner, _tokenContract, _tokenId), "Owner is not dead yet");
        require(!will.inheritanceExecuted, "Already executed");
        require(will.heirConfirmed, "Heir must confirm first");
        
        // Check trustee approvals if required
        if (will.requiresTrusteeApproval) {
            require(hasSufficientTrusteeApprovals(_deadOwner), "Insufficient trustee approvals");
        }

        IERC721 nft = IERC721(_tokenContract);
        
        // Verify the dead owner still owns the NFT
        require(nft.ownerOf(_tokenId) == _deadOwner, "Dead owner no longer owns this NFT");
        
        // Verify contract can still transfer the NFT
        require(canTransferNFT(_tokenContract, _tokenId, _deadOwner), "Cannot transfer NFT - approval revoked");

        // Mark as executed
        will.inheritanceExecuted = true;
        isTokenInActiveWill[_tokenContract][_tokenId] = false;

        // Transfer NFT from dead owner to heir
        nft.safeTransferFrom(_deadOwner, msg.sender, _tokenId);

        emit InheritanceExecuted(_deadOwner, msg.sender, _tokenContract, _tokenId);
    }

    /**
     * @dev Update will details
     * @param _tokenContract NFT contract address
     * @param _tokenId NFT token ID
     * @param _heir New heir address
     * @param _willMessage New will message
     */
    function updateWill(
        address _tokenContract,
        uint256 _tokenId,
        address _heir,
        string memory _willMessage
    ) external {
        Will storage will = wills[msg.sender][_tokenContract][_tokenId];
        require(will.isActive, "No active will found");
        require(_heir != address(0), "Invalid heir address");
        require(_heir != msg.sender, "Cannot be your own heir");

        will.heir = _heir;
        will.willMessage = _willMessage;
        will.lastHeartbeat = block.timestamp;
        will.heirConfirmed = false; // New heir needs to confirm

        emit WillCreated(msg.sender, _heir, _tokenContract, _tokenId);
        emit HeartbeatRecorded(msg.sender, block.timestamp);
    }

    /**
     * @dev Deactivate specific will
     * @param _tokenContract NFT contract address
     * @param _tokenId NFT token ID
     */
    function deactivateWill(address _tokenContract, uint256 _tokenId) external {
        Will storage will = wills[msg.sender][_tokenContract][_tokenId];
        require(will.isActive, "Will already inactive");

        will.isActive = false;
        isTokenInActiveWill[_tokenContract][_tokenId] = false;
        
        emit WillDeactivated(msg.sender, _tokenContract, _tokenId);
    }

    function getWillInfo(address _owner, address _tokenContract, uint256 _tokenId) external view returns (
        address tokenContract,
        uint256 tokenId,
        address heir,
        uint256 lastHeartbeat,
        bool isActive,
        bool inheritanceExecuted,
        bool heirConfirmed,
        string memory willMessage,
        uint256 creationTime,
        bool requiresTrusteeApproval
    ) {
        Will memory will = wills[_owner][_tokenContract][_tokenId];
        return (
            will.tokenContract,
            will.tokenId,
            will.heir,
            will.lastHeartbeat,
            will.isActive,
            will.inheritanceExecuted,
            will.heirConfirmed,
            will.willMessage,
            will.creationTime,
            will.requiresTrusteeApproval
        );
    }

    /**
     * @dev Get time until death for specific will
     * @param _owner Will owner address
     * @param _tokenContract NFT contract address
     * @param _tokenId NFT token ID
     * @return Seconds remaining
     */
    function getTimeUntilDeath(address _owner, address _tokenContract, uint256 _tokenId) external view returns (uint256) {
        Will memory will = wills[_owner][_tokenContract][_tokenId];
        if (!will.isActive) return 0;

        uint256 timePassed = block.timestamp - will.lastHeartbeat;
        if (timePassed >= deathTimeout) return 0;

        return deathTimeout - timePassed;
    }

    /**
     * @dev Check if contract can transfer NFT
     * @param _tokenContract NFT contract address
     * @param _tokenId NFT token ID
     * @param _owner Owner address
     * @return bool True if can transfer
     */
    function canTransferNFT(address _tokenContract, uint256 _tokenId, address _owner) public view returns (bool) {
        IERC721 nft = IERC721(_tokenContract);
        return nft.getApproved(_tokenId) == address(this) || 
               nft.isApprovedForAll(_owner, address(this));
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

    /**
     * @dev Check if NFT is inheritable (has active will)
     * @param _tokenContract NFT contract address
     * @param _tokenId NFT token ID
     * @return bool True if inheritable
     */
    function isNFTInheritable(address _tokenContract, uint256 _tokenId) external view returns (bool) {
        return isTokenInActiveWill[_tokenContract][_tokenId];
    }
}

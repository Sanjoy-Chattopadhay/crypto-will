// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./UnifiedNFTContract.sol";

contract UnifiedWillManager is ReentrancyGuard, IERC721Receiver, Ownable {
    
    UnifiedNFTContract public nftContract;
    
    // Death detection timeout
    uint256 public deathTimeout = 30 days;
    
    // Proposal types
    enum ProposalType { 
        REGULAR_INHERITANCE,    // Single heir inheritance for regular NFTs
        MULTI_INHERITANCE,      // Multi-heir inheritance for multi-owner NFTs
        ADD_OWNER,             // Add owner to indivisible asset
        REMOVE_OWNER           // Remove owner from indivisible asset
    }
    
    // Token types from NFT contract
    enum TokenType { REGULAR, DIVISIBLE, INDIVISIBLE }
    
    // Will structures
    struct RegularWill {
        uint256 tokenId;
        address owner;
        address heir;
        uint256 lastHeartbeat;
        bool isActive;
        bool inheritanceExecuted;
        bool heirConfirmed;
        string willMessage;
        bool requiresTrusteeApproval;
        bool isDeposited;
    }
    
    struct MultiOwnerWill {
        uint256 tokenId;
        address owner;
        uint256 lastHeartbeat;
        bool isActive;
        address[] heirs;
        mapping(address => uint256) heirShares; // For divisible assets
        string willMessage;
    }
    
    // Proposal structure
    struct Proposal {
        uint256 tokenId;
        address proposer;
        address targetOwner;
        ProposalType proposalType;
        address[] requiredSigners;
        mapping(address => bool) hasSigned;
        uint256 signatureCount;
        bool executed;
        uint256 createdAt;
        uint256 expiresAt;
        string reason;
        // For inheritance proposals
        address deceased;
        bool isInheritanceProposal;
    }
    
    // Storage
    mapping(address => mapping(uint256 => RegularWill)) public regularWills; // owner -> tokenId -> Will
    mapping(address => mapping(uint256 => MultiOwnerWill)) public multiWills; // owner -> tokenId -> Will
    mapping(uint256 => Proposal) public proposals;
    uint256 public nextProposalId = 1;
    
    // NFT escrow for regular NFTs
    mapping(address => mapping(uint256 => address)) public depositedTokens; // contract -> tokenId -> depositor
    
    // Trustee system
    mapping(address => address[]) public trustees;
    mapping(address => mapping(address => bool)) public trusteeApprovals;
    mapping(address => uint256) public requiredTrusteeSignatures;
    
    // Tracking
    mapping(address => uint256[]) public userProposals;
    mapping(uint256 => uint256[]) public tokenProposals;
    
    // Events
    event RegularWillCreated(address indexed owner, uint256 indexed tokenId, address heir);
    event MultiWillCreated(address indexed owner, uint256 indexed tokenId, address[] heirs);
    event HeartbeatRecorded(address indexed owner, uint256 timestamp);
    event NFTDeposited(address indexed owner, uint256 indexed tokenId);
    event NFTWithdrawn(address indexed owner, uint256 indexed tokenId);
    event OwnerDeathDetected(address indexed owner, uint256 indexed tokenId);
    event ProposalCreated(uint256 indexed proposalId, uint256 indexed tokenId, ProposalType proposalType);
    event ProposalSigned(uint256 indexed proposalId, address indexed signer);
    event ProposalExecuted(uint256 indexed proposalId, bool success);
    event InheritanceExecuted(address indexed deceased, address indexed heir, uint256 indexed tokenId);
    event TrusteeAdded(address indexed owner, address indexed trustee);
    event DeathTimeoutUpdated(uint256 newTimeout);
    
    modifier onlyTokenOwner(uint256 tokenId) {
        require(nftContract.isOwnerOf(tokenId, msg.sender), "Not a token owner");
        _;
    }
    
    modifier validProposal(uint256 proposalId) {
        require(proposalId < nextProposalId, "Proposal does not exist");
        require(!proposals[proposalId].executed, "Proposal already executed");
        require(block.timestamp <= proposals[proposalId].expiresAt, "Proposal expired");
        _;
    }
    
    constructor(address _nftContract) Ownable(msg.sender) {
        nftContract = UnifiedNFTContract(_nftContract);
    }
    
    // UNIFIED WILL CREATION
    
    function createRegularWill(
        uint256 tokenId,
        address heir,
        string memory willMessage,
        bool requiresTrusteeApproval
    ) external onlyTokenOwner(tokenId) {
        require(nftContract.getTokenType(tokenId) == UnifiedNFTContract.TokenType.REGULAR, "Not a regular token");
        require(heir != address(0), "Invalid heir address");
        require(heir != msg.sender, "Cannot be your own heir");
        
        RegularWill storage will = regularWills[msg.sender][tokenId];
        require(!will.isActive, "Will already exists");
        
        will.tokenId = tokenId;
        will.owner = msg.sender;
        will.heir = heir;
        will.lastHeartbeat = block.timestamp;
        will.isActive = true;
        will.willMessage = willMessage;
        will.requiresTrusteeApproval = requiresTrusteeApproval;
        
        emit RegularWillCreated(msg.sender, tokenId, heir);
    }
    
    function createMultiOwnerWill(
        uint256 tokenId,
        address[] memory heirs,
        uint256[] memory shares,
        string memory willMessage
    ) external onlyTokenOwner(tokenId) {
        UnifiedNFTContract.TokenType tokenType = nftContract.getTokenType(tokenId);
        require(tokenType == UnifiedNFTContract.TokenType.DIVISIBLE || 
                tokenType == UnifiedNFTContract.TokenType.INDIVISIBLE, "Not a multi-owner token");
        require(heirs.length > 0, "Must specify heirs");
        
        if (tokenType == UnifiedNFTContract.TokenType.DIVISIBLE) {
            require(heirs.length == shares.length, "Heirs and shares length mismatch");
            uint256 totalShares = 0;
            for (uint256 i = 0; i < shares.length; i++) {
                totalShares += shares[i];
            }
            require(totalShares == 100, "Shares must total 100%");
        }
        
        MultiOwnerWill storage will = multiWills[msg.sender][tokenId];
        require(!will.isActive, "Will already exists");
        
        will.tokenId = tokenId;
        will.owner = msg.sender;
        will.lastHeartbeat = block.timestamp;
        will.isActive = true;
        will.heirs = heirs;
        will.willMessage = willMessage;
        
        if (tokenType == UnifiedNFTContract.TokenType.DIVISIBLE) {
            for (uint256 i = 0; i < heirs.length; i++) {
                will.heirShares[heirs[i]] = shares[i];
            }
        }
        
        emit MultiWillCreated(msg.sender, tokenId, heirs);
    }
    
    // DEATH DETECTION SYSTEM
    
    function recordHeartbeat(uint256[] memory tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            if (nftContract.isOwnerOf(tokenId, msg.sender)) {
                UnifiedNFTContract.TokenType tokenType = nftContract.getTokenType(tokenId);
                
                if (tokenType == UnifiedNFTContract.TokenType.REGULAR) {
                    RegularWill storage will = regularWills[msg.sender][tokenId];
                    if (will.isActive) {
                        will.lastHeartbeat = block.timestamp;
                    }
                } else {
                    MultiOwnerWill storage will = multiWills[msg.sender][tokenId];
                    if (will.isActive) {
                        will.lastHeartbeat = block.timestamp;
                    }
                }
            }
        }
        emit HeartbeatRecorded(msg.sender, block.timestamp);
    }
    
    function isOwnerDead(address owner, uint256 tokenId) public view returns (bool) {
        UnifiedNFTContract.TokenType tokenType = nftContract.getTokenType(tokenId);
        
        if (tokenType == UnifiedNFTContract.TokenType.REGULAR) {
            RegularWill storage will = regularWills[owner][tokenId];
            if (!will.isActive) return false;
            return (block.timestamp - will.lastHeartbeat) >= deathTimeout;
        } else {
            MultiOwnerWill storage will = multiWills[owner][tokenId];
            if (!will.isActive) return false;
            return (block.timestamp - will.lastHeartbeat) >= deathTimeout;
        }
    }
    
    // NFT ESCROW SYSTEM (for regular NFTs)
    
    function depositNFT(uint256 tokenId) external onlyTokenOwner(tokenId) {
        require(nftContract.getTokenType(tokenId) == UnifiedNFTContract.TokenType.REGULAR, "Only for regular NFTs");
        
        RegularWill storage will = regularWills[msg.sender][tokenId];
        require(will.isActive, "No active will found");
        require(!will.isDeposited, "NFT already deposited");
        
        // Transfer NFT to this contract
        nftContract.safeTransferFrom(msg.sender, address(this), tokenId);
        
        will.isDeposited = true;
        depositedTokens[address(nftContract)][tokenId] = msg.sender;
        
        emit NFTDeposited(msg.sender, tokenId);
    }
    
    function withdrawNFT(uint256 tokenId) external {
        RegularWill storage will = regularWills[msg.sender][tokenId];
        require(will.isActive, "No active will found");
        require(will.isDeposited, "NFT not deposited");
        
        will.isDeposited = false;
        delete depositedTokens[address(nftContract)][tokenId];
        will.lastHeartbeat = block.timestamp;
        
        nftContract.safeTransferFrom(address(this), msg.sender, tokenId);
        
        emit NFTWithdrawn(msg.sender, tokenId);
    }
    
    // INHERITANCE EXECUTION
    
    function executeRegularInheritance(uint256 tokenId, address deceased) external nonReentrant {
        RegularWill storage will = regularWills[deceased][tokenId];
        
        require(will.isActive, "Will is not active");
        require(will.heir == msg.sender, "Only heir can execute");
        require(isOwnerDead(deceased, tokenId), "Owner is not dead yet");
        require(!will.inheritanceExecuted, "Already executed");
        require(will.heirConfirmed, "Heir must confirm first");
        require(will.isDeposited, "NFT not deposited in contract");
        
        if (will.requiresTrusteeApproval) {
            require(hasSufficientTrusteeApprovals(deceased), "Insufficient trustee approvals");
        }
        
        will.inheritanceExecuted = true;
        delete depositedTokens[address(nftContract)][tokenId];
        
        nftContract.safeTransferFrom(address(this), msg.sender, tokenId);
        
        emit InheritanceExecuted(deceased, msg.sender, tokenId);
    }
    
    // PROPOSAL SYSTEM (for multi-owner NFTs and governance)
    
    function proposeInheritance(
        address deceased,
        uint256 tokenId,
        string memory reason
    ) external returns (uint256 proposalId) {
        require(isOwnerDead(deceased, tokenId), "Owner is not dead");
        require(nftContract.isOwnerOf(tokenId, deceased), "Deceased was not owner");
        
        MultiOwnerWill storage will = multiWills[deceased][tokenId];
        require(will.isActive, "No active will found");
        
        // Check if proposer is an heir
        bool isHeir = false;
        for (uint256 i = 0; i < will.heirs.length; i++) {
            if (will.heirs[i] == msg.sender) {
                isHeir = true;
                break;
            }
        }
        require(isHeir, "Only heirs can propose inheritance");
        
        proposalId = nextProposalId++;
        Proposal storage proposal = proposals[proposalId];
        
        proposal.tokenId = tokenId;
        proposal.proposer = msg.sender;
        proposal.deceased = deceased;
        proposal.proposalType = ProposalType.MULTI_INHERITANCE;
        proposal.createdAt = block.timestamp;
        proposal.expiresAt = block.timestamp + 30 days;
        proposal.reason = reason;
        proposal.isInheritanceProposal = true;
        proposal.requiredSigners = will.heirs;
        
        userProposals[msg.sender].push(proposalId);
        tokenProposals[tokenId].push(proposalId);
        
        emit OwnerDeathDetected(deceased, tokenId);
        emit ProposalCreated(proposalId, tokenId, ProposalType.MULTI_INHERITANCE);
        
        _signProposal(proposalId, msg.sender);
        return proposalId;
    }
    
    function proposeAddOwner(
        uint256 tokenId,
        address newOwner,
        string memory reason
    ) external onlyTokenOwner(tokenId) returns (uint256 proposalId) {
        require(nftContract.getTokenType(tokenId) == UnifiedNFTContract.TokenType.INDIVISIBLE, "Only for indivisible tokens");
        require(newOwner != address(0), "Invalid owner address");
        require(!nftContract.isOwnerOf(tokenId, newOwner), "Already an owner");
        
        proposalId = nextProposalId++;
        Proposal storage proposal = proposals[proposalId];
        
        proposal.tokenId = tokenId;
        proposal.proposer = msg.sender;
        proposal.targetOwner = newOwner;
        proposal.proposalType = ProposalType.ADD_OWNER;
        proposal.createdAt = block.timestamp;
        proposal.expiresAt = block.timestamp + 7 days;
        proposal.reason = reason;
        
        address[] memory allOwners = nftContract.getIndivisibleOwners(tokenId);
        proposal.requiredSigners = allOwners;
        
        userProposals[msg.sender].push(proposalId);
        tokenProposals[tokenId].push(proposalId);
        
        emit ProposalCreated(proposalId, tokenId, ProposalType.ADD_OWNER);
        
        _signProposal(proposalId, msg.sender);
        return proposalId;
    }
    
    function proposeRemoveOwner(
        uint256 tokenId,
        address ownerToRemove,
        string memory reason
    ) external onlyTokenOwner(tokenId) returns (uint256 proposalId) {
        require(nftContract.getTokenType(tokenId) == UnifiedNFTContract.TokenType.INDIVISIBLE, "Only for indivisible tokens");
        require(ownerToRemove != address(0), "Invalid owner address");
        require(nftContract.isOwnerOf(tokenId, ownerToRemove), "Not an owner");
        require(msg.sender != ownerToRemove, "Cannot remove yourself");
        require(nftContract.getOwnerCount(tokenId) > 1, "Cannot remove last owner");
        
        proposalId = nextProposalId++;
        Proposal storage proposal = proposals[proposalId];
        
        proposal.tokenId = tokenId;
        proposal.proposer = msg.sender;
        proposal.targetOwner = ownerToRemove;
        proposal.proposalType = ProposalType.REMOVE_OWNER;
        proposal.createdAt = block.timestamp;
        proposal.expiresAt = block.timestamp + 7 days;
        proposal.reason = reason;
        
        address[] memory allOwners = nftContract.getIndivisibleOwners(tokenId);
        address[] memory requiredSigners = new address[](allOwners.length - 1);
        uint256 signerIndex = 0;
        
        for (uint256 i = 0; i < allOwners.length; i++) {
            if (allOwners[i] != ownerToRemove) {
                requiredSigners[signerIndex] = allOwners[i];
                signerIndex++;
            }
        }
        
        proposal.requiredSigners = requiredSigners;
        
        userProposals[msg.sender].push(proposalId);
        tokenProposals[tokenId].push(proposalId);
        
        emit ProposalCreated(proposalId, tokenId, ProposalType.REMOVE_OWNER);
        
        _signProposal(proposalId, msg.sender);
        return proposalId;
    }
    
    function signProposal(uint256 proposalId) external validProposal(proposalId) {
        _signProposal(proposalId, msg.sender);
    }
    
    function _signProposal(uint256 proposalId, address signer) internal {
        Proposal storage proposal = proposals[proposalId];
        
        bool isRequiredSigner = false;
        for (uint256 i = 0; i < proposal.requiredSigners.length; i++) {
            if (proposal.requiredSigners[i] == signer) {
                isRequiredSigner = true;
                break;
            }
        }
        require(isRequiredSigner, "Not authorized to sign");
        require(!proposal.hasSigned[signer], "Already signed");
        
        proposal.hasSigned[signer] = true;
        proposal.signatureCount++;
        
        emit ProposalSigned(proposalId, signer);
        
        if (proposal.signatureCount == proposal.requiredSigners.length) {
            _executeProposal(proposalId);
        }
    }
    
    function _executeProposal(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Already executed");
        
        proposal.executed = true;
        bool success = false;
        
        if (proposal.proposalType == ProposalType.ADD_OWNER) {
            try nftContract.addOwnerToIndivisibleAsset(proposal.tokenId, proposal.targetOwner) {
                success = true;
            } catch {
                success = false;
            }
        } else if (proposal.proposalType == ProposalType.REMOVE_OWNER) {
            try nftContract.removeOwnerFromIndivisibleAsset(proposal.tokenId, proposal.targetOwner) {
                success = true;
            } catch {
                success = false;
            }
        } else if (proposal.proposalType == ProposalType.MULTI_INHERITANCE) {
            // Execute multi-owner inheritance
            MultiOwnerWill storage will = multiWills[proposal.deceased][proposal.tokenId];
            
            try nftContract.removeOwnerFromIndivisibleAsset(proposal.tokenId, proposal.deceased) {
                // Add all heirs as new owners
                for (uint256 i = 0; i < will.heirs.length; i++) {
                    try nftContract.addOwnerToIndivisibleAsset(proposal.tokenId, will.heirs[i]) {
                        // Success for this heir
                    } catch {
                        // Failed to add this heir
                    }
                }
                will.isActive = false;
                success = true;
            } catch {
                success = false;
            }
        }
        
        emit ProposalExecuted(proposalId, success);
    }
    
    // HEIR CONFIRMATION
    
    function confirmRegularHeirship(address owner, uint256 tokenId) external {
        RegularWill storage will = regularWills[owner][tokenId];
        require(will.heir == msg.sender, "Not the designated heir");
        require(will.isActive, "Will is not active");
        require(!will.heirConfirmed, "Already confirmed");
        
        will.heirConfirmed = true;
    }
    
    // TRUSTEE SYSTEM
    
    function addTrustee(address trustee) external {
        require(trustee != address(0), "Invalid trustee address");
        require(trustee != msg.sender, "Cannot be your own trustee");
        
        trustees[msg.sender].push(trustee);
        emit TrusteeAdded(msg.sender, trustee);
    }
    
    function setRequiredTrusteeSignatures(uint256 required) external {
        require(required <= trustees[msg.sender].length, "Cannot require more signatures than trustees");
        requiredTrusteeSignatures[msg.sender] = required;
    }
    
    function trusteeApproval(address owner, bool approve) external {
        require(isTrustee(owner, msg.sender), "Not a trustee for this owner");
        trusteeApprovals[owner][msg.sender] = approve;
    }
    
    function isTrustee(address owner, address trustee) public view returns (bool) {
        address[] memory ownerTrustees = trustees[owner];
        for (uint256 i = 0; i < ownerTrustees.length; i++) {
            if (ownerTrustees[i] == trustee) {
                return true;
            }
        }
        return false;
    }
    
    function hasSufficientTrusteeApprovals(address owner) public view returns (bool) {
        uint256 required = requiredTrusteeSignatures[owner];
        if (required == 0) return true;
        
        uint256 approvals = 0;
        address[] memory ownerTrustees = trustees[owner];
        
        for (uint256 i = 0; i < ownerTrustees.length; i++) {
            if (trusteeApprovals[owner][ownerTrustees[i]]) {
                approvals++;
            }
        }
        
        return approvals >= required;
    }
    
    // QUERY FUNCTIONS
    
    function getRegularWillInfo(address owner, uint256 tokenId) external view returns (
        bool isActive,
        address heir,
        uint256 lastHeartbeat,
        bool heirConfirmed,
        bool isDeposited,
        string memory willMessage
        // bool isDead
    ) {
        RegularWill storage will = regularWills[owner][tokenId];
        return (
            will.isActive,
            will.heir,
            will.lastHeartbeat,
            will.heirConfirmed,
            will.isDeposited,
            will.willMessage
        );
    }
    
    function getMultiWillInfo(address owner, uint256 tokenId) external view returns (
        bool isActive,
        uint256 lastHeartbeat,
        address[] memory heirs,
        string memory willMessage,
        bool isDead
    ) {
        MultiOwnerWill storage will = multiWills[owner][tokenId];
        return (
            will.isActive,
            will.lastHeartbeat,
            will.heirs,
            will.willMessage,
            isOwnerDead(owner, tokenId)
        );
    }
    
    function getProposal(uint256 proposalId) external view returns (
        uint256 tokenId,
        address proposer,
        address targetOwner,
        ProposalType proposalType,
        address[] memory requiredSigners,
        uint256 signatureCount,
        bool executed,
        uint256 createdAt,
        uint256 expiresAt,
        string memory reason
    ) {
        require(proposalId < nextProposalId, "Proposal does not exist");
        Proposal storage proposal = proposals[proposalId];
        
        return (
            proposal.tokenId,
            proposal.proposer,
            proposal.targetOwner,
            proposal.proposalType,
            proposal.requiredSigners,
            proposal.signatureCount,
            proposal.executed,
            proposal.createdAt,
            proposal.expiresAt,
            proposal.reason
        );
    }
    
    // ADMIN FUNCTIONS
    
    function setDeathTimeout(uint256 newTimeout) external onlyOwner {
        require(newTimeout > 0, "Timeout must be positive");
        deathTimeout = newTimeout;
        emit DeathTimeoutUpdated(newTimeout);
    }
    
    function setTestingTimeout() external onlyOwner {
        deathTimeout = 1 minutes;
        emit DeathTimeoutUpdated(deathTimeout);
    }
    
    // Required for receiving NFTs
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

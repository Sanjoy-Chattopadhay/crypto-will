// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "ERC721-adding-remvoing/testcontract.sol";

contract MultiSigWillManager is ReentrancyGuard {
    
    MultiOwnerNFT public nftContract;
    
    // Proposal types
    enum ProposalType { 
        PROPERTY_TRANSFER,  // Existing functionality
        ADD_OWNER,         // New: Add owner to indivisible asset
        REMOVE_OWNER       // New: Remove owner from indivisible asset
    }
    
    // Owner management proposal structure
    struct OwnerProposal {
        uint256 tokenId;
        address proposer;
        address targetOwner;        // Owner to add/remove
        ProposalType proposalType;
        address[] requiredSigners;  // Who needs to sign
        mapping(address => bool) hasSigned;
        uint256 signatureCount;
        bool executed;
        uint256 createdAt;
        string reason;              // Optional reason for proposal
    }
    
    // Proposal storage
    mapping(uint256 => OwnerProposal) public ownerProposals;
    uint256 public nextProposalId = 1;
    
    // Tracking mappings
    mapping(address => uint256[]) public userProposals;           // Proposals by user
    mapping(uint256 => uint256[]) public tokenProposals;         // Proposals for token
    mapping(address => mapping(uint256 => uint256[])) public userTokenProposals; // User proposals for specific token
    
    // Events
    event OwnerProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed tokenId,
        address indexed proposer,
        ProposalType proposalType,
        address targetOwner,
        address[] requiredSigners
    );
    
    event ProposalSigned(
        uint256 indexed proposalId,
        address indexed signer,
        uint256 signaturesCollected,
        uint256 signaturesRequired
    );
    
    event OwnerProposalExecuted(
        uint256 indexed proposalId,
        uint256 indexed tokenId,
        ProposalType proposalType,
        address targetOwner,
        bool success
    );
    
    modifier onlyTokenOwner(uint256 tokenId) {
        require(nftContract.isOwnerOf(tokenId, msg.sender), "Not a token owner");
        _;
    }
    
    modifier onlyIndivisibleToken(uint256 tokenId) {
        require(nftContract.isIndivisible(tokenId), "Token is not indivisible");
        _;
    }
    
    modifier validProposal(uint256 proposalId) {
        require(proposalId < nextProposalId, "Proposal does not exist");
        require(!ownerProposals[proposalId].executed, "Proposal already executed");
        _;
    }
    
    constructor(address _nftContract) {
        nftContract = MultiOwnerNFT(_nftContract);
    }
    
    // NEW: Propose adding an owner to indivisible asset
    function proposeAddOwner(
        uint256 tokenId,
        address newOwner,
        string memory reason
    ) external onlyTokenOwner(tokenId) onlyIndivisibleToken(tokenId) returns (uint256 proposalId) {
        require(newOwner != address(0), "Invalid owner address");
        require(!nftContract.isOwnerOf(tokenId, newOwner), "Already an owner");
        
        proposalId = nextProposalId++;
        OwnerProposal storage proposal = ownerProposals[proposalId];
        
        proposal.tokenId = tokenId;
        proposal.proposer = msg.sender;
        proposal.targetOwner = newOwner;
        proposal.proposalType = ProposalType.ADD_OWNER;
        proposal.createdAt = block.timestamp;
        proposal.reason = reason;
        
        // Required signers = ALL current owners
        address[] memory allOwners = nftContract.getIndivisibleOwners(tokenId);
        proposal.requiredSigners = allOwners;
        
        // Track proposal
        userProposals[msg.sender].push(proposalId);
        tokenProposals[tokenId].push(proposalId);
        userTokenProposals[msg.sender][tokenId].push(proposalId);
        
        emit OwnerProposalCreated(
            proposalId,
            tokenId,
            msg.sender,
            ProposalType.ADD_OWNER,
            newOwner,
            allOwners
        );
        
        // Proposer auto-signs
        _signProposal(proposalId, msg.sender);
        
        return proposalId;
    }
    
    // NEW: Propose removing an owner from indivisible asset
    function proposeRemoveOwner(
        uint256 tokenId,
        address ownerToRemove,
        string memory reason
    ) external onlyTokenOwner(tokenId) onlyIndivisibleToken(tokenId) returns (uint256 proposalId) {
        require(ownerToRemove != address(0), "Invalid owner address");
        require(nftContract.isOwnerOf(tokenId, ownerToRemove), "Not an owner");
        require(msg.sender != ownerToRemove, "Cannot remove yourself");
        require(nftContract.getOwnerCount(tokenId) > 1, "Cannot remove last owner");
        
        proposalId = nextProposalId++;
        OwnerProposal storage proposal = ownerProposals[proposalId];
        
        proposal.tokenId = tokenId;
        proposal.proposer = msg.sender;
        proposal.targetOwner = ownerToRemove;
        proposal.proposalType = ProposalType.REMOVE_OWNER;
        proposal.createdAt = block.timestamp;
        proposal.reason = reason;
        
        // Required signers = ALL OTHER owners (excluding the one being removed)
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
        
        // Track proposal
        userProposals[msg.sender].push(proposalId);
        tokenProposals[tokenId].push(proposalId);
        userTokenProposals[msg.sender][tokenId].push(proposalId);
        
        emit OwnerProposalCreated(
            proposalId,
            tokenId,
            msg.sender,
            ProposalType.REMOVE_OWNER,
            ownerToRemove,
            requiredSigners
        );
        
        // Proposer auto-signs
        _signProposal(proposalId, msg.sender);
        
        return proposalId;
    }
    
    // Sign a proposal
    function signProposal(uint256 proposalId) external validProposal(proposalId) {
        _signProposal(proposalId, msg.sender);
    }
    
    // Internal sign function
    function _signProposal(uint256 proposalId, address signer) internal {
        OwnerProposal storage proposal = ownerProposals[proposalId];
        
        // Check if signer is required to sign
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
        
        emit ProposalSigned(
            proposalId,
            signer,
            proposal.signatureCount,
            proposal.requiredSigners.length
        );
        
        // Execute if all signatures collected
        if (proposal.signatureCount == proposal.requiredSigners.length) {
            _executeOwnerProposal(proposalId);
        }
    }
    
    // Execute owner management proposal
function _executeOwnerProposal(uint256 proposalId) internal {
    OwnerProposal storage proposal = ownerProposals[proposalId];
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
    }

    emit OwnerProposalExecuted(
        proposalId,
        proposal.tokenId,
        proposal.proposalType,
        proposal.targetOwner,
        success
    );
}

    
    // TRACKING METHODS
    
    // Get proposal details
    function getProposal(uint256 proposalId) external view returns (
        uint256 tokenId,
        address proposer,
        address targetOwner,
        ProposalType proposalType,
        address[] memory requiredSigners,
        uint256 signatureCount,
        bool executed,
        uint256 createdAt,
        string memory reason
    ) {
        require(proposalId < nextProposalId, "Proposal does not exist");
        OwnerProposal storage proposal = ownerProposals[proposalId];
        
        return (
            proposal.tokenId,
            proposal.proposer,
            proposal.targetOwner,
            proposal.proposalType,
            proposal.requiredSigners,
            proposal.signatureCount,
            proposal.executed,
            proposal.createdAt,
            proposal.reason
        );
    }
    
    // Check if user has signed proposal
    function hasUserSigned(uint256 proposalId, address user) external view returns (bool) {
        return ownerProposals[proposalId].hasSigned[user];
    }
    
    // Get all proposal IDs created by user
    function getUserProposals(address user) external view returns (uint256[] memory) {
        return userProposals[user];
    }
    
    // Get all proposal IDs for a token
    function getTokenProposals(uint256 tokenId) external view returns (uint256[] memory) {
        return tokenProposals[tokenId];
    }
    
    // Get user's proposals for specific token
    function getUserTokenProposals(address user, uint256 tokenId) external view returns (uint256[] memory) {
        return userTokenProposals[user][tokenId];
    }
    
    // Get active proposals for token
    function getActiveTokenProposals(uint256 tokenId) external view returns (uint256[] memory) {
        uint256[] memory allProposals = tokenProposals[tokenId];
        uint256[] memory activeProposals = new uint256[](allProposals.length);
        uint256 activeCount = 0;
        
        for (uint256 i = 0; i < allProposals.length; i++) {
            if (!ownerProposals[allProposals[i]].executed) {
                activeProposals[activeCount] = allProposals[i];
                activeCount++;
            }
        }
        
        // Resize array
        uint256[] memory result = new uint256[](activeCount);
        for (uint256 j = 0; j < activeCount; j++) {
            result[j] = activeProposals[j];
        }
        
        return result;
    }
    
    // Get proposals requiring user's signature
    function getProposalsAwaitingUserSignature(address user) external view returns (uint256[] memory) {
        uint256[] memory awaitingProposals = new uint256[](nextProposalId - 1);
        uint256 count = 0;
        
        for (uint256 i = 1; i < nextProposalId; i++) {
            OwnerProposal storage proposal = ownerProposals[i];
            
            if (!proposal.executed && !proposal.hasSigned[user]) {
                // Check if user is required signer
                for (uint256 j = 0; j < proposal.requiredSigners.length; j++) {
                    if (proposal.requiredSigners[j] == user) {
                        awaitingProposals[count] = i;
                        count++;
                        break;
                    }
                }
            }
        }
        
        // Resize array
        uint256[] memory result = new uint256[](count);
        for (uint256 k = 0; k < count; k++) {
            result[k] = awaitingProposals[k];
        }
        
        return result;
    }
    
    // Get proposal statistics
    function getProposalStats() external view returns (
        uint256 totalProposals,
        uint256 executedProposals,
        uint256 pendingProposals,
        uint256 addOwnerProposals,
        uint256 removeOwnerProposals
    ) {
        totalProposals = nextProposalId - 1;
        
        for (uint256 i = 1; i < nextProposalId; i++) {
            OwnerProposal storage proposal = ownerProposals[i];
            
            if (proposal.executed) {
                executedProposals++;
            } else {
                pendingProposals++;
            }
            
            if (proposal.proposalType == ProposalType.ADD_OWNER) {
                addOwnerProposals++;
            } else if (proposal.proposalType == ProposalType.REMOVE_OWNER) {
                removeOwnerProposals++;
            }
        }
    }
    
    // Debug function: Get detailed proposal info
    function debugProposal(uint256 proposalId) external view returns (
        string memory proposalTypeStr,
        string memory status,
        address[] memory signers,
        bool[] memory signatureStatus,
        uint256 progress
    ) {
        require(proposalId < nextProposalId, "Proposal does not exist");
        OwnerProposal storage proposal = ownerProposals[proposalId];
        
        // Convert enum to string
        if (proposal.proposalType == ProposalType.ADD_OWNER) {
            proposalTypeStr = "ADD_OWNER";
        } else if (proposal.proposalType == ProposalType.REMOVE_OWNER) {
            proposalTypeStr = "REMOVE_OWNER";
        } else {
            proposalTypeStr = "PROPERTY_TRANSFER";
        }
        
        // Status
        if (proposal.executed) {
            status = "EXECUTED";
        } else if (proposal.signatureCount == proposal.requiredSigners.length) {
            status = "READY_TO_EXECUTE";
        } else {
            status = "PENDING_SIGNATURES";
        }
        
        // Signers and their status
        signers = proposal.requiredSigners;
        signatureStatus = new bool[](signers.length);
        
        for (uint256 i = 0; i < signers.length; i++) {
            signatureStatus[i] = proposal.hasSigned[signers[i]];
        }
        
        // Progress percentage
        progress = (proposal.signatureCount * 100) / proposal.requiredSigners.length;
        
        return (proposalTypeStr, status, signers, signatureStatus, progress);
    }
}
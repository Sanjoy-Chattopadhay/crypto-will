// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract MultiOwnerNFT is ERC721, ReentrancyGuard, Ownable {
    constructor() ERC721("MultiOwnerNFT", "MONFT") Ownable(msg.sender) {}
    
    // Token counter
    uint256 private _nextTokenId = 1;
    
    // Existing divisible assets (original functionality)
    mapping(uint256 => mapping(address => uint256)) public tokenHolders;
    mapping(uint256 => uint256) public tokenSupplies;
    mapping(uint256 => bool) public isDivisible;
    
    // NEW: Indivisible multi-owner assets
    mapping(uint256 => bool) public isIndivisible;
    mapping(uint256 => address[]) public indivisibleOwners;
    mapping(uint256 => mapping(address => bool)) public isOwnerOfToken;
    mapping(uint256 => uint256) public ownerCount;
    
    // Token metadata
    mapping(uint256 => string) public tokenURIs;
    
    // Events
    event AssetCreated(uint256 indexed tokenId, bool isIndivisible, address[] owners, uint256[] amounts);
    event IndivisibleAssetCreated(uint256 indexed tokenId, address[] owners);
    event OwnerAdded(uint256 indexed tokenId, address indexed newOwner);
    event OwnerRemoved(uint256 indexed tokenId, address indexed removedOwner);
    
    // constructor() ERC721("MultiOwnerNFT", "MONFT") {}
    
    // EXISTING FUNCTIONALITY: Create divisible asset
    function createAsset(
        string memory uri,
        address[] memory holders,
        uint256[] memory amounts
    ) external returns (uint256) {
        require(holders.length == amounts.length, "Arrays length mismatch");
        require(holders.length > 0, "No holders provided");
        
        uint256 tokenId = _nextTokenId++;
        uint256 totalSupply = 0;
        
        // Calculate total supply and set holders
        for (uint256 i = 0; i < holders.length; i++) {
            require(amounts[i] > 0, "Amount must be greater than 0");
            tokenHolders[tokenId][holders[i]] = amounts[i];
            totalSupply += amounts[i];
        }
        
        tokenSupplies[tokenId] = totalSupply;
        isDivisible[tokenId] = true;
        tokenURIs[tokenId] = uri;
        
        // Mint to contract
        _mint(address(this), tokenId);
        
        emit AssetCreated(tokenId, false, holders, amounts);
        return tokenId;
    }
    
    // NEW FUNCTIONALITY: Create indivisible asset (supply = 1, equal ownership)
    function createIndivisibleAsset(
        string memory uri,
        address[] memory owners
    ) external returns (uint256) {
        require(owners.length > 0, "No owners provided");
        require(owners.length <= 20, "Too many owners"); // Reasonable limit
        
        // Check for duplicates
        for (uint256 i = 0; i < owners.length; i++) {
            require(owners[i] != address(0), "Invalid owner address");
            for (uint256 j = i + 1; j < owners.length; j++) {
                require(owners[i] != owners[j], "Duplicate owner");
            }
        }
        
        uint256 tokenId = _nextTokenId++;
        
        // Mark as indivisible
        isIndivisible[tokenId] = true;
        tokenURIs[tokenId] = uri;
        ownerCount[tokenId] = owners.length;
        
        // Add all owners with equal rights (no percentages)
        for (uint256 i = 0; i < owners.length; i++) {
            indivisibleOwners[tokenId].push(owners[i]);
            isOwnerOfToken[tokenId][owners[i]] = true;
        }
        
        // Mint to contract (contract holds the actual NFT)
        _mint(address(this), tokenId);
        
        emit IndivisibleAssetCreated(tokenId, owners);
        return tokenId;
    }
    
    // Add owner to indivisible asset (called by will manager after approval)
    function addOwnerToIndivisibleAsset(
        uint256 tokenId,
        address newOwner
    ) external {
        require(msg.sender == owner(), "Only will manager can call");
        require(isIndivisible[tokenId], "Token is not indivisible");
        require(!isOwnerOfToken[tokenId][newOwner], "Already an owner");
        require(newOwner != address(0), "Invalid owner address");
        
        indivisibleOwners[tokenId].push(newOwner);
        isOwnerOfToken[tokenId][newOwner] = true;
        ownerCount[tokenId]++;
        
        emit OwnerAdded(tokenId, newOwner);
    }
    
    // Remove owner from indivisible asset (called by will manager after approval)
    function removeOwnerFromIndivisibleAsset(
        uint256 tokenId,
        address ownerToRemove
    ) external {
        require(msg.sender == owner(), "Only will manager can call");
        require(isIndivisible[tokenId], "Token is not indivisible");
        require(isOwnerOfToken[tokenId][ownerToRemove], "Not an owner");
        require(ownerCount[tokenId] > 1, "Cannot remove last owner");
        
        // Remove from owners array
        address[] storage owners = indivisibleOwners[tokenId];
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == ownerToRemove) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        
        isOwnerOfToken[tokenId][ownerToRemove] = false;
        ownerCount[tokenId]--;
        
        emit OwnerRemoved(tokenId, ownerToRemove);
    }
    
    // TRACKING METHODS
    
    // Get all owners of an indivisible token
    function getIndivisibleOwners(uint256 tokenId) external view returns (address[] memory) {
        require(isIndivisible[tokenId], "Token is not indivisible");
        return indivisibleOwners[tokenId];
    }
    
    // Get owner count for indivisible token
    function getOwnerCount(uint256 tokenId) external view returns (uint256) {
        if (isIndivisible[tokenId]) {
            return ownerCount[tokenId];
        } else if (isDivisible[tokenId]) {
            // Count holders with non-zero amounts
            uint256 count = 0;
            // Note: This would require tracking holders in array for divisible assets
            // For now, return 0 as placeholder
            return count;
        }
        return 0;
    }
    
    // Check if address is owner of indivisible token
    function isOwnerOf(uint256 tokenId, address user) external view returns (bool) {
        return isOwnerOfToken[tokenId][user];
    }
    
    // Get token type
    function getTokenType(uint256 tokenId) external view returns (string memory) {
        if (isIndivisible[tokenId]) {
            return "INDIVISIBLE";
        } else if (isDivisible[tokenId]) {
            return "DIVISIBLE";
        }
        return "NOT_EXISTS";
    }
    
    // Get token info for debugging
    function getTokenInfo(uint256 tokenId) external view returns (
        bool exists,
        string memory tokenType,
        string memory uri,
        uint256 supply,
        uint256 owners
    ) {
        exists = _exists(tokenId);
        if (!exists) {
            return (false, "NOT_EXISTS", "", 0, 0);
        }
        
        uri = tokenURIs[tokenId];
        
        if (isIndivisible[tokenId]) {
            tokenType = "INDIVISIBLE";
            supply = 1;
            owners = ownerCount[tokenId];
        } else if (isDivisible[tokenId]) {
            tokenType = "DIVISIBLE";
            supply = tokenSupplies[tokenId];
            owners = 0; // Would need additional tracking for accurate count
        }
    }
    
    // Get all tokens owned by user (including partial ownership)
    function getTokensOwnedBy(address user) external view returns (uint256[] memory) {
        uint256[] memory ownedTokens = new uint256[](_nextTokenId - 1);
        uint256 count = 0;
        
        for (uint256 i = 1; i < _nextTokenId; i++) {
            if (isIndivisible[i] && isOwnerOfToken[i][user]) {
                ownedTokens[count] = i;
                count++;
            } else if (isDivisible[i] && tokenHolders[i][user] > 0) {
                ownedTokens[count] = i;
                count++;
            }
        }
        
        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 j = 0; j < count; j++) {
            result[j] = ownedTokens[j];
        }
        
        return result;
    }
    
    // Set will manager as owner (for access control)
    function setWillManager(address willManager) external onlyOwner {
        _transferOwnership(willManager);
    }
    
    // Check if token exists
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
    
    // Override tokenURI
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Token does not exist");
        return tokenURIs[tokenId];
    }
    
    // Get total tokens minted
    function totalSupply() external view returns (uint256) {
        return _nextTokenId - 1;
    }
}
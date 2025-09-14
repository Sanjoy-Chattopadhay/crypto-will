// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract UnifiedNFTContract is ERC721, ERC721Enumerable, ReentrancyGuard, Ownable {
    
    uint256 private _nextTokenId = 1;
    
    // Token types
    enum TokenType { REGULAR, DIVISIBLE, INDIVISIBLE }
    
    // Regular ERC721 features (merged from TestERC721)
    mapping(uint256 => string) private _tokenURIs;
    string private _baseTokenURI;
    
    // Multi-owner features (merged from MultiOwnerNFT)
    mapping(uint256 => TokenType) public tokenTypes;
    mapping(uint256 => mapping(address => uint256)) public tokenHolders; // divisible assets
    mapping(uint256 => uint256) public tokenSupplies; // divisible total supply
    mapping(uint256 => address[]) public indivisibleOwners;
    mapping(uint256 => mapping(address => bool)) public isOwnerOfToken;
    mapping(uint256 => uint256) public ownerCount;
    
    // Will Manager authorization
    mapping(address => bool) public authorizedManagers;
    
    // Events
    event AssetCreated(uint256 indexed tokenId, TokenType tokenType, address[] owners, uint256[] amounts);
    event OwnerAdded(uint256 indexed tokenId, address indexed newOwner, address indexed authorizedBy);
    event OwnerRemoved(uint256 indexed tokenId, address indexed removedOwner, address indexed authorizedBy);
    event ManagerAuthorized(address indexed manager);
    event ManagerRevoked(address indexed manager);
    
    modifier onlyAuthorizedManager() {
        require(authorizedManagers[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseURI
    ) ERC721(_name, _symbol) Ownable(msg.sender) {
        _baseTokenURI = _baseURI;
    }
    
    /**
     * @dev Authorize a will manager contract
     */
    function authorizeManager(address manager) external onlyOwner {
        require(manager != address(0), "Invalid manager address");
        authorizedManagers[manager] = true;
        emit ManagerAuthorized(manager);
    }
    
    function revokeManager(address manager) external onlyOwner {
        authorizedManagers[manager] = false;
        emit ManagerRevoked(manager);
    }
    
    // REGULAR NFT FUNCTIONS (from TestERC721)
    
    function mint(address to) external onlyOwner returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _mint(to, tokenId);
        tokenTypes[tokenId] = TokenType.REGULAR;
        
        address[] memory owners = new address[](1);
        owners[0] = to;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        
        emit AssetCreated(tokenId, TokenType.REGULAR, owners, amounts);
        return tokenId;
    }
    
    function mintWithId(address to, uint256 tokenId) external onlyOwner {
        require(_ownerOf(tokenId) == address(0), "Token already exists");
        _mint(to, tokenId);
        tokenTypes[tokenId] = TokenType.REGULAR;
        
        if (tokenId >= _nextTokenId) {
            _nextTokenId = tokenId + 1;
        }
        
        address[] memory owners = new address[](1);
        owners[0] = to;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        
        emit AssetCreated(tokenId, TokenType.REGULAR, owners, amounts);
    }
    
    function batchMint(address to, uint256 amount) external onlyOwner returns (uint256[] memory) {
        uint256[] memory tokenIds = new uint256[](amount);
        
        for (uint256 i = 0; i < amount; i++) {
            uint256 tokenId = _nextTokenId++;
            _mint(to, tokenId);
            tokenTypes[tokenId] = TokenType.REGULAR;
            tokenIds[i] = tokenId;
        }
        
        return tokenIds;
    }
    
    function burn(uint256 tokenId) external onlyOwner {
        _burn(tokenId);
        delete tokenTypes[tokenId];
        delete _tokenURIs[tokenId];
        
        // Clean up multi-owner data if applicable
        if (tokenTypes[tokenId] == TokenType.INDIVISIBLE) {
            delete indivisibleOwners[tokenId];
            delete ownerCount[tokenId];
        }
    }
    
    // MULTI-OWNER NFT FUNCTIONS (from MultiOwnerNFT)
    
    function createDivisibleAsset(
        string memory uri,
        address[] memory holders,
        uint256[] memory amounts
    ) external returns (uint256) {
        require(holders.length == amounts.length, "Arrays length mismatch");
        require(holders.length > 0, "No holders provided");
        
        uint256 tokenId = _nextTokenId++;
        uint256 totalSupply = 0;
        
        for (uint256 i = 0; i < holders.length; i++) {
            require(holders[i] != address(0), "Invalid holder address");
            require(amounts[i] > 0, "Amount must be greater than 0");
            tokenHolders[tokenId][holders[i]] = amounts[i];
            totalSupply += amounts[i];
        }
        
        tokenSupplies[tokenId] = totalSupply;
        tokenTypes[tokenId] = TokenType.DIVISIBLE;
        _tokenURIs[tokenId] = uri;
        
        _mint(address(this), tokenId);
        
        emit AssetCreated(tokenId, TokenType.DIVISIBLE, holders, amounts);
        return tokenId;
    }
    
    function createIndivisibleAsset(
        string memory uri,
        address[] memory owners
    ) external returns (uint256) {
        require(owners.length > 0, "No owners provided");
        require(owners.length <= 20, "Too many owners");
        
        // Check for duplicates and zero addresses
        for (uint256 i = 0; i < owners.length; i++) {
            require(owners[i] != address(0), "Invalid owner address");
            for (uint256 j = i + 1; j < owners.length; j++) {
                require(owners[i] != owners[j], "Duplicate owner");
            }
        }
        
        uint256 tokenId = _nextTokenId++;
        
        tokenTypes[tokenId] = TokenType.INDIVISIBLE;
        _tokenURIs[tokenId] = uri;
        ownerCount[tokenId] = owners.length;
        
        for (uint256 i = 0; i < owners.length; i++) {
            indivisibleOwners[tokenId].push(owners[i]);
            isOwnerOfToken[tokenId][owners[i]] = true;
        }
        
        _mint(address(this), tokenId);
        
        uint256[] memory emptyAmounts = new uint256[](0);
        emit AssetCreated(tokenId, TokenType.INDIVISIBLE, owners, emptyAmounts);
        return tokenId;
    }
    
    function addOwnerToIndivisibleAsset(
        uint256 tokenId,
        address newOwner
    ) external onlyAuthorizedManager {
        require(tokenTypes[tokenId] == TokenType.INDIVISIBLE, "Token is not indivisible");
        require(!isOwnerOfToken[tokenId][newOwner], "Already an owner");
        require(newOwner != address(0), "Invalid owner address");
        require(ownerCount[tokenId] < 20, "Too many owners");
        
        indivisibleOwners[tokenId].push(newOwner);
        isOwnerOfToken[tokenId][newOwner] = true;
        ownerCount[tokenId]++;
        
        emit OwnerAdded(tokenId, newOwner, msg.sender);
    }
    
    function removeOwnerFromIndivisibleAsset(
        uint256 tokenId,
        address ownerToRemove
    ) external onlyAuthorizedManager {
        require(tokenTypes[tokenId] == TokenType.INDIVISIBLE, "Token is not indivisible");
        require(isOwnerOfToken[tokenId][ownerToRemove], "Not an owner");
        require(ownerCount[tokenId] > 1, "Cannot remove last owner");
        
        // Find and remove from owners array - maintain order
        address[] storage owners = indivisibleOwners[tokenId];
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == ownerToRemove) {
                for (uint256 j = i; j < owners.length - 1; j++) {
                    owners[j] = owners[j + 1];
                }
                owners.pop();
                break;
            }
        }
        
        isOwnerOfToken[tokenId][ownerToRemove] = false;
        ownerCount[tokenId]--;
        
        emit OwnerRemoved(tokenId, ownerToRemove, msg.sender);
    }
    
    function transferDivisibleShare(
        uint256 tokenId,
        address from,
        address to,
        uint256 amount
    ) external onlyAuthorizedManager {
        require(tokenTypes[tokenId] == TokenType.DIVISIBLE, "Token is not divisible");
        require(tokenHolders[tokenId][from] >= amount, "Insufficient balance");
        require(to != address(0), "Invalid recipient");
        
        tokenHolders[tokenId][from] -= amount;
        tokenHolders[tokenId][to] += amount;
    }
    
    // UNIFIED QUERY FUNCTIONS
    
    function getTokenType(uint256 tokenId) external view returns (TokenType) {
        require(_exists(tokenId), "Token does not exist");
        return tokenTypes[tokenId];
    }
    
    function isOwnerOf(uint256 tokenId, address user) external view returns (bool) {
        if (tokenTypes[tokenId] == TokenType.REGULAR) {
            return ownerOf(tokenId) == user;
        } else if (tokenTypes[tokenId] == TokenType.INDIVISIBLE) {
            return isOwnerOfToken[tokenId][user];
        } else if (tokenTypes[tokenId] == TokenType.DIVISIBLE) {
            return tokenHolders[tokenId][user] > 0;
        }
        return false;
    }
    
    function getIndivisibleOwners(uint256 tokenId) external view returns (address[] memory) {
        require(tokenTypes[tokenId] == TokenType.INDIVISIBLE, "Token is not indivisible");
        return indivisibleOwners[tokenId];
    }
    
    function getOwnerCount(uint256 tokenId) external view returns (uint256) {
        if (tokenTypes[tokenId] == TokenType.INDIVISIBLE) {
            return ownerCount[tokenId];
        } else if (tokenTypes[tokenId] == TokenType.REGULAR) {
            return 1;
        }
        return 0; // For divisible, would need more complex counting
    }
    
    function isDivisible(uint256 tokenId) external view returns (bool) {
        return tokenTypes[tokenId] == TokenType.DIVISIBLE;
    }
    
    function isIndivisible(uint256 tokenId) external view returns (bool) {
        return tokenTypes[tokenId] == TokenType.INDIVISIBLE;
    }
    
    // URI FUNCTIONS
    
    function setTokenURI(uint256 tokenId, string memory uri) external onlyOwner {
        require(_exists(tokenId), "Token does not exist");
        _tokenURIs[tokenId] = uri;
    }
    
    function setBaseURI(string memory baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
    }
    
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "Token does not exist");
        
        string memory tokenSpecificURI = _tokenURIs[tokenId];
        string memory base = _baseURI();
        
        if (bytes(tokenSpecificURI).length > 0) {
            return tokenSpecificURI;
        }
        
        return bytes(base).length > 0 ? string(abi.encodePacked(base, toString(tokenId))) : "";
    }
    
    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }
    
    // UTILITY FUNCTIONS
    
    function getOwnedTokens(address user) external view returns (uint256[] memory) {
        uint256[] memory ownedTokens = new uint256[](_nextTokenId - 1);
        uint256 count = 0;
        
        for (uint256 i = 1; i < _nextTokenId; i++) {
            if (_exists(i)) {
                bool isOwner = false;
                
                if (tokenTypes[i] == TokenType.REGULAR && ownerOf(i) == user) {
                    isOwner = true;
                } else if (tokenTypes[i] == TokenType.INDIVISIBLE && isOwnerOfToken[i][user]) {
                    isOwner = true;
                } else if (tokenTypes[i] == TokenType.DIVISIBLE && tokenHolders[i][user] > 0) {
                    isOwner = true;
                }
                
                if (isOwner) {
                    ownedTokens[count] = i;
                    count++;
                }
            }
        }
        
        uint256[] memory result = new uint256[](count);
        for (uint256 j = 0; j < count; j++) {
            result[j] = ownedTokens[j];
        }
        
        return result;
    }
    
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
    
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    function getCollectionInfo() external view returns (
        string memory collectionName,
        string memory collectionSymbol,
        uint256 totalMinted,
        string memory baseURI,
        address contractOwner
    ) {
        return (
            name(),
            symbol(),
            totalSupply(),
            _baseTokenURI,
            owner()
        );
    }
    
    function rescueNFT(address tokenContract, address to, uint256 tokenId) external onlyOwner {
        IERC721(tokenContract).transferFrom(address(this), to, tokenId);
    }
    
    // Required overrides for multiple inheritance
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }
    
    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TestERC721 is ERC721, Ownable {
    uint256 private _currentTokenId = 0;
    
    // Optional mapping for token URIs
    mapping(uint256 => string) private _tokenURIs;
    
    // Base URI for metadata
    string private _baseTokenURI;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseURI
    ) ERC721(_name, _symbol) Ownable(msg.sender) {
        _baseTokenURI = _baseURI;
    }

    /**
     * @dev Mint NFT to specific address (for testing purposes)
     * @param to Address to mint NFT to
     * @return tokenId The ID of the newly minted token
     */
    function mint(address to) external onlyOwner returns (uint256) {
        _currentTokenId++;
        uint256 tokenId = _currentTokenId;
        _mint(to, tokenId);
        return tokenId;
    }

    /**
     * @dev Mint NFT with specific token ID (for testing purposes)
     * @param to Address to mint NFT to
     * @param tokenId Specific token ID to mint
     */
    /**
 * @dev Mint NFT with specific token ID (for testing purposes)
 * @param to Address to mint NFT to
 * @param tokenId Specific token ID to mint
 */
    function mintWithId(address to, uint256 tokenId) external onlyOwner {
        require(_ownerOf(tokenId) == address(0), "Token already exists");
        _mint(to, tokenId);
        
        // Update current token ID if minting with higher ID
        if (tokenId > _currentTokenId) {
            _currentTokenId = tokenId;
        }
    }


    /**
     * @dev Mint multiple NFTs to address (for testing purposes)
     * @param to Address to mint NFTs to
     * @param amount Number of NFTs to mint
     * @return tokenIds Array of minted token IDs
     */
    function batchMint(address to, uint256 amount) external onlyOwner returns (uint256[] memory) {
        uint256[] memory tokenIds = new uint256[](amount);
        
        for (uint256 i = 0; i < amount; i++) {
            _currentTokenId++;
            uint256 tokenId = _currentTokenId;
            _mint(to, tokenId);
            tokenIds[i] = tokenId;
        }
        
        return tokenIds;
    }

    /**
     * @dev Burn NFT (for testing purposes)
     * @param tokenId Token ID to burn
     */
    function burn(uint256 tokenId) external onlyOwner {
        _burn(tokenId);
    }

    /**
     * @dev Set token URI for specific token
     * @param tokenId Token ID
     * @param uri Metadata URI
     */
    /**
    * @dev Set token URI for specific token
    * @param tokenId Token ID
    * @param uri Metadata URI
    */
    function setTokenURI(uint256 tokenId, string memory uri) external onlyOwner {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        _tokenURIs[tokenId] = uri;
    }


    /**
     * @dev Set base URI for all tokens
     * @param baseURI New base URI
     */
    function setBaseURI(string memory baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
    }

    /**
    * @dev Get token URI
    * @param tokenId Token ID
    * @return Token metadata URI
    */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");

        string memory tokenSpecificURI = _tokenURIs[tokenId];
        string memory base = _baseURI();

        // If there is a token-specific URI, return it
        if (bytes(tokenSpecificURI).length > 0) {
            return tokenSpecificURI;
        }

        // Otherwise, concatenate base URI and token ID
        return bytes(base).length > 0 ? string(abi.encodePacked(base, toString(tokenId))) : "";
    }


    /**
     * @dev Get all tokens owned by an address
     * @param owner Owner address
     * @return Array of token IDs
     */
    /**
 * @dev Get all tokens owned by an address
 * @param owner Owner address
 * @return Array of token IDs
 */
    function getOwnedTokens(address owner) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory tokens = new uint256[](balance);
        uint256 index = 0;

        for (uint256 tokenId = 1; tokenId <= _currentTokenId; tokenId++) {
            if (_ownerOf(tokenId) != address(0) && ownerOf(tokenId) == owner) {
                tokens[index] = tokenId;
                index++;
            }
        }

        return tokens;
    }


    /**
     * @dev Check if token exists
     * @param tokenId Token ID to check
     * @return True if token exists
     */
    /**
 * @dev Check if token exists
 * @param tokenId Token ID to check
 * @return True if token exists
 */
    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }


    /**
     * @dev Get total number of tokens minted
     * @return Current token ID (total minted)
     */
    function totalSupply() external view returns (uint256) {
        return _currentTokenId;
    }

    /**
     * @dev Get NFT collection info for testing
     */
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
            _currentTokenId,
            _baseTokenURI,
            owner()
        );
    }

    /**
     * @dev Helper function to convert uint to string
     */
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
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

    /**
     * @dev Override _baseURI function
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @dev Emergency token rescue function
     * @param tokenContract Contract address of stuck tokens
     * @param to Address to send tokens to
     * @param tokenId Token ID to rescue
     */
    function rescueNFT(address tokenContract, address to, uint256 tokenId) external onlyOwner {
        IERC721(tokenContract).transferFrom(address(this), to, tokenId);
    }
}

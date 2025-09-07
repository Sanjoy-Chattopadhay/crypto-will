// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TestMultiOwnerNFT is ERC1155, Ownable {
    uint256 private _nextId;

    // tokenId => holders
    mapping(uint256 => address[]) private _holders;
    mapping(uint256 => mapping(address => bool)) private _isHolder;

    constructor() ERC1155("ipfs://base-uri/") Ownable(msg.sender) {}

    /// @notice Mint a new tokenId and distribute amounts to recipients
    function createAsset(
        address[] calldata recipients,
        uint256[] calldata amounts,
        string calldata /*uriForId*/
    ) external onlyOwner returns (uint256 tokenId) {
        require(recipients.length == amounts.length, "Length mismatch");
        tokenId = ++_nextId;

        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], tokenId, amounts[i], "");
            _addHolder(tokenId, recipients[i]);
        }
    }

    /// @notice Enumerate holders of a tokenId
    function getHolders(uint256 id) external view returns (address[] memory) {
        return _holders[id];
    }

    // --- Internals ---

    function _addHolder(uint256 id, address account) internal {
        if (!_isHolder[id][account] && balanceOf(account, id) > 0) {
            _isHolder[id][account] = true;
            _holders[id].push(account);
        }
    }

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts
    ) internal override {
        super._update(from, to, ids, amounts);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (from != address(0) && balanceOf(from, id) == 0) {
                _isHolder[id][from] = false;
                // we keep them in the array, safe enough for testing
            }
            if (to != address(0)) {
                _addHolder(id, to);
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TestERC20 is ERC20, Ownable {
    
    uint8 private _decimals;
    
     constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply
    ) ERC20(_name, _symbol) Ownable(msg.sender) { // ← Fix: Pass msg.sender to Ownable
        _mint(msg.sender, _totalSupply);
    }
    
    /**
     * @dev Override decimals function
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
    
    /**
     * @dev Mint tokens to any address (for testing purposes)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint (in wei units)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    
    /**
     * @dev Burn tokens from any address (for testing purposes)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn (in wei units)
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
    
    /**
     * @dev Set allowance for testing (bypasses normal approval)
     * @param owner Token owner address
     * @param spender Spender address
     * @param amount Allowance amount
     */
    function setAllowance(address owner, address spender, uint256 amount) external onlyOwner {
        _approve(owner, spender, amount);
    }
    
    /**
     * @dev Get balance in readable format (with decimals)
     * @param account Account to check balance for
     * @return Formatted balance as string
     */
    function getReadableBalance(address account) external view returns (string memory) {
        uint256 balance = balanceOf(account);
        uint256 wholePart = balance / 10**_decimals;
        uint256 fractionalPart = balance % 10**_decimals;
        
        return string(abi.encodePacked(
            uintToString(wholePart), 
            ".", 
            uintToString(fractionalPart)
        ));
    }
    
    
    function uintToString(uint256 value) internal pure returns (string memory) {
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
    
    
    function batchTransfer(address[] calldata recipients, uint256[] calldata amounts) external {
        require(recipients.length == amounts.length, "Arrays length mismatch");
        
        for (uint256 i = 0; i < recipients.length; i++) {
            transfer(recipients[i], amounts[i]);
        }
    }
    
    
    function getTokenInfo() external view returns (
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals,
        uint256 tokenTotalSupply,
        address tokenOwner
    ) {
        return (
            name(),
            symbol(),
            decimals(),
            totalSupply(),
            owner()
        );
    }
}

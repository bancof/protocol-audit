// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "hardhat/console.sol";

contract TestNft1155 is ERC1155 {
  uint256 public constant CROWN = 1;
  uint256 public constant SHIELD = 2;
  uint256 public constant SWORD = 3;
  uint256 public constant GUN = 4;
  uint256 public constant COPPER = 5;
  uint256 public constant IRON = 6;
  uint256 public constant BRONZE = 7;
  uint256 public constant SILVER = 8;
  uint256 public constant GOLD = 9;
  uint256 public constant SAPHIRE = 10;
  uint256 public constant EMERALD = 11;
  uint256 public constant RUBY = 12;
  uint256 public constant DIAMOND = 13;

  string private baseUri;

  string public name;

  constructor(string memory _name, string memory _baseUri) ERC1155(_baseUri) {
    baseUri = _baseUri;
    name = _name;
    _mint(msg.sender, CROWN, 20, "");
    _mint(msg.sender, SHIELD, 19, "");
    _mint(msg.sender, SWORD, 18, "");
    _mint(msg.sender, GUN, 17, "");
    _mint(msg.sender, COPPER, 16, "");
    _mint(msg.sender, IRON, 15, "");
    _mint(msg.sender, BRONZE, 14, "");
    _mint(msg.sender, SILVER, 13, "");
    _mint(msg.sender, GOLD, 12, "");
    _mint(msg.sender, SAPHIRE, 11, "");
    _mint(msg.sender, EMERALD, 10, "");
    _mint(msg.sender, RUBY, 9, "");
    _mint(msg.sender, DIAMOND, 8, "");
  }

  function uri(uint256 tokenId) public view override returns (string memory) {
    return string(abi.encodePacked(baseUri, Strings.toString(tokenId), ".json"));
  }
}

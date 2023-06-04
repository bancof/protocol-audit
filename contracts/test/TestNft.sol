// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract TestNft is ERC721 {
  uint256 private counter;
  mapping(address => uint256) public mintCounts;
  mapping(uint256 => string) public uris;

  constructor(string memory name, string memory symbol) ERC721(name, symbol) {}

  function mint() public {
    require(mintCounts[msg.sender] <= 50, "exceed mint limit");
    mintCounts[msg.sender] += 1;
    _mint(msg.sender, counter);
    counter += 1;
  }

  function tokenURI(uint256 _tokenId) public pure override returns (string memory) {
    return
      string(
        abi.encodePacked(
          string(abi.encodePacked("https://api.gmstudio.art/collections/gmv2/token/", Strings.toString(_tokenId))),
          ".json"
        )
      );
  }
}

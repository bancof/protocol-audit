// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "../lib/GenericTokenInterface.sol";
import "../lib/Slots.sol";
import "../lib/KeyValueStorage.sol";
import "../globalbeacon/GlobalBeaconProxyImpl.sol";
import "./BoundNFT.sol";

bytes32 constant namespace = keccak256("contract BoundNFTManager");

abstract contract BoundNFTManager is GlobalBeaconProxyImpl, KeyValueStorage {
  using GenericTokenInterface for GenericTokenInterface.Item;
  using GenericTokenInterface for GenericTokenInterface.Collection;

  event BoundNFTCreated(address originAddress, address boundNftAddress);

  function _deployBoundNFTContract(GenericTokenInterface.Collection memory coll) private returns (BoundNFT) {
    bytes32 slot;
    if (coll.spec == GenericTokenInterface.Spec.erc721) {
      slot = Slots.BOUND_ERC721_IMPL;
    } else if (coll.spec == GenericTokenInterface.Spec.erc1155) {
      slot = Slots.BOUND_ERC1155_IMPL;
    } else {
      revert("Unsupported NFT specification");
    }
    BoundNFT bnft = BoundNFT(deployProxy(slot));
    _setAddress(keccak256(abi.encode(namespace, coll.hash())), address(bnft));
    bnft.initialize(coll.addr);
    emit BoundNFTCreated(coll.addr, address(bnft));
    return bnft;
  }

  function _getBoundNFTContract(GenericTokenInterface.Collection memory coll) private returns (BoundNFT) {
    BoundNFT boundNFT = BoundNFT(_getAddress(keccak256(abi.encode(namespace, coll.hash()))));
    if (address(boundNFT) == address(0)) {
      return _deployBoundNFTContract(coll);
    } else {
      return boundNFT;
    }
  }

  function mintBoundNFTs(address to, GenericTokenInterface.Item[] memory items, uint256[] memory amounts) internal {
    for (uint256 i = 0; i < items.length; i++) {
      if (amounts[i] > 0) {
        _getBoundNFTContract(items[i].collection).mint(to, items[i].id, amounts[i]);
      }
    }
  }

  function burnBoundNFTs(address from, GenericTokenInterface.Item[] memory items, uint256[] memory amounts) internal {
    for (uint256 i = 0; i < items.length; i++) {
      if (amounts[i] > 0) {
        _getBoundNFTContract(items[i].collection).burn(from, items[i].id, amounts[i]);
      }
    }
  }
}

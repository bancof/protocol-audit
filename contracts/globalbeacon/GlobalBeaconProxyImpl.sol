// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import { WillNotSelfDestruct, GlobalBeacon } from "./GlobalBeacon.sol";
import "../lib/Slots.sol";

contract GlobalBeaconProxyImpl {
  GlobalBeacon public immutable beacon;
  bytes32 immutable slot;

  constructor(address _beacon, bytes32 _slot) {
    beacon = GlobalBeacon(_beacon);
    slot = _slot;
  }

  function selfDestructIfCache() public {
    if (msg.sender == address(beacon) && address(this) == beacon.cache(slot)) {
      selfdestruct(payable(msg.sender));
    } else {
      revert WillNotSelfDestruct();
    }
  }

  function deployProxy(bytes32 _slot) internal returns (address) {
    return beacon.deployProxy(_slot);
  }

  function getOracleAddress() internal view returns (address) {
    return beacon.getAddress(Slots.ORACLE_ADDRESS);
  }

  function getBancofAddress() internal view returns (address) {
    return beacon.getAddress(Slots.BANCOF_ADDRESS);
  }

  function getInitialFee() internal view returns (uint256) {
    return beacon.getUint256(Slots.INITIAL_FEE);
  }

  function getInitialFeeToken() internal view returns (address) {
    return beacon.getAddress(Slots.INITIAL_FEE_TOKEN);
  }

  function getBorrowFeeBP() internal view returns (uint256) {
    return beacon.readDefaultMapUint256(Slots.BORROW_FEE_BP, bytes32(uint256(uint160(address(this)))));
  }

  function getRenewFeeBP() internal view returns (uint256) {
    return beacon.readDefaultMapUint256(Slots.RENEW_FEE_BP, bytes32(uint256(uint160(address(this)))));
  }

  function getInterestFeeBP() internal view returns (uint256) {
    return beacon.readDefaultMapUint256(Slots.INTEREST_FEE_BP, bytes32(uint256(uint160(address(this)))));
  }
}

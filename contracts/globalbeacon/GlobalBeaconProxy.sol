// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/proxy/Proxy.sol";
import "./GlobalBeacon.sol";

contract GlobalBeaconProxy is Proxy {
  GlobalBeacon immutable beacon;
  bytes32 immutable slot;
  address immutable cache;

  constructor(GlobalBeacon _beacon, bytes32 _slot) {
    beacon = _beacon;
    slot = _slot;
    cache = _beacon.cache(_slot);
  }

  function _implementation() internal view override returns (address) {
    return cache.code.length > 0 ? cache : beacon.getAddress(slot);
  }
}

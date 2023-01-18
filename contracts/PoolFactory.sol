// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;
import "./lib/PoolPolicy.sol";
import "./PoolLogic.sol";
import "./TreasuryLogic.sol";

struct AdminList {
  address poolAdmin;
  address moneyManager;
  address nftManager;
}

struct PoolConfig {
  PoolPolicy.Policy initialPolicy;
  AdminList admin;
  string poolName;
}

contract PoolFactory {
  GlobalBeacon immutable beacon;
  event PoolCreated(string poolName, AdminList admins, address pool, address treasury);

  constructor(GlobalBeacon _beacon) {
    beacon = _beacon;
  }

  function deployPool(PoolConfig calldata config) external {
    PoolLogic pool = PoolLogic(payable(beacon.deployProxy(Slots.LENDING_POOL_IMPL)));
    TreasuryLogic treasury = TreasuryLogic(payable(beacon.deployProxy(Slots.TREASURY_IMPL)));
    pool.initialize(config.initialPolicy, config.admin.poolAdmin, treasury);
    treasury.initialize(address(pool), config.admin.moneyManager, config.admin.nftManager);
    emit PoolCreated(config.poolName, config.admin, address(pool), address(treasury));
  }
}

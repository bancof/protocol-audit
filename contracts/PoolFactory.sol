// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;
import "./PoolLogic.sol";
import "./TreasuryLogic.sol";
import "./PolicyLogic.sol";

struct AdminList {
  address poolAdmin;
  address policyManager;
  address moneyManager;
  address nftManager;
}

struct PoolConfig {
  PolicyLogic.InitialPolicy initialPolicy;
  AdminList admin;
  string poolName;
}

contract PoolFactory {
  GlobalBeacon immutable beacon;
  event PoolCreated(string poolName, AdminList admins, address pool, address treasury, address policy);

  constructor(GlobalBeacon _beacon) {
    beacon = _beacon;
  }

  function deployPool(PoolConfig calldata config) external {
    PoolLogic pool = PoolLogic(payable(beacon.deployProxy(Slots.LENDING_POOL_IMPL)));
    TreasuryLogic treasury = TreasuryLogic(payable(beacon.deployProxy(Slots.TREASURY_IMPL)));
    PolicyLogic policy = PolicyLogic(beacon.deployProxy(Slots.POLICY_IMPL));

    pool.initialize(treasury, policy, config.admin.poolAdmin);
    treasury.initialize(pool, config.admin.moneyManager, config.admin.nftManager);
    policy.initialize(config.admin.policyManager, config.initialPolicy);

    emit PoolCreated(config.poolName, config.admin, address(pool), address(treasury), address(policy));
  }
}

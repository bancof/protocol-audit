// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "./PoolLogic.sol";

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
  using SafeERC20 for IERC20;

  GlobalBeacon immutable beacon;
  event PoolCreated(string poolName, AdminList admins, address pool, address treasury);

  constructor(GlobalBeacon _beacon) {
    beacon = _beacon;
  }

  function deployPool(PoolConfig calldata config) external payable {
    _deployFee();
    PoolLogic pool = PoolLogic(payable(beacon.deployProxy(Slots.LENDING_POOL_IMPL)));
    TreasuryLogic treasury = TreasuryLogic(payable(beacon.deployProxy(Slots.TREASURY_IMPL)));
    pool.initialize(config.initialPolicy, config.admin.poolAdmin, treasury);
    treasury.initialize(address(pool), config.admin.moneyManager, config.admin.nftManager);
    emit PoolCreated(config.poolName, config.admin, address(pool), address(treasury));
  }

  function _deployFee() internal {
    address initialFeeToken = beacon.getAddress(Slots.INITIAL_FEE_TOKEN);
    uint256 initialFee = beacon.getUint256(Slots.INITIAL_FEE);
    if (initialFee > 0) {
      if (initialFeeToken == address(0)) {
        require(msg.value >= initialFee, "insufficient ether to make pool");
        (bool s1, ) = beacon.getAddress(Slots.BANCOF_ADDRESS).call{ value: initialFee }("");
        (bool s2, ) = msg.sender.call{ value: msg.value - initialFee }("");
        require(s1 && s2);
      } else {
        IERC20(initialFeeToken).safeTransferFrom(msg.sender, beacon.getAddress(Slots.BANCOF_ADDRESS), initialFee);
        (bool s, ) = msg.sender.call{ value: msg.value }("");
        require(s);
      }
    }
  }
}

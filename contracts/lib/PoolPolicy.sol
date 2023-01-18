// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./GenericTokenInterface.sol";
import "./Slots.sol";

abstract contract PoolPolicy is OwnableUpgradeable {
  struct AllowedDebtToken {
    address debtToken;
    uint256 maxValuation;
  }

  struct AllowedCollection {
    GenericTokenInterface.Collection collection;
    AllowedDebtToken[] allowedDebtTokens;
  }

  struct InterestInfo {
    uint32 interestRateBP;
    uint32 earlyReturnMultiplierBP;
    uint32 lateReturnMultiplierBP;
    uint32 maxOverdue;
  }

  struct PoolwidePolicy {
    InterestInfo interestInfo;
    uint32 maxLtvBP;
    uint32 maxDuration;
    uint32 maxCollateralNumPerLoan;
  }

  struct Policy {
    PoolwidePolicy poolwide;
    AllowedCollection[] allowedcollections;
  }

  using GenericTokenInterface for GenericTokenInterface.Item;
  using GenericTokenInterface for GenericTokenInterface.Collection;

  event MaxCollateralValueSet(address nft, GenericTokenInterface.Spec spec, address debtToken, uint256 value);
  event PoolwidePolicySet(PoolwidePolicy policy);

  PoolwidePolicy public poolwide;
  mapping(bytes32 => mapping(address => uint256)) public maxValuation;

  function getReturnFeeRates(
    uint256 loanInterestRate
  ) external view returns (uint256 earlyReturnRate, uint256 lateReturnRate) {
    return (
      (loanInterestRate * poolwide.interestInfo.earlyReturnMultiplierBP) / 10000,
      (loanInterestRate * poolwide.interestInfo.lateReturnMultiplierBP) / 10000
    );
  }

  function setPolicy(Policy calldata policy) external onlyOwner {
    _setPoolwidePolicy(policy.poolwide);
    _setAllowedCollection(policy.allowedcollections);
  }

  function setPoolwidePolicy(PoolwidePolicy calldata _poolwide) external onlyOwner {
    _setPoolwidePolicy(_poolwide);
  }

  function _setPoolwidePolicy(PoolwidePolicy calldata _poolwide) internal {
    require(_poolwide.interestInfo.interestRateBP > 0, "interest-free loan is not allowed");
    poolwide = _poolwide;
    emit PoolwidePolicySet(_poolwide);
  }

  function setAllowedCollection(AllowedCollection[] calldata allowedCollections) external onlyOwner {
    _setAllowedCollection(allowedCollections);
  }

  function _setAllowedCollection(AllowedCollection[] calldata allowedCollections) internal {
    for (uint256 i = 0; i < allowedCollections.length; i++) {
      for (uint256 j = 0; j < allowedCollections[i].allowedDebtTokens.length; j++) {
        maxValuation[allowedCollections[i].collection.hash()][
          allowedCollections[i].allowedDebtTokens[j].debtToken
        ] = allowedCollections[i].allowedDebtTokens[j].maxValuation;
        emit MaxCollateralValueSet(
          allowedCollections[i].collection.addr,
          allowedCollections[i].collection.spec,
          allowedCollections[i].allowedDebtTokens[j].debtToken,
          allowedCollections[i].allowedDebtTokens[j].maxValuation
        );
      }
    }
  }
}

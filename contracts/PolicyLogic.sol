// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./globalbeacon/GlobalBeaconProxyImpl.sol";
import "./lib/GenericTokenInterface.sol";
import "./lib/Slots.sol";
import "./PoolLogic.sol";

contract PolicyLogic is GlobalBeaconProxyImpl, AccessControlUpgradeable {
  using GenericTokenInterface for GenericTokenInterface.Item;
  using GenericTokenInterface for GenericTokenInterface.Collection;

  bytes32 public constant POLICY_MANAGER = keccak256("POLICY_MANAGER");

  event MaxCollateralValueSet(address nft, GenericTokenInterface.Spec spec, address debtToken, uint256 value);
  event PoolwidePolicySet(PoolwidePolicy policy);

  struct InitialPolicy {
    PoolwidePolicy poolwide;
    GenericTokenInterface.Collection[] maxValuation_collections;
    address[] maxValuation_tokens;
    uint256[] maxValuation_values;
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

  PoolwidePolicy public poolwide;
  mapping(bytes32 => mapping(address => uint256)) public maxValuation; // keccak256(Collection) => ERC20 => Value; 0 when forbidden

  constructor(address globalBeacon) GlobalBeaconProxyImpl(globalBeacon, Slots.POLICY_IMPL) {}

  function initialize(address policyManager, InitialPolicy calldata initial) external initializer {
    _grantRole(POLICY_MANAGER, policyManager);
    _setPoolwidePolicy(initial.poolwide);
    _setMaxValuation(initial.maxValuation_collections, initial.maxValuation_tokens, initial.maxValuation_values);
  }

  function approveLoanAndGetInterestRateBP(PoolLogic.Loan calldata loan) external view returns (InterestInfo memory) {
    uint256 totalValuation = 0;
    for (uint256 i = 0; i < loan.collaterals.length; i++) {
      require(loan.collateralAmounts[i] > 0, "Collateral amount cannot be zero");
      require(
        loan.valuations[i] <= maxValuation[loan.collaterals[i].collection.hash()][loan.principalToken],
        "Malformed quotation: valuation is too high"
      );
      require(loan.valuations[i] > 0, "Malformed quotation: valuation is too low");

      totalValuation += loan.valuations[i] * loan.collateralAmounts[i];
    }
    uint256 ltvBP = (loan.principal * 10000) / totalValuation;
    require(ltvBP <= poolwide.maxLtvBP, "Principal amount is too large");

    require(loan.principal > 0, "The loan is too small");
    require(loan.collaterals.length <= poolwide.maxCollateralNumPerLoan, "Number of collateral is too large");
    require(loan.duration > 0, "Debt duration is too short");
    require(loan.duration <= poolwide.maxDuration, "Debt duration is too long");

    return (poolwide.interestInfo);
  }

  function getReturnFeeRates(
    uint256 loanInterestRate
  ) external view returns (uint256 earlyReturnRate, uint256 lateReturnRate) {
    return (
      (loanInterestRate * poolwide.interestInfo.earlyReturnMultiplierBP) / 10000,
      (loanInterestRate * poolwide.interestInfo.lateReturnMultiplierBP) / 10000
    );
  }

  function setMaxValuation(
    GenericTokenInterface.Collection[] calldata collections,
    address[] calldata tokens,
    uint256[] calldata values
  ) external onlyRole(POLICY_MANAGER) {
    _setMaxValuation(collections, tokens, values);
  }

  function _setMaxValuation(
    GenericTokenInterface.Collection[] calldata collections,
    address[] calldata tokens,
    uint256[] calldata values
  ) internal {
    for (uint256 i = 0; i < collections.length; i++) {
      maxValuation[collections[i].hash()][tokens[i]] = values[i];
      emit MaxCollateralValueSet(collections[i].addr, collections[i].spec, tokens[i], values[i]);
    }
  }

  function setPoolwidePolicy(PoolwidePolicy calldata _poolwide) external onlyRole(POLICY_MANAGER) {
    _setPoolwidePolicy(_poolwide);
  }

  function _setPoolwidePolicy(PoolwidePolicy calldata _poolwide) internal {
    poolwide = _poolwide;
    emit PoolwidePolicySet(_poolwide);
  }
}

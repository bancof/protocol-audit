// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./lib/Slots.sol";
import "./lib/GenericTokenInterface.sol";
import "./lib/PoolPolicy.sol";
import "./boundnft/BoundNFTManager.sol";
import "./TreasuryLogic.sol";
import "hardhat/console.sol";

contract PoolLogic is ReentrancyGuardUpgradeable, PoolPolicy, BoundNFTManager, ERC1155Holder, ERC721Holder {
  using SafeERC20 for IERC20;
  using ECDSA for bytes32;
  using GenericTokenInterface for GenericTokenInterface.Item;
  using GenericTokenInterface for GenericTokenInterface.Collection;

  struct Loan {
    address borrower;
    uint256 beginTime;
    uint256 duration;
    address principalToken;
    uint256 principal;
    GenericTokenInterface.Item[] collaterals;
    uint256[] collateralAmounts;
    uint256[] valuations;
  }

  struct LoanPartialUpdateInfo {
    bytes32 updateLoanHash;
    uint256 principal;
    uint256[] collateralAmounts;
  }

  event Borrowed(PoolPolicy.InterestInfo interestInfo, bytes32 lastLoanHash, Loan newLoan);
  event Repaid(bool isComplete, bytes32 repayLoanHash, LoanPartialUpdateInfo updateInfo);
  event Liquidated(bytes32 loanHash);
  event Freeze(bool isfrozen);

  bytes32 public constant ADMIN = keccak256("ADMIN");
  bool public frozen;
  TreasuryLogic public treasury;
  mapping(bytes32 => PoolPolicy.InterestInfo) public loanInterestInfo;

  constructor(address globalBeacon) GlobalBeaconProxyImpl(globalBeacon, Slots.LENDING_POOL_IMPL) {}

  function initialize(Policy calldata initialPolicy, address poolAdmin, TreasuryLogic _treasury) external initializer {
    _transferOwnership(poolAdmin);
    _setPoolwidePolicy(initialPolicy.poolwide);
    _setAllowedCollection(initialPolicy.allowedcollections);
    treasury = _treasury;
    frozen = false;
  }

  function borrowPolicyCheck(Loan memory loan) internal view returns (InterestInfo memory) {
    require(loan.borrower == msg.sender, "Invalid borrower");
    require(loan.collaterals.length > 0, "collaterals should be exist");
    require(loan.collaterals.length == loan.valuations.length, "invalid loan term");
    require(loan.collaterals.length == loan.collateralAmounts.length, "invalid loan term");
    require(loan.beginTime > block.timestamp - 3 minutes, "Request expired");
    require(loan.beginTime < block.timestamp + 3 minutes, "Invalid time");
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

  function borrow(
    Loan memory newLoan,
    bytes32 r,
    bytes32 vs,
    Loan[] memory maybeLastLoan
  ) external payable nonReentrant {
    require(!frozen, "Pool frozen");
    require(treasury.checkBalance(newLoan.principalToken, newLoan.principal), "Insufficient Treasury Balance");
    require(
      keccak256(abi.encode(newLoan)).toEthSignedMessageHash().recover(r, vs) == getOracleAddress(),
      "Invalid signature"
    );
    PoolPolicy.InterestInfo memory interestInfo = borrowPolicyCheck(newLoan);
    require(interestInfo.interestRateBP > 0, "interest-free loan is not allowed");
    bytes32 loanHash = keccak256(abi.encode(newLoan));
    require(loanInterestInfo[loanHash].interestRateBP == 0, "Loan already exists");
    uint256 receiveAmount = newLoan.principal;
    uint256 communityShare = 0;
    uint256 developerFee = 0;
    bytes32 lastHash = bytes32(0);
    require(maybeLastLoan.length <= 1);
    if (maybeLastLoan.length == 1) {
      Loan memory lastLoan = maybeLastLoan[0];
      lastHash = keccak256(abi.encode(lastLoan));
      require(loanInterestInfo[lastHash].interestRateBP != 0, "lastLoan does not exist");
      require(lastLoan.borrower == newLoan.borrower);
      require(lastLoan.principalToken == newLoan.principalToken);
      require(keccak256(abi.encode(lastLoan.collaterals)) == keccak256(abi.encode(newLoan.collaterals)));
      require(keccak256(abi.encode(lastLoan.collateralAmounts)) == keccak256(abi.encode(newLoan.collateralAmounts)));
      (receiveAmount, communityShare, developerFee) = _calculateRenew(newLoan, lastLoan);
    }
    delete loanInterestInfo[lastHash];
    loanInterestInfo[loanHash] = interestInfo;
    if (lastHash == bytes32(0)) {
      GenericTokenInterface.safeBatchTransferFrom(
        msg.sender,
        address(this),
        newLoan.collaterals,
        newLoan.collateralAmounts
      );
      mintBoundNFTs(msg.sender, newLoan.collaterals, newLoan.collateralAmounts);
    }
    if (receiveAmount > 0) {
      treasury.lendOut(newLoan.principalToken, msg.sender, receiveAmount);
    }
    uint256 principalFee = ((lastHash != bytes32(0) ? getRenewFeeBP() : getBorrowFeeBP()) * newLoan.principal) / 10000;
    _takeMoney(newLoan.principalToken, communityShare, developerFee + principalFee, true, msg.value);
    emit Borrowed(interestInfo, lastHash, newLoan);
  }

  function calculateRenew(Loan memory loan, Loan memory lastLoan) external view returns (uint256, uint256) {
    (uint256 receiveAmount, uint256 communityShare, uint256 developerFee) = _calculateRenew(loan, lastLoan);
    return (receiveAmount, communityShare + developerFee);
  }

  function _calculateRenew(Loan memory loan, Loan memory lastLoan) internal view returns (uint256, uint256, uint256) {
    (uint256 communityShare, uint256 developerFee) = _calculateDebt(
      loanInterestInfo[keccak256(abi.encode(lastLoan))],
      lastLoan.beginTime,
      lastLoan.duration,
      lastLoan.principal
    );
    if (communityShare < loan.principal) {
      return (loan.principal - communityShare, 0, developerFee);
    } else {
      return (0, communityShare - loan.principal, developerFee);
    }
  }

  function _calculateRepaidLoan_inplace(
    Loan memory loan,
    uint256[] memory repayAmounts
  ) internal pure returns (bool completeRepay, uint256 partialPrincipal) {
    completeRepay = true;
    uint256 totalValuations;
    uint256 repayValuations;
    for (uint256 i = 0; i < loan.collaterals.length; i++) {
      completeRepay = completeRepay && loan.collateralAmounts[i] == repayAmounts[i];
      repayValuations += loan.valuations[i] * repayAmounts[i];
      totalValuations += loan.valuations[i] * loan.collateralAmounts[i];
      loan.collateralAmounts[i] -= repayAmounts[i];
    }
    partialPrincipal = (loan.principal * repayValuations) / totalValuations;
    loan.principal -= partialPrincipal;
  }

  function _calculateDebt(
    PoolPolicy.InterestInfo memory interestInfo,
    uint256 beginTime,
    uint256 duration,
    uint256 principal
  ) internal view returns (uint256 treasuryShare, uint256 developerFee) {
    uint256 timeElapsed = beginTime < block.timestamp ? block.timestamp - beginTime : 0;
    uint256 penalty = timeElapsed < duration
      ? ((interestInfo.interestRateBP * interestInfo.earlyReturnMultiplierBP) / 10000) * (duration - timeElapsed)
      : ((interestInfo.interestRateBP * interestInfo.lateReturnMultiplierBP) / 10000) * (timeElapsed - duration);
    uint256 totalInterest = (principal * (interestInfo.interestRateBP * timeElapsed + penalty)) / (10000 * 365 days);
    developerFee = (totalInterest * getInterestFeeBP()) / 10000;
    treasuryShare = principal + totalInterest - developerFee;
  }

  function repay(Loan[] memory loans, uint256[][] memory repayAmountsArray) external payable nonReentrant {
    uint256 remainMsgValue = msg.value;
    for (uint256 i = 0; i < loans.length; i++) {
      uint256 usedMsgValue = _repayPartial(loans[i], repayAmountsArray[i], i == (loans.length - 1), remainMsgValue);
      remainMsgValue -= usedMsgValue;
    }
  }

  function _repayPartial(
    Loan memory loan,
    uint256[] memory repayAmounts,
    bool isLast,
    uint256 remainMsgValue
  ) internal returns (uint256) {
    require(msg.sender == loan.borrower, "You cannot repay other's loan");
    bytes32 repayLoanHash = keccak256(abi.encode(loan));
    PoolPolicy.InterestInfo memory interestInfo = loanInterestInfo[repayLoanHash];
    require(interestInfo.interestRateBP > 0, "Loan does not exist");
    require(loan.beginTime + loan.duration + interestInfo.maxOverdue > block.timestamp, "to late repayment");
    (bool completeRepay, uint256 partialPrincipal) = _calculateRepaidLoan_inplace(loan, repayAmounts);
    (uint256 treasuryShare, uint256 developerFee) = _calculateDebt(
      interestInfo,
      loan.beginTime,
      loan.duration,
      partialPrincipal
    );
    require(treasuryShare + developerFee > 0, "No principal to repay");
    delete loanInterestInfo[repayLoanHash];
    burnBoundNFTs(msg.sender, loan.collaterals, repayAmounts);
    GenericTokenInterface.safeBatchTransferFrom(address(this), msg.sender, loan.collaterals, repayAmounts);
    if (completeRepay) {
      emit Repaid(true, repayLoanHash, LoanPartialUpdateInfo(repayLoanHash, loan.principal, loan.collateralAmounts));
    } else {
      loanInterestInfo[keccak256(abi.encode(loan))] = interestInfo;
      emit Repaid(
        false,
        repayLoanHash,
        LoanPartialUpdateInfo(keccak256(abi.encode(loan)), loan.principal, loan.collateralAmounts)
      );
    }
    return _takeMoney(loan.principalToken, treasuryShare, developerFee, isLast, remainMsgValue);
  }

  function liquidate(Loan[] memory loans, address transferTo) external nonReentrant onlyOwner {
    for (uint256 i = 0; i < loans.length; i++) {
      _liquidate(loans[i], transferTo);
    }
  }

  function _liquidate(Loan memory loan, address transferTo) internal {
    bytes32 loanHash = keccak256(abi.encode(loan));
    require(loanInterestInfo[loanHash].interestRateBP > 0, "Loan does not exist");
    require(
      loan.beginTime + loan.duration + loanInterestInfo[loanHash].maxOverdue < block.timestamp,
      "Can't liquidate yet"
    );

    delete loanInterestInfo[loanHash];
    emit Liquidated(loanHash);

    burnBoundNFTs(loan.borrower, loan.collaterals, loan.collateralAmounts);
    GenericTokenInterface.safeBatchTransferFrom(address(this), transferTo, loan.collaterals, loan.collateralAmounts);
  }

  function _takeMoney(
    address token,
    uint256 treasuryShare,
    uint256 developerFee,
    bool isLast,
    uint256 remainMsgValue
  ) internal returns (uint256) {
    if (token == address(0)) {
      require(remainMsgValue >= treasuryShare + developerFee, "insufficient ether");
      _safeTransferEther(address(treasury), treasuryShare);
      _safeTransferEther(getBancofAddress(), developerFee);
      if (isLast) {
        _safeTransferEther(msg.sender, remainMsgValue - (treasuryShare + developerFee));
      }
      return treasuryShare + developerFee;
    } else {
      if (treasuryShare > 0) IERC20(token).safeTransferFrom(msg.sender, address(treasury), treasuryShare);
      if (developerFee > 0) IERC20(token).safeTransferFrom(msg.sender, getBancofAddress(), developerFee);
      if (isLast) {
        _safeTransferEther(msg.sender, remainMsgValue);
      }
      return 0;
    }
  }

  function _safeTransferEther(address to, uint256 amount) internal {
    if (amount > 0) {
      (bool s, ) = to.call{ value: amount }("");
      require(s);
    }
  }

  function freeze(bool b) external {
    require(msg.sender == getBancofAddress() || msg.sender == owner(), "should be bancof or poolOwner");
    frozen = b;
    emit Freeze(b);
  }
}

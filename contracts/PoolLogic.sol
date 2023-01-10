// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./globalbeacon/GlobalBeaconProxyImpl.sol";
import "./lib/Slots.sol";
import "./lib/GenericTokenInterface.sol";
import "./TreasuryLogic.sol";
import "./PolicyLogic.sol";
import "./boundnft/BoundNFTManager.sol";

contract PoolLogic is
  ReentrancyGuardUpgradeable,
  GlobalBeaconProxyImpl,
  OwnableUpgradeable,
  BoundNFTManager,
  ERC1155Holder,
  ERC721Holder
{
  using SafeERC20 for IERC20;
  using ECDSA for bytes32;
  using GenericTokenInterface for GenericTokenInterface.Item;
  using GenericTokenInterface for GenericTokenInterface.Collection;

  struct Collateral {
    GenericTokenInterface.Item item;
    uint256 amount;
    uint256 valueation;
  }

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

  event Borrowed(PolicyLogic.InterestInfo interestInfo, bytes32 lastLoanHash, Loan newLoan);
  event Repaid(bool isComplete, bytes32 repayLoanHash, LoanPartialUpdateInfo updateInfo);
  event Liquidated(bytes32 loanHash);

  bytes32 public constant ADMIN = keccak256("ADMIN");
  bool public frozen;

  TreasuryLogic public treasury;
  PolicyLogic public policy;

  mapping(bytes32 => PolicyLogic.InterestInfo) public loanInterestInfo;

  constructor(address globalBeacon) GlobalBeaconProxyImpl(globalBeacon, Slots.LENDING_POOL_IMPL) {}

  function initialize(TreasuryLogic _treasury, PolicyLogic _policy, address admin) external payable initializer {
    frozen = false;
    treasury = _treasury;
    policy = _policy;

    _transferOwnership(admin);
    _takeMoney(getInitialFeeToken(), 0, getInitialFee(), true, msg.value);
  }

  function borrow(
    Loan memory newLoan,
    bytes32 r,
    bytes32 vs,
    Loan[] memory maybeLastLoan
  ) external payable nonReentrant returns (uint256) {
    require(!frozen, "Pool frozen");
    require(
      keccak256(abi.encode(newLoan)).toEthSignedMessageHash().recover(r, vs) == getOracleAddress(),
      "Invalid signature"
    );

    require(treasury.checkBalance(newLoan.principalToken, newLoan.principal), "Insufficient Treasury Balance");

    require(newLoan.borrower == msg.sender, "Invalid borrower");

    require(newLoan.collaterals.length > 0);
    require(newLoan.collaterals.length == newLoan.valuations.length);
    require(newLoan.collaterals.length == newLoan.collateralAmounts.length);

    require(newLoan.beginTime > block.timestamp - 3 minutes, "Request expired");
    require(newLoan.beginTime < block.timestamp + 3 minutes, "Invalid time");

    PolicyLogic.InterestInfo memory interestInfo = policy.approveLoanAndGetInterestRateBP(newLoan);
    assert(interestInfo.interestRateBP > 0);

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
    return interestInfo.interestRateBP;
  }

  function calculateRenew(
    Loan memory loan,
    Loan memory lastLoan
  ) external view returns (uint256, uint256 /* (amount that will be received by the user, amount to approve/send) */) {
    (uint256 receiveAmount, uint256 communityShare, uint256 developerFee) = _calculateRenew(loan, lastLoan);
    return (receiveAmount, communityShare + developerFee);
  }

  function _calculateRenew(
    Loan memory loan,
    Loan memory lastLoan
  ) internal view returns (uint256, uint256, uint256 /* receiveAmount, communityShare, developerFee */) {
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

  function repay(Loan[] memory loans, uint256[][] memory repayAmountsArray) external payable {
    uint256 remainMsgValue = msg.value;
    for (uint256 i = 0; i < loans.length; i++) {
      uint256 usedMsgValue = _repayPartial(loans[i], repayAmountsArray[i], i == (loans.length - 1), remainMsgValue);
      remainMsgValue -= usedMsgValue;
    }
  }

  function liquidate(Loan memory loan) external nonReentrant {
    require(msg.sender == address(treasury) || msg.sender == owner(), "should be treasury or poolOwner");

    bytes32 loanHash = keccak256(abi.encode(loan));

    require(loanInterestInfo[loanHash].interestRateBP > 0, "Loan does not exist");
    require(
      loan.beginTime + loan.duration + loanInterestInfo[loanHash].maxOverdue < block.timestamp,
      "Can't liquidate yet"
    );

    delete loanInterestInfo[loanHash];
    emit Liquidated(loanHash);

    burnBoundNFTs(loan.borrower, loan.collaterals, loan.collateralAmounts);
    GenericTokenInterface.safeBatchTransferFrom(
      address(this),
      address(treasury),
      loan.collaterals,
      loan.collateralAmounts
    );
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
    PolicyLogic.InterestInfo memory interestInfo,
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

  function _repayPartial(
    Loan memory loan,
    uint256[] memory repayAmounts,
    bool isLast,
    uint256 remainMsgValue
  ) internal returns (uint256) {
    bytes32 repayLoanHash = keccak256(abi.encode(loan));
    PolicyLogic.InterestInfo memory interestInfo = loanInterestInfo[repayLoanHash];
    require(interestInfo.interestRateBP > 0, "Loan does not exist");
    require(msg.sender == loan.borrower, "You cannot repay other's debt");
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

    _takeMoney(loan.principalToken, treasuryShare, developerFee, isLast, remainMsgValue);
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
    return (treasuryShare + developerFee);
  }

  function _takeMoney(
    address token,
    uint256 treasuryShare,
    uint256 developerFee,
    bool isLast,
    uint256 remainMsgValue
  ) internal {
    if (token == address(0)) {
      require(remainMsgValue >= treasuryShare + developerFee, "insufficient ether");
      _safeTransferEther(address(treasury), treasuryShare);
      _safeTransferEther(getBancofAddress(), developerFee);

      if (isLast) {
        _safeTransferEther(msg.sender, remainMsgValue - (treasuryShare + developerFee));
      }
    } else {
      if (treasuryShare > 0) IERC20(token).safeTransferFrom(msg.sender, address(treasury), treasuryShare);
      if (developerFee > 0) IERC20(token).safeTransferFrom(msg.sender, getBancofAddress(), developerFee);
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
  }
}

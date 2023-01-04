// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./globalbeacon/GlobalBeaconProxyImpl.sol";
import "./lib/Slots.sol";
import "./PoolLogic.sol";

contract TreasuryLogic is
  ReentrancyGuardUpgradeable,
  GlobalBeaconProxyImpl,
  AccessControlUpgradeable,
  ERC721Holder,
  ERC1155Holder
{
  using SafeERC20 for IERC20;

  bytes32 public constant MONEY_MANAGER = keccak256("MONEY_MANAGER");
  bytes32 public constant NFT_MANAGER = keccak256("NFT_MANAGER");
  bytes32 public constant POOL = keccak256("POOL");

  constructor(address globalBeacon) GlobalBeaconProxyImpl(globalBeacon, Slots.TREASURY_IMPL) {}

  function initialize(PoolLogic pool, address moneyManager, address nftManager) external initializer {
    _grantRole(POOL, address(pool));
    _grantRole(MONEY_MANAGER, moneyManager);
    _grantRole(NFT_MANAGER, nftManager);
  }

  function supportsInterface(
    bytes4 interfaceId
  ) public view override(ERC1155Receiver, AccessControlUpgradeable) returns (bool) {
    return ERC1155Receiver.supportsInterface(interfaceId) || AccessControlUpgradeable.supportsInterface(interfaceId);
  }

  function _safeTransferEther(address to, uint256 amount) internal {
    (bool s, ) = to.call{ value: amount }("");
    require(s);
  }

  receive() external payable {}

  function withdrawETH(address payable to, uint256 amount) external onlyRole(MONEY_MANAGER) nonReentrant {
    _safeTransferEther(to, amount);
  }

  function withdrawERC20(address to, IERC20 token, uint256 amount) external onlyRole(MONEY_MANAGER) nonReentrant {
    token.safeTransfer(to, amount);
  }

  function withdrawERC721(address to, IERC721 token, uint256 id) external onlyRole(NFT_MANAGER) nonReentrant {
    token.safeTransferFrom(address(this), to, id);
  }

  function withdrawERC1155(
    address to,
    IERC1155 token,
    uint256 id,
    uint256 amount
  ) external onlyRole(NFT_MANAGER) nonReentrant {
    token.safeTransferFrom(address(this), to, id, amount, "");
  }

  function checkBalance(address token, uint256 amount) external view onlyRole(POOL) returns (bool) {
    if (token == address(0)) {
      return address(this).balance >= amount;
    } else {
      return IERC20(token).balanceOf(address(this)) >= amount;
    }
  }

  function lendOut(address token, address to, uint256 amount) external onlyRole(POOL) nonReentrant {
    if (token == address(0)) {
      _safeTransferEther(to, amount);
    } else {
      IERC20(token).safeTransfer(to, amount);
    }
  }
}
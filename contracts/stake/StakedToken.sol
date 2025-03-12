// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ERC20, SafeMath} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import {IStakedTrala} from '../interfaces/IStakedTrala.sol';

/**
 * @title StakedToken
 * @notice Contract to stake Trala token, tokenize the position and get reward, inheriting from a distribution manager contract
 **/
contract StakedToken is IStakedTrala, ERC20, Ownable {
  using SafeMath for *;
  using SafeERC20 for IERC20;

  struct CooldownState {
      uint256 amount;
      uint256 cooldownStartTimestamp;
  }

  uint256 internal constant ONE = 1e18; // 18 decimal places
  
  uint256 public constant FIXED_APR = 0.1e18; // 10%

  uint256 public constant COOLDOWN_SECONDS = 7 days;
  
  uint256 public constant UNSTAKE_WINDOW = 7 days;

  uint256 public constant DURATION = 90 days;

  IERC20 public immutable TOKEN;

  /// @notice Address to pull from the reward, needs to have approved this contract
  address public immutable REWARD_VAULT;

  mapping(address => mapping(uint256 => CooldownState)) public cooldownStates;
  mapping(address => uint256) public cooldownAmounts;
  mapping(address => uint256) public cooldownStartIndices;
  mapping(address => uint256) public cooldownIndexCounts;

  mapping(address => uint256) public rewardToClaim;
  mapping(address => uint256) public lastUpdateRewardTimestamps;

  uint256 public maxTotalSupply;
  uint256 public startTimestamp;
  uint256 public endTimestamp;

  event Staked(address indexed from, address indexed user, uint256 amount);
  event Redeem(address indexed from, address indexed to, uint256 amount, uint256 id);

  event RewardAccrued(address user, uint256 amount);
  event RewardClaimed(address indexed from, address indexed to, uint256 amount);

  event CooldownRequested(address indexed user, uint256 id);

  constructor(
    IERC20 token,
    address rewardVault,
    address manager,
    string memory name,
    string memory symbol
  ) public ERC20(name, symbol) Ownable() {
    TOKEN = token;
    REWARD_VAULT = rewardVault;
    transferOwnership(manager);
  }

  function configureCampaign(uint256 rewardAmount) external onlyOwner {
    if (TOKEN.balanceOf(REWARD_VAULT) < rewardAmount) revert('INSUFFICIENT_REWARD_AMOUNT');
    maxTotalSupply = rewardAmount.mul(ONE).mul(365 days).div(FIXED_APR.mul(DURATION));
    startTimestamp = block.timestamp;
  }

  function stake(address user, uint256 amount) external override {
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    if (totalSupply().add(amount) > maxTotalSupply) revert('MAX_TOTAL_SUPPLY_EXCEEDED');

    IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), amount);

    uint256 accruedReward = _getAccruedReward(balanceOf(user), lastUpdateRewardTimestamps[user]);
    if (accruedReward != 0) {
      emit RewardAccrued(user, accruedReward);
      rewardToClaim[user] = rewardToClaim[user].add(accruedReward);
    }

    _mint(user, amount);

    emit Staked(msg.sender, user, amount);
  }

  /**
   * @dev Redeems staked tokens, and stop earning reward
   **/
  function redeem(uint256 id, address to, uint256 amount) external override {
    require(amount != 0, 'INVALID_ZERO_AMOUNT');

    uint256 cooldownStartTimestamp = cooldownStates[msg.sender][id].cooldownStartTimestamp;
    require(block.timestamp > cooldownStartTimestamp.add(COOLDOWN_SECONDS), 'INSUFFICIENT_COOLDOWN');

    if (block.timestamp.sub(cooldownStartTimestamp.add(COOLDOWN_SECONDS)) > UNSTAKE_WINDOW) {
      cooldownStates[msg.sender][id].amount = 0;
      cooldownStates[msg.sender][id].cooldownStartTimestamp = 0;
      cooldownStartIndices[msg.sender] = id + 1;
      return;
    }

    uint256 balancerOfUser = balanceOf(msg.sender);    

    _updateCurrentUnclaimedReward(msg.sender, balancerOfUser, lastUpdateRewardTimestamps[msg.sender], true);

    cooldownAmounts[msg.sender] = cooldownAmounts[msg.sender].sub(amount, 'INVALID_AMOUNT');

    _burn(msg.sender, amount);

    if (balancerOfUser.sub(amount) == 0) {
      cooldownStates[msg.sender][id].amount = 0;
      cooldownStates[msg.sender][id].cooldownStartTimestamp = 0;
      if (id == cooldownStartIndices[msg.sender]) cooldownStartIndices[msg.sender]++;
      if (id == cooldownIndexCounts[msg.sender]) cooldownIndexCounts[msg.sender]--;
    }

    IERC20(TOKEN).safeTransfer(to, amount);

    emit Redeem(msg.sender, to, amount, id);
  }

  /**
   * @dev Activates the cooldown period to unstake
   * - It can't be called if the user is not staking
   **/
  function cooldown(uint256 amount) external override returns (uint256 id) {
    uint256 balanceOfUser = balanceOf(msg.sender);
    require(balanceOfUser != 0, 'INVALID_BALANCE_ON_COOLDOWN');

    amount = (amount > balanceOfUser - cooldownAmounts[msg.sender]) ? balanceOfUser - cooldownAmounts[msg.sender] : amount;

    id = cooldownIndexCounts[msg.sender];
    cooldownIndexCounts[msg.sender]++;
    
    cooldownStates[msg.sender][id].amount = amount;
    cooldownStates[msg.sender][id].cooldownStartTimestamp = block.timestamp;

    cooldownAmounts[msg.sender] = cooldownAmounts[msg.sender].add(amount);

    emit CooldownRequested(msg.sender, id);
  }

  /**
   * @dev Claims an `amount` of `TOKEN` to the address `to`
   * @param to Address to stake for
   * @param amount Amount to stake
   **/
  function claimReward(address to, uint256 amount) external override {
    uint256 newTotalReward =
      _updateCurrentUnclaimedReward(msg.sender, balanceOf(msg.sender), lastUpdateRewardTimestamps[msg.sender], false);
    uint256 amountToClaim = (amount == type(uint256).max) ? newTotalReward : amount;

    rewardToClaim[msg.sender] = newTotalReward.sub(amountToClaim, 'INVALID_AMOUNT');

    TOKEN.safeTransferFrom(REWARD_VAULT, to, amountToClaim);

    emit RewardClaimed(msg.sender, to, amountToClaim);
  }

  /**
   * @dev Update the user state related with accrued reward
   **/
  function _updateCurrentUnclaimedReward(
    address user, 
    uint256 balanceOfUser,
    uint256 lastUpdateRewardTimestamp,
    bool updateStorage
  ) internal returns (uint256) {
    uint256 accruedReward = _getAccruedReward(balanceOfUser, lastUpdateRewardTimestamp);
    
    uint256 unclaimedReward = rewardToClaim[user].add(accruedReward);

    if (accruedReward != 0) {
      if (updateStorage) rewardToClaim[user] = unclaimedReward;
      emit RewardAccrued(user, accruedReward);
    }

    return unclaimedReward;
  }


  /**
   * @dev Updates the state of user's accrued reward
   **/
  function _getAccruedReward(
    uint256 balanceOfUser,
    uint256 lastUpdateRewardTimestamp
  ) internal view returns (uint256) {
    uint256 blockTimestamp = block.timestamp > endTimestamp ? endTimestamp : block.timestamp;
    if (startTimestamp > lastUpdateRewardTimestamp) lastUpdateRewardTimestamp = startTimestamp;      
    return balanceOfUser.mul(FIXED_APR).mul(blockTimestamp.sub(lastUpdateRewardTimestamp))
      .div(ONE.mul(365 days));
  }

  /**
   * @dev Return the total reward pending to claim by a user
   */
  function getTotalRewardBalance(address user) external view returns (uint256) {
    return rewardToClaim[user].add(_getAccruedReward(balanceOf(user), lastUpdateRewardTimestamps[user]));
  }

  /**
    * @dev Query withdrawal IDs that match active states.
    */
  function getCooldownStateIds(address user) external view returns (uint256[] memory ids) {
    ids = new uint256[](cooldownIndexCounts[user] - cooldownStartIndices[user]);
    uint256 cnt;

    for (uint256 i = cooldownStartIndices[user]; i < cooldownIndexCounts[user]; i++) {
      if (
        cooldownStates[user][i].amount != 0 
          && block.timestamp <= cooldownStates[user][i].cooldownStartTimestamp.add(COOLDOWN_SECONDS).add(UNSTAKE_WINDOW)
      ) {
        ids[cnt++] = i;
      }
    }
  }
  
  function getCooldownStateById(address user, uint256 id) external view returns (CooldownState memory) {
    return cooldownStates[user][id];
  }
}

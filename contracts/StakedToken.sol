// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.8.20;
pragma experimental ABIEncoderV2;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IStakedTrala} from './interfaces/IStakedTrala.sol';

/**
 * @title StakedToken
 * @notice Contract to stake Trala token, tokenize the position and get reward
 **/
contract StakedToken is IStakedTrala, ERC20, Ownable {
  using SafeERC20 for IERC20;

  struct RequestRedeemState {
      address recipient;
      uint256 amount;
      uint256 cooldownStartTimestamp;
  }

  uint256 internal constant ONE = 1e18; // 100%
  
  uint256 public constant FIXED_APR = 0.1e18; // 10%

  uint256 public constant COOLDOWN_SECONDS = 1 minutes;
  
  uint256 public constant UNSTAKE_WINDOW = 10 minutes;

  uint256 public constant DURATION = 90 days;

  IERC20 public immutable TOKEN;

  /// @notice Address to pull from the reward, needs to have approved this contract
  address public rewardVault;

  mapping(address => mapping(uint256 => RequestRedeemState)) public requestRedeemStatesById;
  mapping(address => uint256) public requestRedeemStartIndices;
  mapping(address => uint256) public requestRedeemIndexCounts;

  mapping(address => uint256) public rewardToClaim;
  mapping(address => uint256) public lastUpdateTimestamps;
  mapping(address => uint256) public lastIndex;

  uint256 public campaignMaxTotalSupply;
  uint256 public campaignEndTimestamp;

  uint256 public aggregateRewardToClaim;
  uint256 public aggregateIndex;
  uint256 public lastUpdateAggregateTimestamp;

  bool public paused;

  event CampaignConfigured(uint256 maxRewardAmount, uint256 maxStakeAmount);

  event Staked(address indexed from, address indexed user, uint256 amount);
  event Redeem(address indexed from, address indexed to, uint256 amount, uint256 id);

  event RewardAccrued(address user, uint256 amount);
  event RewardClaimed(address indexed from, address indexed to, uint256 amount);

  event RedeemRequested(address indexed user, uint256 id);

  event IndexUpdated(uint256 aggregateIndex);

  constructor(
    IERC20 token,
    address _rewardVault,
    address manager,
    string memory name,
    string memory symbol
  ) ERC20(name, symbol) Ownable(manager) {
    TOKEN = token;
    rewardVault = _rewardVault;
  }

  function configureCampaign(uint256 _aggregateReward) external onlyOwner {
    if (paused) revert('CONFIGURE_INVALID_WHEN_PAUSED');
    uint256 aggregateRewardToDistribute = TOKEN.balanceOf(rewardVault) - aggregateRewardToClaim;
    if (aggregateRewardToDistribute < _aggregateReward) revert('INSUFFICIENT_REWARD_AMOUNT');
    campaignEndTimestamp = block.timestamp + DURATION;
    campaignMaxTotalSupply = aggregateRewardToDistribute * ONE * 365 days / (FIXED_APR * DURATION);
    emit CampaignConfigured(_aggregateReward, campaignMaxTotalSupply);
  }

  function stake(address user, uint256 amount) external override {
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    if (totalSupply() + amount > campaignMaxTotalSupply) revert('MAX_TOTAL_SUPPLY_EXCEEDED');
    IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), amount);
    uint256 currentTimestamp = block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp;
    _updateUnclaimedReward(user, balanceOf(user), currentTimestamp - lastUpdateTimestamps[user], true);
    _updateAggregateUnclaimedReward(totalSupply(), currentTimestamp - lastUpdateAggregateTimestamp);
    _mint(user, amount);

    emit Staked(msg.sender, user, amount);
  }

  /**
   * @dev Redeems staked tokens, and stop earning reward
   **/
  function redeem(uint256 id) external override {
    RequestRedeemState storage state = requestRedeemStatesById[msg.sender][id];
    uint256 amount = state.amount;
    
    if (amount == 0) revert('REDEEMABLE_ZERO_AMOUNT');
    if (block.timestamp < state.cooldownStartTimestamp + COOLDOWN_SECONDS) revert('COOLDOWN_NOT_FINISHED');
    
    state.amount = 0;
    if (id == requestRedeemStartIndices[msg.sender]) requestRedeemStartIndices[msg.sender]++;
    if (id == requestRedeemIndexCounts[msg.sender]) requestRedeemIndexCounts[msg.sender]--;
  
    uint256 currentTimestamp = block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp;
    _updateUnclaimedReward(msg.sender, balanceOf(msg.sender), currentTimestamp - lastUpdateTimestamps[msg.sender], true);
    _updateAggregateUnclaimedReward(totalSupply(), currentTimestamp - lastUpdateAggregateTimestamp);
    
    IERC20(TOKEN).safeTransfer(state.recipient, amount);

    emit Redeem(msg.sender, state.recipient, amount, id);
  }

  /**
   * @dev Activates the cooldown period to unstake
   * - It can't be called if the user is not staking
   **/
  function requestRedeem(address to, uint256 amount) external override returns (uint256 id) {
    uint256 balanceOfUser = balanceOf(msg.sender);
    require(balanceOfUser != 0, 'INVALID_BALANCE_ON_COOLDOWN');
    amount = (amount > balanceOfUser) ? balanceOfUser : amount;
    id = requestRedeemIndexCounts[msg.sender];
    requestRedeemIndexCounts[msg.sender]++;
    requestRedeemStatesById[msg.sender][id].recipient = to;
    requestRedeemStatesById[msg.sender][id].amount = amount;
    requestRedeemStatesById[msg.sender][id].cooldownStartTimestamp = block.timestamp;

    _burn(msg.sender, amount);

    emit RedeemRequested(msg.sender, id);
  }

  /**
   * @dev Claims an `amount` of `TOKEN` to the address `to`
   **/
  function claimReward(address to, uint256 amount) external override {
    uint256 currentTimestamp = block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp;
    uint256 newTotalReward = _updateUnclaimedReward(
      msg.sender, balanceOf(msg.sender), currentTimestamp - lastUpdateTimestamps[msg.sender], false
    );
    uint256 amountToClaim = amount > newTotalReward ? newTotalReward : amount;
    rewardToClaim[msg.sender] = newTotalReward - amountToClaim;
    aggregateRewardToClaim -= amountToClaim;
    TOKEN.safeTransferFrom(rewardVault, to, amountToClaim);

    emit RewardClaimed(msg.sender, to, amountToClaim);
  }

  /**
   * @dev Update the user state related with accrued reward
   **/
  function _updateUnclaimedReward(
    address user, 
    uint256 balanceOfUser,
    uint256 timeDelta,
    bool updateStorage
  ) internal returns (uint256) {
    uint256 unclaimedReward;

    if (timeDelta != 0) {
      uint256 accruedReward = _getAccruedReward(balanceOfUser, aggregateIndex - lastIndex[user]);

      unclaimedReward = rewardToClaim[user] + accruedReward;

      if (accruedReward != 0) {
        if (updateStorage) rewardToClaim[user] = unclaimedReward;
        emit RewardAccrued(user, accruedReward);
      }

      lastIndex[user] = aggregateIndex;
      lastUpdateTimestamps[user] = block.timestamp;
    }

    return unclaimedReward;
  }



  /**
   * @dev Update the aggregate state related with accrued reward
   **/
  function _updateAggregateUnclaimedReward(
    uint256 aggregateBalance,
    uint256 timeDelta
  ) internal returns (uint256) {
    uint256 unclaimedAggregateReward;

    if (timeDelta != 0) {
      uint256 accruedAggregateReward = aggregateBalance * timeDelta * FIXED_APR / (ONE * 365 days);
      
      unclaimedAggregateReward += aggregateRewardToClaim;

      if (accruedAggregateReward != 0) {
        aggregateRewardToClaim = unclaimedAggregateReward;  
        aggregateIndex += unclaimedAggregateReward * ONE / totalSupply();
        lastUpdateAggregateTimestamp = block.timestamp;  
        emit IndexUpdated(aggregateIndex);
      }
    }
    
    return unclaimedAggregateReward;
  }

  /**
   * @dev Updates the state of user's accrued reward
   **/
  function _getAccruedReward(uint256 balance, uint256 indexDelta) internal pure returns (uint256) {
    return balance * indexDelta / ONE;
  }

  /**
   * @dev Return the total reward pending to claim by a user
   */
  function getTotalRewardBalance(address user) external view returns (uint256) {
    return rewardToClaim[user] + _getAccruedReward(balanceOf(user), aggregateIndex - lastIndex[user]);
  }

  /**
    * @dev Query withdrawal IDs that match active states.
    */
  function getRequestRedeemStateIds(address user) external view returns (uint256[] memory ids) {
    ids = new uint256[](requestRedeemIndexCounts[user] - requestRedeemStartIndices[user]);
    uint256 cnt;

    for (uint256 i = requestRedeemStartIndices[user]; i < requestRedeemIndexCounts[user]; i++) {
      if (
        requestRedeemStatesById[user][i].amount != 0 
          && block.timestamp <= requestRedeemStatesById[user][i].cooldownStartTimestamp + COOLDOWN_SECONDS + UNSTAKE_WINDOW
      ) {
        ids[cnt++] = i;
      }
    }
  }
  
  function getRequestRedeemStateById(address user, uint256 id) external view returns (RequestRedeemState memory) {
    return requestRedeemStatesById[user][id];
  }

  function pause() external onlyOwner {
    paused = true;
  }

  function setRewardVault(address _rewardVault) external onlyOwner {
    delete aggregateRewardToClaim;
    rewardVault = _rewardVault;
  }
}

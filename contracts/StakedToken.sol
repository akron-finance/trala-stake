// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.8.20;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IStakedToken} from './interfaces/IStakedToken.sol';

/**
 * @title StakedToken
 * @notice Contract to stake Trala token, tokenize the position and get reward
 **/
contract StakedToken is IStakedToken, ERC20, Ownable {
  using SafeERC20 for IERC20;

  uint256 internal constant ONE = 1e18; // 100%
  
  uint256 public constant override FIXED_APR = 0.1e18; // 10%

  uint256 public constant override COOLDOWN_SECONDS = 1 minutes;

  IERC20 public immutable override TOKEN;

  /// @notice Address to pull from the reward, needs to have approved this contract
  address public rewardVault;

  mapping(address => mapping(uint256 => RequestRedeemState)) public requestRedeemStatesById;
  mapping(address => uint256) public requestRedeemStartIndices;
  mapping(address => uint256) public requestRedeemIndexCounts;

  mapping(address => uint256) public rewardToClaim;
  mapping(address => uint256) public lastUpdateTimestamps;
  mapping(address => uint256) public lastIndex;

  uint256 public override campaignMaxTotalSupply;
  uint256 public override campaignEndTimestamp;

  uint256 public aggregateRewardToClaim;
  uint256 public aggregateIndex;
  uint256 public lastUpdateAggregateTimestamp;

  event CampaignStarted(uint256 maxRewardAmount, uint256 maxStakeAmount);

  event Staked(address indexed from, address indexed user, uint256 amount);
  event Redeem(address indexed from, address indexed to, uint256 amount, uint256 id);

  event RewardAccrued(address user, uint256 amount);
  event RewardClaimed(address indexed from, address indexed to, uint256 amount);

  event RedeemRequested(address indexed user, uint256 id);

  event IndexUpdated(uint256 aggregateIndex);

  event CampaignEnded();

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

  function startCampaign(uint256 _aggregateReward, uint256 _campaignDuration) external onlyOwner {
    if (_aggregateReward > TOKEN.allowance(rewardVault, address(this)) - aggregateRewardToClaim) revert('INSUFFICIENT_REWARD_AMOUNT');
    uint256 _campaignEndTimestamp = block.timestamp + _campaignDuration;
    if (_campaignEndTimestamp < campaignEndTimestamp) revert('ENDTIMESTAMP_LESS_THAN_EXISTING_ENDTIMESTAMP');
    campaignEndTimestamp = _campaignEndTimestamp;
    campaignMaxTotalSupply = _aggregateReward * ONE * 365 days / (FIXED_APR * _campaignDuration);
    if (totalSupply() > campaignMaxTotalSupply) revert('INSUFFICIENT_CAMPAIGN_MAX_SUPPLY');
    emit CampaignStarted(_aggregateReward, campaignMaxTotalSupply);
  }

  /**
   * @dev Stakes token, and starts earning reward
   **/
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
   * @dev Redeems staked token
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
   * @dev Activates the cooldown period to unstake, and stop earning reward.
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
    if (timeDelta != 0) {
      uint256 accruedReward = _getAccruedReward(balanceOfUser, aggregateIndex - lastIndex[user]);
      if (accruedReward != 0) {
        if (updateStorage) rewardToClaim[user] += accruedReward;
        emit RewardAccrued(user, accruedReward);
      }
      lastIndex[user] = aggregateIndex;
      lastUpdateTimestamps[user] = block.timestamp;
    }

    return rewardToClaim[user];
  }



  /**
   * @dev Update the aggregate state related with accrued reward
   **/
  function _updateAggregateUnclaimedReward(
    uint256 aggregateBalance,
    uint256 timeDelta
  ) internal returns (uint256) {
    if (timeDelta != 0) {
      uint256 accruedAggregateReward = aggregateBalance * timeDelta * FIXED_APR / (ONE * 365 days);
      if (accruedAggregateReward != 0) {
        aggregateRewardToClaim += accruedAggregateReward;  
        aggregateIndex += aggregateRewardToClaim * ONE / totalSupply();
        lastUpdateAggregateTimestamp = block.timestamp;  
        emit IndexUpdated(aggregateIndex);
      }
    }
    
    return aggregateRewardToClaim;
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
  function getTotalRewardBalance(address user) external view override returns (uint256) {
    return rewardToClaim[user] + _getAccruedReward(balanceOf(user), aggregateIndex - lastIndex[user]);
  }

  /**
    * @dev Query withdrawal IDs that match active states.
    */
  function getRequestRedeemIdsAndStates(address user) 
    external 
    view 
    override 
    returns (uint256[] memory ids, RequestRedeemState[] memory requestRedeemStates) 
  {
    
    uint256 cnt;

    for (uint256 i = requestRedeemStartIndices[user]; i < requestRedeemIndexCounts[user]; i++) {
      if (requestRedeemStatesById[user][i].amount != 0) {
        requestRedeemStates[cnt] = requestRedeemStatesById[user][cnt];
        ids[cnt++];
      }
    }
  }
  
  function endCampaign() external onlyOwner {
    campaignEndTimestamp = block.timestamp;
    emit CampaignEnded();
  }

  function setRewardVault(address _rewardVault) external onlyOwner {
    delete aggregateRewardToClaim;
    rewardVault = _rewardVault;
  }
}

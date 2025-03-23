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
  address public REWARD_VAULT;

  mapping(address => mapping(uint256 => RequestRedeemState)) public requestRedeemStatesById;
  mapping(address => uint256) public requestRedeemStartIndices;
  mapping(address => uint256) public requestRedeemIndexCounts;

  mapping(address => uint256) public rewardToClaim;

  uint256 public override campaignMaxTotalSupply;
  uint256 public override campaignEndTimestamp;
  uint256 public override index;

  mapping(address => uint256) private _lastUpdateTimestampOfUser;
  mapping(address => uint256) private _lastIndexOfUser;
  uint256 private _lastIndexUpdateTimestamp;

  event CampaignStarted(uint256 maxRewardAmount, uint256 maxStakeAmount);

  event Staked(address indexed from, address indexed user, uint256 amount);
  event Redeem(address indexed from, address indexed to, uint256 amount, uint256 id);

  event RewardAccrued(address user, uint256 amount);
  event RewardClaimed(address indexed from, address indexed to, uint256 amount);

  event RedeemRequested(
    address indexed from, address indexed to, uint256 amount, uint256 cooldownStartTimestamp, uint256 id
  );

  event IndexUpdated(uint256 index);

  event CampaignEnded();

  constructor(
    IERC20 token,
    address _rewardVault,
    address manager,
    string memory name,
    string memory symbol
  ) ERC20(name, symbol) Ownable(manager) {
    TOKEN = token;
    REWARD_VAULT = _rewardVault;
  }

  function startCampaign(uint256 maxTotalReward, uint256 duration) external onlyOwner {
    uint256 totalSupply = totalSupply();
    if (maxTotalReward > TOKEN.allowance(REWARD_VAULT, address(this)) 
      - _getIndex(block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp, totalSupply) * totalSupply) 
      revert('INSUFFICIENT_CAMPAIGN_REWARD_AMOUNT');
    
    uint256 _campaignEndTimestamp = block.timestamp + duration;
    if (_campaignEndTimestamp < campaignEndTimestamp) revert('INVALID_CAMPAIGN_ENDTIMESTAMP');
    campaignEndTimestamp = _campaignEndTimestamp;

    campaignMaxTotalSupply = maxTotalReward * ONE * 365 days / (FIXED_APR * duration);
    if (totalSupply > campaignMaxTotalSupply) revert('INSUFFICIENT_CAMPAIGN_MAX_SUPPLY');

    emit CampaignStarted(maxTotalReward, campaignMaxTotalSupply);
  }
  
  function endCampaign() external onlyOwner {
    campaignEndTimestamp = block.timestamp;
    emit CampaignEnded();
  }

  /**
   * @dev Stakes token, and starts earning reward
   **/
  function stake(address user, uint256 amount) external override {
    uint256 currentTimestamp = block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp;
    if (currentTimestamp == campaignEndTimestamp) revert('INACTIVE_CAMPAIGN');
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    uint256 totalSupply = totalSupply();
    if (totalSupply + amount > campaignMaxTotalSupply) revert('CAMPAIGN_MAX_TOTAL_SUPPLY_EXCEEDED');
    
    IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), amount);
    
    _updateStates(user, currentTimestamp, totalSupply);

    _mint(user, amount);

    emit Staked(msg.sender, user, amount);
  }

  /**
   * @dev Activates the cooldown period to unstake, and stop earning reward.
   * - It can't be called if the user is not staking
   **/
  function requestRedeem(address recipient, uint256 amount) external override returns (uint256 id) {
    uint256 balanceOfUser = balanceOf(msg.sender);
    require(balanceOfUser != 0, 'INVALID_BALANCE_ON_COOLDOWN');
    amount = (amount > balanceOfUser) ? balanceOfUser : amount;
    id = requestRedeemIndexCounts[msg.sender];
    requestRedeemIndexCounts[msg.sender]++;
    requestRedeemStatesById[msg.sender][id].recipient = recipient;
    requestRedeemStatesById[msg.sender][id].amount = amount;
    requestRedeemStatesById[msg.sender][id].cooldownStartTimestamp = block.timestamp;

    _updateStates(
      msg.sender, 
      block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp, 
      totalSupply()
    );

    _burn(msg.sender, amount);

    emit RedeemRequested(msg.sender, recipient, amount, block.timestamp, id);
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
  
    IERC20(TOKEN).safeTransfer(state.recipient, amount);

    emit Redeem(msg.sender, state.recipient, amount, id);
  }

  /**
   * @dev Claims an `amount` of `TOKEN` to the address `to`
   **/
  function claimReward(address recipient, uint256 amount) external override {
    uint256 newTotalRewardBalance = getTotalRewardBalance(msg.sender);
    uint256 amountToClaim = amount > newTotalRewardBalance ? newTotalRewardBalance : amount;
    rewardToClaim[msg.sender] = newTotalRewardBalance - amountToClaim;

    TOKEN.safeTransferFrom(REWARD_VAULT, recipient, amountToClaim);

    emit RewardClaimed(msg.sender, recipient, amountToClaim);
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

  /**
   * @dev Return the total reward pending to claim by a user
   */
  function getTotalRewardBalance(address user) public view override returns (uint256) {
    uint256 newIndex = _getIndex(block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp, totalSupply());
    return rewardToClaim[user] + _getUserAccruedReward(balanceOf(user), newIndex - _lastIndexOfUser[user]);
  }

  /**
   * @dev Update the user state related with accrued reward
   **/
  function _updateStates(
    address user, uint256 currentTimestamp, uint256 totalSupply
  ) internal returns (uint256 newUnclaimedRewards) {
    uint256 newIndex = _getIndex(currentTimestamp, totalSupply);
    
    if (newIndex != index) {
      index = newIndex;
      _lastIndexUpdateTimestamp = block.timestamp;
      emit IndexUpdated(index);
    }

    uint256 accruedReward = _getUserAccruedReward(balanceOf(user), newIndex - _lastIndexOfUser[user]);
    newUnclaimedRewards = rewardToClaim[user] + accruedReward;
    
    if (accruedReward != 0) {
      rewardToClaim[user] = newUnclaimedRewards;
      _lastIndexOfUser[user] = newIndex;
      _lastUpdateTimestampOfUser[user] = block.timestamp;
      emit RewardAccrued(user, accruedReward);
    }
  }

  function _getIndex(uint256 currentTimestamp, uint256 totalSupply) internal view returns (uint256 newIndex) {
    uint256 timeDelta = currentTimestamp - _lastIndexUpdateTimestamp;
    if (totalSupply == 0 || timeDelta == 0) return index;
    return newIndex += timeDelta * FIXED_APR / 365 days;
  }

  /**
   * @dev Updates the state of user's accrued reward
   **/
  function _getUserAccruedReward(uint256 balance, uint256 indexDelta) internal pure returns (uint256) {
    return balance * indexDelta / ONE;
  }
}

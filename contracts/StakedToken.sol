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

  uint256 public constant override COOLDOWN_SECONDS = 7 days;

  IERC20 public immutable override TOKEN;

  /// @notice Address to pull from the reward, needs to have approved this contract
  address public rewardVault;

  mapping(address => mapping(uint256 => RequestRedeemState)) public requestRedeemStatesById;
  mapping(address => uint256) public requestRedeemStartIds;
  mapping(address => uint256) public requestRedeemEndIds;
  mapping(address => uint256) public requestRedeemCounts;

  mapping(address => uint256) public rewardToClaim;

  uint256 public override campaignMaxTotalSupply;
  uint256 public override campaignEndTimestamp;
  
  mapping(address => uint256) private _lastNormalizedIncome;
  uint256 private _normalizedIncome;
  uint256 private _lastNormalizedIncomeUpdateTimestamp;
  uint256 private _claimedReward; // N5

  event CampaignStarted(uint256 maxRewardAmount, uint256 maxStakeAmount);

  event Staked(address indexed sender, address indexed staker, uint256 amount);
  event Redeem(address indexed sender, address indexed recipient, uint256 amount, uint256 id);

  event RewardAccrued(address sender, uint256 amount);
  event RewardClaimed(address indexed sender, address indexed recipient, uint256 amount);

  event RewardVaultChanged(address _rewardVault);

  event RedeemRequested(
    address indexed sender, 
    address indexed recipient, 
    uint256 amount, 
    uint256 cooldownStartTimestamp, 
    uint256 id
  );

  event NormalizedIncomeUpdated(uint256 newNormalizedIncome);

  event CampaignEnded();

  constructor(
    IERC20 _token,
    address _rewardVault,
    address _manager,
    string memory _name,
    string memory _symbol
  ) ERC20(_name, _symbol) Ownable(_manager) {
    if (_rewardVault == address(0)) revert('ZERO_ADDRESS');
    TOKEN = _token;
    rewardVault = _rewardVault;
  }

  function startCampaign(uint256 maxTotalReward, uint256 duration) external onlyOwner {
    uint256 totalSupply = totalSupply();
    if (
      maxTotalReward > TOKEN.allowance(rewardVault, address(this)) - _getNormalizedIncome(
        block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp, totalSupply
      ) * totalSupply / ONE // N2
        - _claimedReward // N5
    ) 
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
  function stake(address staker, uint256 amount) external override {
    uint256 currentTimestamp = block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp;
    if (currentTimestamp == campaignEndTimestamp) revert('INACTIVE_CAMPAIGN');
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    uint256 totalSupply = totalSupply();
    if (totalSupply + amount > campaignMaxTotalSupply) revert('CAMPAIGN_MAX_TOTAL_SUPPLY_EXCEEDED');
    
    IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), amount);
    
    _updateStates(staker, currentTimestamp, totalSupply, true);

    _mint(staker, amount);

    emit Staked(msg.sender, staker, amount);
  }

  /**
   * @dev Activates the cooldown period to unstake, and stop earning reward.
   * - It can't be called if the user is not staking
   **/
  function requestRedeem(address recipient, uint256 amount) external override returns (uint256 id) {
    uint256 balanceOfUser = balanceOf(msg.sender);
    require(balanceOfUser != 0, 'INVALID_BALANCE_ON_COOLDOWN');
    amount = (amount > balanceOfUser) ? balanceOfUser : amount;
    id = requestRedeemEndIds[msg.sender];
    requestRedeemEndIds[msg.sender]++;
    requestRedeemCounts[msg.sender]++; // N6 
    requestRedeemStatesById[msg.sender][id].recipient = recipient;
    requestRedeemStatesById[msg.sender][id].amount = amount;
    requestRedeemStatesById[msg.sender][id].cooldownStartTimestamp = block.timestamp;

    _updateStates(
      msg.sender, 
      block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp, 
      totalSupply(),
      true
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
    requestRedeemCounts[msg.sender]--; // N6 
    if (id == requestRedeemStartIds[msg.sender]) requestRedeemStartIds[msg.sender]++;
    // if (id == requestRedeemEndIds[msg.sender]) requestRedeemEndIds[msg.sender]--; // N3 . will delete
    
  
    IERC20(TOKEN).safeTransfer(state.recipient, amount);

    emit Redeem(msg.sender, state.recipient, amount, id);
  }

  /**
   * @dev Claims an `amount` of `TOKEN` to the address `to`
   **/
  function claimReward(address recipient, uint256 amount) external override {
    uint256 newTotalRewardBalance = getTotalRewardBalance(msg.sender);
    uint256 amountToClaim = amount > newTotalRewardBalance ? newTotalRewardBalance : amount;
    rewardToClaim[msg.sender] = _updateStates(
      msg.sender, 
      block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp, 
      totalSupply(),
      false
    ) - amountToClaim;

    _claimedReward += amountToClaim; // N5

    TOKEN.safeTransferFrom(rewardVault, recipient, amountToClaim);

    emit RewardClaimed(msg.sender, recipient, amountToClaim);
  }

  /**
   * @dev Sets an `amount` of `TOKEN` to the address `to`
   **/
  function setRewardVault(address _rewardVault) external onlyOwner {
    if (_rewardVault == address(0)) revert('ZERO_ADDRESS');
    rewardVault = _rewardVault;

    emit RewardVaultChanged(_rewardVault);
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
    uint256 cnt = requestRedeemCounts[user]; // N6 
    
    // for (uint256 i = requestRedeemStartIds[user]; i < requestRedeemEndIds[user]; i++) {
    //     if (requestRedeemStatesById[user][i].amount != 0) {
    //         cnt++;
    //     }
    // }  
    // N6. will delete.

    ids = new uint256[](cnt);
    requestRedeemStates = new RequestRedeemState[](cnt);

    cnt = 0;
    for (uint256 i = requestRedeemStartIds[user]; i < requestRedeemEndIds[user]; i++) {
        if (requestRedeemStatesById[user][i].amount != 0) {
            requestRedeemStates[cnt] = requestRedeemStatesById[user][i];
            ids[cnt] = i;
            cnt++;
        }
    }
  }

  function getNormalizedIncome() public view override returns (uint256 newNormalizedIncome) {
    return _getNormalizedIncome(block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp, totalSupply());
  }

  /**
   * @dev Return the total reward pending to claim by a user
   */
  function getTotalRewardBalance(address user) public view override returns (uint256) {
    return rewardToClaim[user] + _getUserAccruedReward(
      balanceOf(user), 
      _getNormalizedIncome(block.timestamp > campaignEndTimestamp ? campaignEndTimestamp : block.timestamp, totalSupply()) 
        - _lastNormalizedIncome[user]
    );
  }

  /**
   * @dev Update the user state related with accrued reward
   **/
  function _updateStates(
    address user, uint256 currentTimestamp, uint256 totalSupply, bool updateStorage
  ) internal returns (uint256 newUnclaimedRewards) {
    uint256 newNormalizedIncome = _getNormalizedIncome(currentTimestamp, totalSupply);
    
    if (_normalizedIncome != newNormalizedIncome) {
      _normalizedIncome = newNormalizedIncome;
      emit NormalizedIncomeUpdated(newNormalizedIncome);
    }

    if (_lastNormalizedIncomeUpdateTimestamp != block.timestamp)
      _lastNormalizedIncomeUpdateTimestamp = currentTimestamp; // N1
      // _lastNormalizedIncomeUpdateTimestamp = block.timestamp;
      
    uint256 accruedReward = _getUserAccruedReward(balanceOf(user), newNormalizedIncome - _lastNormalizedIncome[user]);
    newUnclaimedRewards = rewardToClaim[user] + accruedReward;
    
    if (accruedReward != 0) {
      if (updateStorage) rewardToClaim[user] = newUnclaimedRewards;
      _lastNormalizedIncome[user] = newNormalizedIncome;
      emit RewardAccrued(user, accruedReward);
    }
  }

  function _getNormalizedIncome(uint256 currentTimestamp, uint256 totalSupply) internal view returns (uint256 newNormalizedIncome) {
    uint256 timeDelta = currentTimestamp - _lastNormalizedIncomeUpdateTimestamp;
    if (totalSupply == 0 || timeDelta == 0) return _normalizedIncome;
    return _normalizedIncome + timeDelta * FIXED_APR / 365 days;
  }

  /**
   * @dev Updates the state of user's accrued reward
   **/
  function _getUserAccruedReward(uint256 balance, uint256 normalizedIncomeDelta) internal pure returns (uint256) {
    return balance * normalizedIncomeDelta / ONE;
  }
}

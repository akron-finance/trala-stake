// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IStakedToken {
  struct RequestRedeemState {
      address recipient;
      uint256 amount;
      uint256 cooldownStartTimestamp;
  }

  function stake(address to, uint256 amount) external;

  function requestRedeem(address to, uint256 amount) external returns (uint256 id);

  function redeem(uint256 id) external;

  function claimReward(address to, uint256 amount) external;

  function FIXED_APR() external view returns (uint256);

  function COOLDOWN_SECONDS() external view returns (uint256);

  function TOKEN() external view returns (IERC20);

  function campaignMaxTotalSupply() external view returns (uint256);

  function campaignEndTimestamp() external view returns (uint256);

  function getTotalRewardBalance(address user) external view returns (uint256);

  function getRequestRedeemIdsAndStates(address user) external view returns (uint256[] memory ids, RequestRedeemState[] memory requestRedeemStates);
}

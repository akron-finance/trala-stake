// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;
pragma experimental ABIEncoderV2;

interface IStakedToken {
  struct RequestRedeemState {
      address recipient;
      uint256 amount;
      uint256 cooldownStartTimestamp;
  }

  function totalSupply() external view returns (uint256);

  function COOLDOWN_SECONDS() external view returns (uint256);

  function campaignEndTimestamp() external view returns (uint256);

  function balanceOf(address user) external view returns (uint256);

  function getTotalRewardsBalance(address user) external view returns (uint256);

  function getRequestRedeemStateIds(address user) external view returns (RequestRedeemState[] memory requestRedeemStates);
}

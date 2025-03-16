// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;
pragma experimental ABIEncoderV2;

interface IStakedToken {

  function totalSupply() external view returns (uint256);

  function COOLDOWN_SECONDS() external view returns (uint256);

  function campaignEndTimestamp() external view returns (uint256);

  function balanceOf(address user) external view returns (uint256);

  function getTotalRewardsBalance(address user) external view returns (uint256);

  function getRequestRedeemStateIds(address user) external view returns (uint256[] memory ids);

  function getRequestRedeemStateById(address user, uint256 id) external view returns (uint256);
}

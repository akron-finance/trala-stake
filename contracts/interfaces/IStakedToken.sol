// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IStakedToken {
  struct AssetData {
    uint128 emission;
    uint128 lastUpdateTimestamp;
    uint256 index;
  }

  function totalSupply() external view returns (uint256);

  function COOLDOWN_SECONDS() external view returns (uint256);

  function UNSTAKE_WINDOW() external view returns (uint256);

  function DISTRIBUTION_END() external view returns (uint256);

  function assets(address asset) external view returns (AssetData memory);

  function balanceOf(address user) external view returns (uint256);

  function getTotalRewardsBalance(address user) external view returns (uint256);

  function getCooldownStateIds(address user) external view returns (uint256[] memory ids);

  function getCooldownStateById(address user, uint256 id) external view returns (uint256);
}

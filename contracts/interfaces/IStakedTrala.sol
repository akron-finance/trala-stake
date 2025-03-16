// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.8.20;

interface IStakedTrala {
  function stake(address to, uint256 amount) external;

  function requestRedeem(address to, uint256 amount) external returns (uint256 id);

  function redeem(uint256 id) external;

  function claimReward(address to, uint256 amount) external;
}

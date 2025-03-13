// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

interface IStakedTrala {
  function stake(address to, uint256 amount) external;

  function requestCooldown(uint256 amount) external returns (uint256 id);

  function redeem(uint256 id, address to, uint256 amount) external;

  function claimReward(address to, uint256 amount) external;
}

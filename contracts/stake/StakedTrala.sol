// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {StakedToken} from './StakedToken.sol';

/**
 * @title StakedTrala
 * @notice StakedToken with TRALA token as staked token
 **/
contract StakedTrala is StakedToken {
  constructor(
    IERC20 token, 
    address rewardsVault,
    address manager,
    string memory name,
    string memory symbol
  ) public
    StakedToken(
      token,
      rewardsVault,
      manager,
      name,
      symbol
    )
  {}
}

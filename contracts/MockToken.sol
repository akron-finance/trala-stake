// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.8.20;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract MockToken is  ERC20 {
  
  constructor() ERC20("MOCKToken", "MOCK"){
    _mint(msg.sender, 1000000000 * 1e18);
  }

}

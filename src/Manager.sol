// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IPool.sol";

contract Manager {
    IERC20 private immutable i_usdcToken;
    IPool immutable lendingPool;

    error InvalidUsdcToken();
    error InvalidAmount();

    constructor(address _usdcToken, address _pool) {
        if (_usdcToken == address(0)) revert InvalidUsdcToken();
        i_usdcToken = IERC20(_usdcToken);
        lendingPool = IPool(_pool);
    }

    function deposit(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        i_usdcToken.transferFrom(msg.sender, address(this), _amount);
        IERC20(address(i_usdcToken)).approve(address(lendingPool), _amount);
        lendingPool.deposit(address(i_usdcToken), _amount, address(this), 0);
    }
}

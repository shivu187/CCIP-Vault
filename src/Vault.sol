// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "./ERC4626.sol";
import {IERC20} from "ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/ERC20.sol";
import {Sender} from "./Sender.sol";
import {Manager} from "./Manager.sol";

contract Vault is ERC4626 {
    address public immutable USDCaddress;
    Sender public sender;
    Manager public manager;
    address public ownerContract;

    enum Chains {
        Arbitrum,
        Base,
        Optimism,
        Sepolia
    }
    Chains public chain = Chains.Arbitrum;

    constructor(
        address _USDC,
        address _sender,
        address _manager
    ) ERC20("Cross-Chain-Vault", "CLV") ERC4626(IERC20(_USDC)) {
        USDCaddress = _USDC;
        sender = Sender(_sender);
        manager = Manager(_manager);
        ownerContract = msg.sender;
    }

    modifier nonZero(uint256 _value) {
        require(_value != 0, "Value should not be zero");
        _;
    }

    function deposit(
        uint256 _assets,
        address _receiver
    ) public virtual override nonZero(_assets) returns (uint256) {
        uint256 maxAssets = maxDeposit(_receiver);
        if (_assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(_receiver, _assets, maxAssets);
        }
        uint256 shares = previewDeposit(_assets);
        _deposit(_msgSender(), _receiver, _assets, shares);
        if (chain == Chains.Arbitrum) {
            sender.sendMessagePayLINK(3478487238524512106, _assets);
        } else if (chain == Chains.Base) {
            manager.deposit(_assets);
        } else if (chain == Chains.Optimism) {
            sender.sendMessagePayLINK(5224473277236331295, _assets);
        } else if (chain == Chains.Sepolia) {
            sender.sendMessagePayLINK(16015286601757825753, _assets);
        }
        return shares;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override nonZero(assets) returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }
        uint256 shares = previewWithdraw(assets);
        if (chain == Chains.Arbitrum) {
            sender.sendWithdrawPayLINK(3478487238524512106, assets);
        } else if (chain == Chains.Base) {
            manager.withdraw(assets);
        } else if (chain == Chains.Optimism) {
            sender.sendWithdrawPayLINK(5224473277236331295, assets);
        } else if (chain == Chains.Sepolia) {
            sender.sendWithdrawPayLINK(16015286601757825753, assets);
        }
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return assets;
    }

    function rebalance(Chains _chain, uint256 assets) public {
        require(msg.sender == ownerContract, "Only owner can call");
        require(chain == _chain, "It is already in that chain");
        chain = _chain;
        // first withdraw
        if (chain == Chains.Arbitrum) {
            sender.sendMessagePayLINK(3478487238524512106, assets);
        } else if (chain == Chains.Base) {
            manager.deposit(assets);
        } else if (chain == Chains.Optimism) {
            sender.sendMessagePayLINK(5224473277236331295, assets);
        } else if (chain == Chains.Sepolia) {
            sender.sendMessagePayLINK(16015286601757825753, assets);
        }
        // now deposit
        if (chain == Chains.Arbitrum) {
            sender.sendMessagePayLINK(3478487238524512106, assets);
        } else if (chain == Chains.Base) {
            manager.deposit(assets);
        } else if (chain == Chains.Optimism) {
            sender.sendMessagePayLINK(5224473277236331295, assets);
        } else if (chain == Chains.Sepolia) {
            sender.sendMessagePayLINK(16015286601757825753, assets);
        }
    }
}

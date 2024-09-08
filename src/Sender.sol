// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRouterClient} from "./interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "ccip/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "./utils/Client.sol";
import {CCIPReceiver} from "./utils/CCIPReceiver.sol";
import {IERC20} from "ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/utils/structs/EnumerableMap.sol";

/// @title - A simple messenger contract for transferring tokens to a receiver  that calls a staker contract.
contract Sender is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;

    // Custom errors to provide more descriptive revert messages.
    // error InvalidRouter(); // Used when the router address is 0
    error InvalidLinkToken(); // Used when the link token address is 0
    error InvalidUsdcToken(); // Used when the usdc token address is 0
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance to cover the fees.
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error InvalidDestinationChain(); // Used when the destination chain selector is 0.
    error InvalidReceiverAddress(); // Used when the receiver address is 0.
    error NoReceiverOnDestinationChain(uint64 destinationChainSelector); // Used when the receiver address is 0 for a given destination chain.
    error AmountIsZero(); // Used if the amount to transfer is 0.
    error InvalidGasLimit(); // Used if the gas limit is 0.
    error NoGasLimitOnDestinationChain(uint64 destinationChainSelector); // Used when the gas limit is 0.
    error InvalidSenderAddress(); // Used when the sender address is 0
    error NoSenderOnSourceChain(uint64 sourceChainSelector); // Used when there is no sender for a given source chain
    error InvalidSourceChain(); // Used when the source chain is 0
    error WrongSenderForSourceChain(uint64 sourceChainSelector); // Used when the sender contract is not the correct one
    error WrongReceivedToken(address usdcToken, address receivedToken); // Used if the received token is different than usdc token
    error OnlySelf(); // Used when a function is called outside of the contract itself
    error NoReturnDataExpected(); // Used if the call to the stake function of the staker contract returns data. This is not expected
    error MessageNotFailed(bytes32 messageId); // Used if you try to retry a message that has no failed
    error CallToStakerFailed(); // Used when the call to the stake function of the staker contract is not succesful

    // Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address indexed receiver, // The address of the receiver contract on the destination chain.
        address token, // The token address that was transferred.
        uint256 tokenAmount, // The token amount that was transferred.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the message.
    );
    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address indexed sender, // The address of the sender from the source chain.
        bytes data, // The data that was received.
        address token, // The token address that was transferred.
        uint256 tokenAmount // The token amount that was transferred.
    );

    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);

    struct FailedMessage {
        bytes32 messageId;
        ErrorCode errorCode;
    }

    // Example error code, could have many different error codes.
    enum ErrorCode {
        // RESOLVED is first so that the default value is resolved.
        RESOLVED,
        // Could have any number of error codes here.
        FAILED
    }

    IRouterClient private immutable i_router;
    IERC20 private immutable i_linkToken;
    IERC20 private immutable i_usdcToken;

    // Mapping to keep track of the receiver contract per destination chain.
    mapping(uint64 => address) public s_receivers;
    // Mapping to store the gas limit per destination chain.
    mapping(uint64 => uint256) public s_gasLimits;

    // Mapping to keep track of the sender contract per source chain.
    mapping(uint64 => address) public s_senders;

    // The message contents of failed messages are stored here.
    mapping(bytes32 => Client.Any2EVMMessage) public s_messageContents;

    // Contains failed messages and their state.
    EnumerableMap.Bytes32ToUintMap internal s_failedMessages;

    modifier validateDestinationChain(uint64 _destinationChainSelector) {
        if (_destinationChainSelector == 0) revert InvalidDestinationChain();
        _;
    }

    modifier validateSourceChain(uint64 _sourceChainSelector) {
        if (_sourceChainSelector == 0) revert InvalidSourceChain();
        _;
    }

    /// @dev Modifier to allow only the contract itself to execute a function.
    /// Throws an exception if called by any account other than the contract itself.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @notice Constructor initializes the contract with the router address.
    /// @param _router The address of the router contract.
    /// @param _link The address of the link contract.
    /// @param _usdcToken The address of the usdc contract.
    constructor(
        address _router,
        address _link,
        address _usdcToken
    ) CCIPReceiver(_router) {
        if (_router == address(0)) revert InvalidRouter(_router);
        if (_link == address(0)) revert InvalidLinkToken();
        if (_usdcToken == address(0)) revert InvalidUsdcToken();
        i_router = IRouterClient(_router);
        i_linkToken = IERC20(_link);
        i_usdcToken = IERC20(_usdcToken);
    }

    /// @dev Set the receiver contract for a given destination chain.
    /// @notice This function can only be called by the owner.
    /// @param _destinationChainSelector The selector of the destination chain.
    /// @param _receiver The receiver contract on the destination chain .
    function setReceiverForDestinationChain(
        uint64 _destinationChainSelector,
        address _receiver
    ) external onlyOwner validateDestinationChain(_destinationChainSelector) {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        s_receivers[_destinationChainSelector] = _receiver;
    }

    /// @dev Set the gas limit for a given destination chain.
    /// @notice This function can only be called by the owner.
    /// @param _destinationChainSelector The selector of the destination chain.
    /// @param _gasLimit The gas limit on the destination chain .
    function setGasLimitForDestinationChain(
        uint64 _destinationChainSelector,
        uint256 _gasLimit
    ) external onlyOwner validateDestinationChain(_destinationChainSelector) {
        if (_gasLimit == 0) revert InvalidGasLimit();
        s_gasLimits[_destinationChainSelector] = _gasLimit;
    }

    /// @dev Delete the receiver contract for a given destination chain.
    /// @notice This function can only be called by the owner.
    /// @param _destinationChainSelector The selector of the destination chain.
    function deleteReceiverForDestinationChain(
        uint64 _destinationChainSelector
    ) external onlyOwner validateDestinationChain(_destinationChainSelector) {
        if (s_receivers[_destinationChainSelector] == address(0))
            revert NoReceiverOnDestinationChain(_destinationChainSelector);
        delete s_receivers[_destinationChainSelector];
    }

    /// @dev Set the sender contract for a given source chain.
    /// @notice This function can only be called by the owner.
    /// @param _sourceChainSelector The selector of the source chain.
    /// @param _sender The sender contract on the source chain .
    function setSenderForSourceChain(
        uint64 _sourceChainSelector,
        address _sender
    ) external onlyOwner validateSourceChain(_sourceChainSelector) {
        if (_sender == address(0)) revert InvalidSenderAddress();
        s_senders[_sourceChainSelector] = _sender;
    }

    /// @dev Delete the sender contract for a given source chain.
    /// @notice This function can only be called by the owner.
    /// @param _sourceChainSelector The selector of the source chain.
    function deleteSenderForSourceChain(
        uint64 _sourceChainSelector
    ) external onlyOwner validateSourceChain(_sourceChainSelector) {
        if (s_senders[_sourceChainSelector] == address(0))
            revert NoSenderOnSourceChain(_sourceChainSelector);
        delete s_senders[_sourceChainSelector];
    }

    /// @notice Sends data and transfer tokens to receiver on the destination chain.
    /// @notice Pay for fees in LINK.
    /// @dev Assumes your contract has sufficient LINK to pay for CCIP fees.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _amount token amount.
    /// @return messageId The ID of the CCIP message that was sent.
    function sendMessagePayLINK(
        uint64 _destinationChainSelector,
        uint256 _amount
    )
        external
        onlyOwner
        validateDestinationChain(_destinationChainSelector)
        returns (bytes32 messageId)
    {
        address receiver = s_receivers[_destinationChainSelector];
        if (receiver == address(0))
            revert NoReceiverOnDestinationChain(_destinationChainSelector);
        if (_amount == 0) revert AmountIsZero();
        uint256 gasLimit = s_gasLimits[_destinationChainSelector];
        if (gasLimit == 0)
            revert NoGasLimitOnDestinationChain(_destinationChainSelector);

        i_usdcToken.safeTransferFrom(msg.sender, address(this), _amount);
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(linkToken) means fees are paid in LINK
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(i_usdcToken),
            amount: _amount
        });
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: abi.encodeWithSelector(bytes4(keccak256("deposit(uint256)"))),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: gasLimit})
            ),
            feeToken: address(i_linkToken)
        });

        // Get the fee required to send the CCIP message
        uint256 fees = i_router.getFee(
            _destinationChainSelector,
            evm2AnyMessage
        );

        if (fees > i_linkToken.balanceOf(address(this)))
            revert NotEnoughBalance(i_linkToken.balanceOf(address(this)), fees);

        // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
        i_linkToken.approve(address(i_router), fees);

        // approve the Router to spend usdc tokens on contract's behalf. It will spend the amount of the given token
        i_usdcToken.approve(address(i_router), _amount);

        // Send the message through the router and store the returned message ID
        messageId = i_router.ccipSend(
            _destinationChainSelector,
            evm2AnyMessage
        );

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            receiver,
            address(i_usdcToken),
            _amount,
            address(i_linkToken),
            fees
        );

        // Return the message ID
        return messageId;
    }

    /// @notice Sends data and transfer tokens to receiver on the destination chain.
    /// @notice Pay for fees in LINK.
    /// @dev Assumes your contract has sufficient LINK to pay for CCIP fees.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _amount token amount.
    /// @return messageId The ID of the CCIP message that was sent.
    function sendWithdrawPayLINK(
        uint64 _destinationChainSelector,
        uint256 _amount
    )
        external
        onlyOwner
        validateDestinationChain(_destinationChainSelector)
        returns (bytes32 messageId)
    {
        address receiver = s_receivers[_destinationChainSelector];
        if (receiver == address(0))
            revert NoReceiverOnDestinationChain(_destinationChainSelector);
        if (_amount == 0) revert AmountIsZero();
        uint256 gasLimit = s_gasLimits[_destinationChainSelector];
        if (gasLimit == 0)
            revert NoGasLimitOnDestinationChain(_destinationChainSelector);

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(linkToken) means fees are paid in LINK
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(i_usdcToken),
            amount: _amount
        });
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: abi.encodeWithSelector(
                bytes4(keccak256("withdraw(uint256)"))
            ),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: gasLimit})
            ),
            feeToken: address(i_linkToken)
        });

        // Get the fee required to send the CCIP message
        uint256 fees = i_router.getFee(
            _destinationChainSelector,
            evm2AnyMessage
        );

        if (fees > i_linkToken.balanceOf(address(this)))
            revert NotEnoughBalance(i_linkToken.balanceOf(address(this)), fees);

        // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
        i_linkToken.approve(address(i_router), fees);

        // approve the Router to spend usdc tokens on contract's behalf. It will spend the amount of the given token
        i_usdcToken.approve(address(i_router), _amount);

        // Send the message through the router and store the returned message ID
        messageId = i_router.ccipSend(
            _destinationChainSelector,
            evm2AnyMessage
        );

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            receiver,
            address(i_usdcToken),
            _amount,
            address(i_linkToken),
            fees
        );

        // Return the message ID
        return messageId;
    }

    /// @notice Allows the owner of the contract to withdraw all LINK tokens in the contract and transfer them to a beneficiary.
    /// @dev This function reverts with a 'NothingToWithdraw' error if there are no tokens to withdraw.
    /// @param _beneficiary The address to which the tokens will be sent.
    function withdrawLinkToken(address _beneficiary) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = i_linkToken.balanceOf(address(this));

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        i_linkToken.safeTransfer(_beneficiary, amount);
    }

    /// @notice Allows the owner of the contract to withdraw all usdc tokens in the contract and transfer them to a beneficiary.
    /// @dev This function reverts with a 'NothingToWithdraw' error if there are no tokens to withdraw.
    /// @param _beneficiary The address to which the tokens will be sent.
    function withdrawUsdcToken(address _beneficiary) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = i_usdcToken.balanceOf(address(this));

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        i_usdcToken.safeTransfer(_beneficiary, amount);
    }

    /// @notice The entrypoint for the CCIP router to call. This function should
    /// never revert, all errors should be handled internally in this contract.
    /// @param any2EvmMessage The message to process.
    /// @dev Extremely important to ensure only router calls this.
    function ccipReceive(
        Client.Any2EVMMessage calldata any2EvmMessage
    ) external override onlyRouter {
        // validate the sender contract
        if (
            abi.decode(any2EvmMessage.sender, (address)) !=
            s_senders[any2EvmMessage.sourceChainSelector]
        ) revert WrongSenderForSourceChain(any2EvmMessage.sourceChainSelector);
        /* solhint-disable no-empty-blocks */
        try this.processMessage(any2EvmMessage) {
            // Intentionally empty in this example; no action needed if processMessage succeeds
        } catch (bytes memory err) {
            // Could set different error codes based on the caught error. Each could be
            // handled differently.
            // s_failedMessages.set(
            //     any2EvmMessage.messageId,
            //     uint256(ErrorCode.FAILED)
            // );
            s_messageContents[any2EvmMessage.messageId] = any2EvmMessage;
            // Don't revert so CCIP doesn't revert. Emit event instead.
            // The message can be retried later without having to do manual execution of CCIP.
            emit MessageFailed(any2EvmMessage.messageId, err);
            return;
        }
    }

    /// @notice Serves as the entry point for this contract to process incoming messages.
    /// @param any2EvmMessage Received CCIP message.
    /// @dev Transfers specified token amounts to the owner of this contract. This function
    /// must be external because of the  try/catch for error handling.
    /// It uses the `onlySelf`: can only be called from the contract.
    function processMessage(
        Client.Any2EVMMessage calldata any2EvmMessage
    ) external onlySelf {
        _ccipReceive(any2EvmMessage); // process the message - may revert
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        if (any2EvmMessage.destTokenAmounts[0].token != address(i_usdcToken))
            revert WrongReceivedToken(
                address(i_usdcToken),
                any2EvmMessage.destTokenAmounts[0].token
            );
        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
            abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
            any2EvmMessage.data, // received data
            any2EvmMessage.destTokenAmounts[0].token,
            any2EvmMessage.destTokenAmounts[0].amount
        );
    }
}

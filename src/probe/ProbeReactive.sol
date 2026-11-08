// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {CronTopics} from "reactive-kit/CronTopics.sol";

/// @title ProbeReactive
/// @notice Day-1 spike on Lasna. Answers, with real transactions:
///         - does an ERC-20 `Transfer(from = owner)` on Base / Ethereum / Unichain Sepolia reach `react()`?
///         - does a zero-value `transferFrom(owner, spoofer, 0)` reach `react()` (spoof surface)?
///         - does one Cron10 tick reach `react()`, and how far apart are the ticks?
///         - what address does the destination see as the injected first callback argument?
///         - how long is the callback -> Ack round trip (callback contract event observed back on Lasna)?
/// @dev Spends are bounded: at most `maxCallbacks` callbacks and `maxCronTicks` CRON reacts before it unsubscribes.
contract ProbeReactive is AbstractReactive {
    uint256 internal constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 internal constant PINGED_TOPIC = uint256(keccak256("Pinged(address,uint256,uint256,uint256,uint256)"));
    uint64 internal constant CALLBACK_GAS = 1_000_000;

    address public immutable owner;
    uint256 public immutable destChainId;
    address public immutable destContract;
    uint256 public immutable maxCallbacks;
    uint256 public immutable maxCronTicks;

    uint256 public callbacksSent;
    uint256 public cronTicks;
    uint256 public lastCronBlock;
    uint256 public lastCronAt;
    bool public cronOn;

    event Seen(uint256 indexed chainId, address indexed token, uint256 from, uint256 to, uint256 value, uint256 originTx);
    event CallbackSent(uint256 indexed seq, uint256 originChainId, uint256 originTx);
    event AckSeen(uint256 indexed seq, uint256 rvmInjected, uint256 destTx);
    event CronTick(uint256 indexed n, uint256 cronBlock, uint256 reactBlock, uint256 at, uint256 gapSeconds);
    event CronOff(uint256 ticks, bool viaReact);

    error NotOwner();

    constructor(uint256 destChainId_, address destContract_, uint256 maxCallbacks_, uint256 maxCronTicks_) payable {
        owner = msg.sender;
        destChainId = destChainId_;
        destContract = destContract_;
        maxCallbacks = maxCallbacks_;
        maxCronTicks = maxCronTicks_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Subscribe to `Transfer(from = owner)` of `token` on `chainId`.
    function watchToken(uint256 chainId, address token) external onlyOwner {
        SYSTEM.subscribe(chainId, token, TRANSFER_TOPIC, uint256(uint160(owner)), REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Subscribe to the destination contract's `Pinged` event (the Ack leg of the round trip).
    function watchAck() external onlyOwner {
        SYSTEM.subscribe(destChainId, destContract, PINGED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function cronStart() external onlyOwner {
        cronOn = true;
        SYSTEM.subscribe(
            block.chainid, CronTopics.LEGACY_SYSTEM_ADDR, CronTopics.CRON10, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Manual fallback if unsubscribing from inside `react()` is not allowed.
    function cronStop() external onlyOwner {
        _cronUnsubscribe();
        emit CronOff(cronTicks, false);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (CronTopics.isCron(log_.contractAddress, log_.topic0)) {
            _onCron(log_);
        } else if (log_.chainId == destChainId && log_.contractAddress == destContract && log_.topic0 == PINGED_TOPIC) {
            // Pinged(address indexed rvm, uint256 indexed seq, ...) -> topic1 = injected rvm, topic2 = seq
            emit AckSeen(log_.topic2, log_.topic1, log_.txHash);
        } else if (log_.topic0 == TRANSFER_TOPIC) {
            uint256 value = log_.data.length >= 32 ? abi.decode(log_.data, (uint256)) : 0;
            emit Seen(log_.chainId, log_.contractAddress, log_.topic1, log_.topic2, value, log_.txHash);
            if (callbacksSent < maxCallbacks) {
                uint256 seq = ++callbacksSent;
                bytes memory payload = abi.encodeWithSignature(
                    "ping(address,uint256,uint256,uint256)", address(0), seq, log_.chainId, log_.txHash
                );
                emit CallbackSent(seq, log_.chainId, log_.txHash);
                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: destChainId, recipient: destContract, gasLimit: CALLBACK_GAS, payload: payload
                    })
                );
            }
        }
    }

    function _onCron(LogRecord calldata log_) internal {
        uint256 n = ++cronTicks;
        uint256 cronBlock = log_.data.length >= 32 ? abi.decode(log_.data, (uint256)) : 0;
        uint256 gap = lastCronAt == 0 ? 0 : block.timestamp - lastCronAt;
        lastCronAt = block.timestamp;
        lastCronBlock = cronBlock;
        emit CronTick(n, cronBlock, block.number, block.timestamp, gap);
        if (n >= maxCronTicks && cronOn) {
            // Probe: can a react() unsubscribe itself? If SYSTEM refuses, owner falls back to cronStop().
            try SYSTEM.unsubscribe(
                block.chainid,
                CronTopics.LEGACY_SYSTEM_ADDR,
                CronTopics.CRON10,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            ) {
                cronOn = false;
                emit CronOff(n, true);
            } catch {}
        }
    }

    function _cronUnsubscribe() internal {
        cronOn = false;
        SYSTEM.unsubscribe(
            block.chainid, CronTopics.LEGACY_SYSTEM_ADDR, CronTopics.CRON10, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Return unspent lREACT to the owner when the probe is done.
    function drain() external onlyOwner {
        (bool ok,) = payable(owner).call{value: address(this).balance}("");
        require(ok, "drain");
    }
}

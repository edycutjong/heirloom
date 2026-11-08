// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {IPayer} from "reactive-lib-omni/interfaces/IPayer.sol";
import {CronTopics} from "reactive-kit/CronTopics.sol";
import {AckLedger} from "reactive-kit/AckLedger.sol";
import {CallbackFailureWatch} from "reactive-kit/CallbackFailureWatch.sol";
import {HeirloomTypes, IHeirloomVault} from "./HeirloomTypes.sol";

/// @title HeirloomReactive
/// @notice Watches one owner's ordinary token transfers across chains and acts when they STOP. After T seconds of
///         silence (extended once by `freezeCap` if an owner-independent canary feed says the network itself was
///         down), it opens a grace window on the Base vault; after grace it marks the vault claimable. Any real
///         activity (an allowlisted value > 0 `Transfer` from the owner, or any owner action on the vault) cancels.
/// @dev Omni only: `SYSTEM.subscribe/unsubscribe`, `requestCallbackV_1_0`, CRON topics. Timestamps, never block
///      counts. Every callback is ONE full snapshot to `vault.sync`; delivery is confirmed by the vault's `Ack`
///      and an un-acked snapshot is resent on CRON ticks (bounded by an AckLedger policy) or, immediately, on the
///      destination proxy's target-indexed `CallbackFailure` log.
contract HeirloomReactive is AbstractReactive {
    using AckLedger for AckLedger.Pending;

    // ------------------------------------------------------------------ constants

    uint256 internal constant TRANSFER_T0 = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 internal constant ANSWER_UPDATED_T0 = uint256(keccak256("AnswerUpdated(int256,uint256,uint256)"));
    uint256 internal constant OWNER_ACTIVE_T0 = uint256(keccak256("OwnerActive(uint8,uint64,bytes32)"));
    uint256 internal constant ALLOWLIST_T0 = uint256(keccak256("AllowlistChanged(uint256,address,bool)"));
    uint256 internal constant ACK_T0 = uint256(keccak256("Ack(uint64,uint64,bytes32,bool)"));
    uint256 internal constant RELEASED_T0 = uint256(keccak256("EstateReleased()"));
    uint256 internal constant RETIRED_T0 = uint256(keccak256("Retired()"));

    uint64 public constant CALLBACK_GAS = 1_000_000; // Panic(0x11) seen at 200k on the network (team, Telegram)
    uint256 public constant MAX_TOKENS = 8;
    uint8 public constant FAST_TRIES = 3;

    enum Refusal {
        MALFORMED,
        NOT_ALLOWLISTED,
        NOT_OWNER,
        ZERO_VALUE
    }

    struct Config {
        uint64 T; // silence before grace
        uint64 grace;
        uint64 freezeCap; // one extension per silence epoch when a canary is stale
        uint64 attestEvery;
        uint64 ackTimeout; // >= 2 x p95 callback -> Ack round trip
        uint64 tickPeriod; // measured seconds per tick of `cronTopic` (sizes the canary arm window)
        uint64 brakeWindow;
        uint32 maxRefusedPerWindow;
        uint256 cronTopic; // fixed tier for the whole life of the instance
        uint256 graceCronTopic; // optional faster tier subscribed ONLY during grace (0 = off)
        uint256 destChainId; // Base (mainnet or Sepolia); the ONLY callback target chain
        address callbackProxy; // destination proxy emitting CallbackFailure (0 = do not watch failures)
    }

    struct TokenRef {
        uint256 chainId;
        address token;
    }

    struct Brake {
        uint64 windowStart;
        uint32 refusedInWindow;
        uint64 brakedUntil; // 0 = not braked
    }

    struct Canary {
        address aggregator;
        uint64 maxGap;
        uint64 lastAt;
        uint64 maxGapSeen;
        bool armed;
    }

    struct CanaryInit {
        uint256 chainId;
        address aggregator;
        uint64 maxGap;
    }

    // ------------------------------------------------------------------ immutables

    address public immutable owner; // the watched wallet (topic1 of Transfer)
    address public immutable deployer;
    uint64 public immutable T;
    uint64 public immutable grace;
    uint64 public immutable freezeCap;
    uint64 public immutable attestEvery;
    uint64 public immutable ackTimeout;
    uint64 public immutable tickPeriod;
    uint64 public immutable brakeWindow;
    uint32 public immutable maxRefusedPerWindow;
    uint256 public immutable cronTopic;
    uint256 public immutable graceCronTopic;
    uint256 public immutable destChainId;
    address public immutable callbackProxy;

    // ------------------------------------------------------------------ state

    address public vault;
    HeirloomTypes.Phase public phase;

    uint64 public lastSeen;
    uint256 public lastChain;
    address public lastToken;
    bytes32 public lastOriginTx;
    uint64 public observedFrom; // the T clock runs from here: max(lastSeen, last brake lift)
    uint64 public graceEndsAt;
    bool public epochFreezeUsed;

    uint64 public ownerNonceSeen;
    bytes32 public ownerActionIdSeen;

    TokenRef[] internal _tokens;
    mapping(uint256 => mapping(address => bool)) public allowed;
    mapping(uint256 => mapping(address => bool)) public subscribed;
    mapping(uint256 => mapping(address => Brake)) public brakes;
    uint256 public brakedCount;

    uint256[] internal _canaryChains;
    mapping(uint256 => Canary) public canaries;

    uint64 public nextSeq;
    AckLedger.Pending public pending;
    HeirloomTypes.Kind public pendingKind;

    uint64 public lastAttestAt;
    uint256 public balanceAtLastAttest;
    uint256 public depositsSinceAttest;

    uint32 public refusedTotal;
    mapping(Refusal => uint32) public refusedBy;

    bool internal _graceCronOn;

    // ------------------------------------------------------------------ events

    event Seen(uint256 indexed chainId, address indexed token, uint256 originTx);
    event SpoofRefused(uint256 indexed chainId, address indexed token, uint256 originTx, Refusal reason);
    event SpamBrake(uint256 indexed chainId, address indexed token, uint64 until);
    event ObservationReset(uint256 indexed chainId, address indexed token, uint64 liftTime);
    event FreezeUsed(uint64 newDeadline);
    event PhaseChanged(HeirloomTypes.Phase from, HeirloomTypes.Phase to);
    event CallbackSent(uint64 indexed seq, HeirloomTypes.Kind kind, uint8 tries);
    event CallbackStuck(uint64 indexed seq);
    event CallbackFailed(uint64 indexed seq, uint256 failureTx);
    event Acked(uint64 indexed seq, uint256 ackTx);
    event OwnerVersionAdopted(uint64 nonce, bytes32 actionId, uint256 ackTx);
    event CanaryArmed(uint256 indexed chainId);
    event CanaryBeat(uint256 indexed chainId, uint64 gap);
    event CanaryDisarmed(uint256 indexed chainId);
    event AllowlistFull(uint256 indexed chainId, address indexed token);
    event GraceCron(bool on);
    event TornDown(uint256 trigger);

    error NotDeployer();
    error AlreadyWired();
    error BadConfig();

    // ------------------------------------------------------------------ setup

    /// @param owner_ the watched wallet; distinct from the deployer (an everyday wallet the deployer never holds)
    constructor(address owner_, Config memory c) payable {
        if (owner_ == address(0) || c.T == 0 || c.grace == 0 || c.attestEvery == 0 || c.tickPeriod == 0) revert BadConfig();
        if (CronTopics.interval(c.cronTopic) == 0) revert BadConfig();
        if (c.graceCronTopic != 0 && CronTopics.interval(c.graceCronTopic) == 0) revert BadConfig();
        AckLedger.validate(AckLedger.Policy(c.ackTimeout, FAST_TRIES, c.attestEvery));
        owner = owner_;
        deployer = msg.sender;
        T = c.T;
        grace = c.grace;
        freezeCap = c.freezeCap;
        attestEvery = c.attestEvery;
        ackTimeout = c.ackTimeout;
        tickPeriod = c.tickPeriod;
        brakeWindow = c.brakeWindow;
        maxRefusedPerWindow = c.maxRefusedPerWindow;
        cronTopic = c.cronTopic;
        graceCronTopic = c.graceCronTopic;
        destChainId = c.destChainId;
        callbackProxy = c.callbackProxy;
    }

    /// @notice One-time wiring (deploy order RC -> vault -> setVault). Subscribes the vault events, the initial
    ///         allowlist, the canaries (only now if T < armWindow, else near the deadline) and the CRON tier.
    function setVault(address vault_, TokenRef[] calldata tokens_, CanaryInit[] calldata canaries_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (vault != address(0) || vault_ == address(0)) revert AlreadyWired();
        vault = vault_;
        _vaultSubs(true);
        for (uint256 i; i < tokens_.length; i++) {
            _allow(tokens_[i].chainId, tokens_[i].token);
        }
        uint64 nowTs = uint64(block.timestamp);
        for (uint256 i; i < canaries_.length; i++) {
            CanaryInit calldata ci = canaries_[i];
            if (ci.aggregator == address(0) || ci.maxGap == 0) revert BadConfig();
            canaries[ci.chainId] = Canary(ci.aggregator, ci.maxGap, 0, 0, false);
            _canaryChains.push(ci.chainId);
            if (_alwaysOn(ci.chainId)) _armCanary(ci.chainId, nowTs);
        }
        _cron(cronTopic, true);
        lastSeen = nowTs;
        observedFrom = nowTs;
        lastAttestAt = nowTs;
        balanceAtLastAttest = address(this).balance;
    }

    /// @notice Funds for reacts and callbacks. Counted so the runway estimate ignores top-ups.
    receive() external payable override(AbstractPayer, IPayer) {
        depositsSinceAttest += msg.value;
    }

    // ------------------------------------------------------------------ react

    function react(LogRecord calldata log_) external onlySystem {
        if (phase == HeirloomTypes.Phase.DONE) return;

        // H6: the token filter is the first thing a Transfer meets (refused reacts are billed; keep them cheap).
        if (log_.topic0 == TRANSFER_T0) {
            if (log_.opCode != 3 || log_.data.length != 32) return _refuse(log_, Refusal.MALFORMED, true);
            if (!allowed[log_.chainId][log_.contractAddress]) return _refuse(log_, Refusal.NOT_ALLOWLISTED, false);
            if (log_.topic1 != uint256(uint160(owner))) return _refuse(log_, Refusal.NOT_OWNER, false);
            if (abi.decode(log_.data, (uint256)) == 0) return _refuse(log_, Refusal.ZERO_VALUE, true);
            return _seen(log_.chainId, log_.contractAddress, log_.txHash);
        }

        if (log_.contractAddress == CronTopics.LEGACY_SYSTEM_ADDR) {
            if (log_.topic0 == cronTopic || (log_.topic0 == graceCronTopic && graceCronTopic != 0)) _tick();
            return;
        }

        if (log_.chainId == destChainId && log_.contractAddress == vault) return _onVault(log_);

        if (
            callbackProxy != address(0)
                && CallbackFailureWatch.isFailure(log_, destChainId, callbackProxy, vault)
        ) return _onFailure(log_);

        if (log_.topic0 == ANSWER_UPDATED_T0) {
            Canary storage c = canaries[log_.chainId];
            if (c.armed && c.aggregator == log_.contractAddress) {
                uint64 nowTs = uint64(block.timestamp);
                uint64 gap = nowTs - c.lastAt;
                if (gap > c.maxGapSeen) c.maxGapSeen = gap;
                c.lastAt = nowTs;
                emit CanaryBeat(log_.chainId, gap);
            }
        }
    }

    // ------------------------------------------------------------------ token path

    function _refuse(LogRecord calldata log_, Refusal reason, bool countBrake) internal {
        refusedTotal++;
        refusedBy[reason]++;
        emit SpoofRefused(log_.chainId, log_.contractAddress, log_.txHash, reason);
        if (countBrake && subscribed[log_.chainId][log_.contractAddress]) _brakeCount(log_.chainId, log_.contractAddress);
    }

    /// @dev H6 hard bound: at `maxRefusedPerWindow` refusals per `brakeWindow`, the token is unsubscribed until a
    ///      CRON tick after `brakedUntil`. The vault's OwnerActive channel is never braked.
    function _brakeCount(uint256 chainId, address token) internal {
        if (maxRefusedPerWindow == 0) return;
        Brake storage b = brakes[chainId][token];
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs >= b.windowStart + brakeWindow) {
            b.windowStart = nowTs;
            b.refusedInWindow = 0;
        }
        if (++b.refusedInWindow < maxRefusedPerWindow) return;
        b.brakedUntil = nowTs + brakeWindow;
        brakedCount++;
        _unsubscribeToken(chainId, token);
        emit SpamBrake(chainId, token, b.brakedUntil);
        // Blackout rule: a claim clock must never run over a blind token.
        if (phase == HeirloomTypes.Phase.GRACE) {
            _setPhase(HeirloomTypes.Phase.ARMED);
            _send(HeirloomTypes.Kind.CANCEL);
        } else if (phase == HeirloomTypes.Phase.EXPIRED) {
            _setPhase(HeirloomTypes.Phase.ARMED);
            _send(HeirloomTypes.Kind.REVIVE);
        }
    }

    function _seen(uint256 chainId, address token, uint256 txHash) internal {
        uint64 nowTs = uint64(block.timestamp);
        lastSeen = nowTs;
        if (nowTs > observedFrom) observedFrom = nowTs;
        lastChain = chainId;
        lastToken = token;
        lastOriginTx = bytes32(txHash);
        epochFreezeUsed = false;
        _resetCanaries();
        emit Seen(chainId, token, txHash);
        if (phase == HeirloomTypes.Phase.GRACE) {
            _setPhase(HeirloomTypes.Phase.ARMED);
            _send(HeirloomTypes.Kind.CANCEL);
        } else if (phase == HeirloomTypes.Phase.EXPIRED) {
            _setPhase(HeirloomTypes.Phase.ARMED);
            _send(HeirloomTypes.Kind.REVIVE);
        }
    }

    // ------------------------------------------------------------------ vault path

    function _onVault(LogRecord calldata log_) internal {
        uint256 t0 = log_.topic0;
        if (t0 == OWNER_ACTIVE_T0) {
            (uint64 n, bytes32 id) = abi.decode(log_.data, (uint64, bytes32));
            ownerNonceSeen = n;
            ownerActionIdSeen = id;
            _seen(log_.chainId, log_.contractAddress, log_.txHash);
        } else if (t0 == ALLOWLIST_T0) {
            uint256 chainId = log_.topic1;
            address token = address(uint160(log_.topic2));
            if (abi.decode(log_.data, (bool))) _allow(chainId, token);
            else _disallow(chainId, token);
        } else if (t0 == ACK_T0) {
            uint64 seq = uint64(log_.topic1);
            (uint64 n, bytes32 id, bool terminal) = abi.decode(log_.data, (uint64, bytes32, bool));
            if (terminal) return _teardown(log_.txHash);
            if (pending.ack(seq)) emit Acked(seq, log_.txHash);
            if (n != ownerNonceSeen || id != ownerActionIdSeen) {
                // A missed owner action (or a Base reorg rollback): adopt the vault's version and count it as life.
                ownerNonceSeen = n;
                ownerActionIdSeen = id;
                emit OwnerVersionAdopted(n, id, log_.txHash);
                _seen(log_.chainId, log_.contractAddress, log_.txHash);
            }
        } else if (t0 == RELEASED_T0 || t0 == RETIRED_T0) {
            _teardown(log_.txHash);
        }
    }

    function _onFailure(LogRecord calldata log_) internal {
        bytes memory p = CallbackFailureWatch.payload(log_);
        if (CallbackFailureWatch.selectorOf(p) != IHeirloomVault.sync.selector || p.length < 4 + 64) return;
        uint64 seq = uint64(CallbackFailureWatch.argWord(p, 1));
        emit CallbackFailed(seq, log_.txHash);
        // Immediate resend only inside the fast budget; past it the CRON backoff paces resends (bounded spend).
        if (pending.open && pending.seq == seq && pending.tries <= FAST_TRIES) _resend();
    }

    // ------------------------------------------------------------------ the clock

    function _tick() internal {
        if (vault == address(0)) return;
        uint64 nowTs = uint64(block.timestamp);

        _liftBrakes(nowTs);

        if (pending.due(_policy(), nowTs)) _resend();

        if (brakedCount == 0) {
            if (phase == HeirloomTypes.Phase.ARMED) {
                uint64 dl = deadline();
                if (nowTs > dl) {
                    if (!epochFreezeUsed && _anyCanaryStale(nowTs)) {
                        epochFreezeUsed = true;
                        emit FreezeUsed(deadline());
                    } else {
                        graceEndsAt = nowTs + grace;
                        _setPhase(HeirloomTypes.Phase.GRACE);
                        _send(HeirloomTypes.Kind.GRACE);
                    }
                    _disarmCanaries(); // the epoch's canary check is done
                } else {
                    _armCanariesNear(dl, nowTs);
                }
            } else if (phase == HeirloomTypes.Phase.GRACE && nowTs > graceEndsAt) {
                _setPhase(HeirloomTypes.Phase.EXPIRED);
                _send(HeirloomTypes.Kind.EXPIRE);
            }
        }

        if (nowTs >= lastAttestAt + attestEvery) {
            // An attest never overwrites a pending state change: skip it, keep the cadence.
            if (!pending.open) _send(HeirloomTypes.Kind.ATTEST);
            _rollRunway(nowTs);
        }
    }

    function _liftBrakes(uint64 nowTs) internal {
        if (brakedCount == 0) return;
        for (uint256 i; i < _tokens.length; i++) {
            TokenRef memory r = _tokens[i];
            _liftOne(r.chainId, r.token, nowTs);
        }
    }

    function _liftOne(uint256 chainId, address token, uint64 nowTs) internal {
        Brake storage b = brakes[chainId][token];
        if (b.brakedUntil == 0 || nowTs < b.brakedUntil) return;
        b.brakedUntil = 0;
        b.windowStart = nowTs;
        b.refusedInWindow = 0;
        brakedCount--;
        if (allowed[chainId][token]) _subscribeToken(chainId, token);
        // The brake hid real transfers: restart the T clock from the lift.
        if (nowTs > observedFrom) observedFrom = nowTs;
        emit ObservationReset(chainId, token, nowTs);
    }

    // ------------------------------------------------------------------ callbacks

    function _send(HeirloomTypes.Kind kind) internal {
        uint64 seq = ++nextSeq;
        pending.start(seq, keccak256(abi.encode(kind)), uint64(block.timestamp));
        pendingKind = kind;
        _request(seq, kind);
        emit CallbackSent(seq, kind, 1);
        if (kind == HeirloomTypes.Kind.GRACE) _graceCron(true);
        else if (kind != HeirloomTypes.Kind.ATTEST) _graceCron(false);
    }

    /// @dev Same seq, fresh snapshot: the vault treats it as one delivery; the state inside is the newest.
    function _resend() internal {
        bool stuck = pending.markResent(_policy(), uint64(block.timestamp));
        _request(pending.seq, pendingKind);
        emit CallbackSent(pending.seq, pendingKind, pending.tries);
        if (stuck) emit CallbackStuck(pending.seq);
    }

    function _request(uint64 seq, HeirloomTypes.Kind kind) internal {
        HeirloomTypes.Snapshot memory s = HeirloomTypes.Snapshot({
            seq: seq,
            kind: kind,
            rcPhase: phase,
            ownerNonce: ownerNonceSeen,
            ownerActionId: ownerActionIdSeen,
            lastSeen: lastSeen,
            lastChain: lastChain,
            originTx: lastOriginTx,
            graceEndsAt: graceEndsAt,
            runwayDays: runwayDays()
        });
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId,
                recipient: vault,
                gasLimit: CALLBACK_GAS,
                payload: abi.encodeCall(IHeirloomVault.sync, (address(0), s))
            })
        );
    }

    function _policy() internal view returns (AckLedger.Policy memory) {
        return AckLedger.Policy(ackTimeout, FAST_TRIES, attestEvery);
    }

    // ------------------------------------------------------------------ canaries

    function _armWindow(uint256 chainId) internal view returns (uint64) {
        return 2 * tickPeriod + 2 * canaries[chainId].maxGap;
    }

    /// @dev If T is shorter than the arm window (demo instance) the canary simply stays subscribed.
    function _alwaysOn(uint256 chainId) internal view returns (bool) {
        return T < _armWindow(chainId);
    }

    function _armCanary(uint256 chainId, uint64 nowTs) internal {
        Canary storage c = canaries[chainId];
        if (c.armed) return;
        c.armed = true;
        c.lastAt = nowTs; // arming EDGE only
        c.maxGapSeen = 0;
        SYSTEM.subscribe(chainId, c.aggregator, ANSWER_UPDATED_T0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit CanaryArmed(chainId);
    }

    function _disarmCanary(uint256 chainId) internal {
        Canary storage c = canaries[chainId];
        if (!c.armed) return;
        c.armed = false;
        SYSTEM.unsubscribe(chainId, c.aggregator, ANSWER_UPDATED_T0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit CanaryDisarmed(chainId);
    }

    function _armCanariesNear(uint64 dl, uint64 nowTs) internal {
        for (uint256 i; i < _canaryChains.length; i++) {
            uint256 id = _canaryChains[i];
            uint64 w = _armWindow(id);
            if (!canaries[id].armed && (dl <= w || nowTs >= dl - w)) _armCanary(id, nowTs);
        }
    }

    function _disarmCanaries() internal {
        for (uint256 i; i < _canaryChains.length; i++) {
            uint256 id = _canaryChains[i];
            if (!_alwaysOn(id)) _disarmCanary(id);
        }
    }

    /// @dev On real activity: unsubscribe near-deadline canaries; always-on canaries start a fresh epoch.
    function _resetCanaries() internal {
        for (uint256 i; i < _canaryChains.length; i++) {
            uint256 id = _canaryChains[i];
            if (_alwaysOn(id)) canaries[id].maxGapSeen = 0;
            else _disarmCanary(id);
        }
    }

    function _anyCanaryStale(uint64 nowTs) internal view returns (bool) {
        for (uint256 i; i < _canaryChains.length; i++) {
            Canary storage c = canaries[_canaryChains[i]];
            if (c.armed && (nowTs - c.lastAt > c.maxGap || c.maxGapSeen > c.maxGap)) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ subscriptions (one helper pair per kind)

    function _allow(uint256 chainId, address token) internal {
        if (allowed[chainId][token]) return;
        if (_tokens.length >= MAX_TOKENS) {
            emit AllowlistFull(chainId, token);
            return;
        }
        allowed[chainId][token] = true;
        _tokens.push(TokenRef(chainId, token));
        if (brakes[chainId][token].brakedUntil == 0) _subscribeToken(chainId, token);
    }

    function _disallow(uint256 chainId, address token) internal {
        if (!allowed[chainId][token]) return;
        allowed[chainId][token] = false;
        _unsubscribeToken(chainId, token);
        Brake storage b = brakes[chainId][token];
        if (b.brakedUntil != 0) {
            b.brakedUntil = 0;
            brakedCount--;
        }
        for (uint256 i; i < _tokens.length; i++) {
            if (_tokens[i].chainId == chainId && _tokens[i].token == token) {
                _tokens[i] = _tokens[_tokens.length - 1];
                _tokens.pop();
                break;
            }
        }
    }

    function _subscribeToken(uint256 chainId, address token) internal {
        if (subscribed[chainId][token]) return;
        subscribed[chainId][token] = true;
        SYSTEM.subscribe(chainId, token, TRANSFER_T0, uint256(uint160(owner)), REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _unsubscribeToken(uint256 chainId, address token) internal {
        if (!subscribed[chainId][token]) return;
        subscribed[chainId][token] = false;
        SYSTEM.unsubscribe(chainId, token, TRANSFER_T0, uint256(uint160(owner)), REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _cron(uint256 topic, bool on) internal {
        if (on) {
            SYSTEM.subscribe(block.chainid, CronTopics.LEGACY_SYSTEM_ADDR, topic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        } else {
            SYSTEM.unsubscribe(block.chainid, CronTopics.LEGACY_SYSTEM_ADDR, topic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    function _graceCron(bool on) internal {
        if (graceCronTopic == 0 || _graceCronOn == on) return;
        _graceCronOn = on;
        _cron(graceCronTopic, on);
        emit GraceCron(on);
    }

    function _vaultSubs(bool on) internal {
        uint256[5] memory t0s = [OWNER_ACTIVE_T0, ALLOWLIST_T0, ACK_T0, RELEASED_T0, RETIRED_T0];
        for (uint256 i; i < 5; i++) {
            if (on) SYSTEM.subscribe(destChainId, vault, t0s[i], REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            else SYSTEM.unsubscribe(destChainId, vault, t0s[i], REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        if (callbackProxy != address(0)) {
            if (on) {
                SYSTEM.subscribe(destChainId, callbackProxy, CallbackFailureWatch.TOPIC, uint256(uint160(vault)), REACTIVE_IGNORE, REACTIVE_IGNORE);
            } else {
                SYSTEM.unsubscribe(destChainId, callbackProxy, CallbackFailureWatch.TOPIC, uint256(uint160(vault)), REACTIVE_IGNORE, REACTIVE_IGNORE);
            }
        }
    }

    /// @dev I9: after release / retire / a terminal Ack the RC holds no subscription (CRON bills every tick).
    function _teardown(uint256 trigger) internal {
        _cron(cronTopic, false);
        _graceCron(false);
        for (uint256 i; i < _tokens.length; i++) {
            _unsubscribeToken(_tokens[i].chainId, _tokens[i].token);
        }
        for (uint256 i; i < _canaryChains.length; i++) {
            _disarmCanary(_canaryChains[i]);
        }
        _vaultSubs(false);
        pending.open = false;
        _setPhase(HeirloomTypes.Phase.DONE);
        emit TornDown(trigger);
    }

    // ------------------------------------------------------------------ helpers & views

    function _setPhase(HeirloomTypes.Phase to) internal {
        emit PhaseChanged(phase, to);
        phase = to;
    }

    function _rollRunway(uint64 nowTs) internal {
        lastAttestAt = nowTs;
        balanceAtLastAttest = address(this).balance;
        depositsSinceAttest = 0;
    }

    /// @notice Deadline of the current silence epoch.
    function deadline() public view returns (uint64) {
        return observedFrom + T + (epochFreezeUsed ? freezeCap : 0);
    }

    /// @notice Days of reserve left at the spend rate since the last attest (estimate; max if nothing spent yet).
    function runwayDays() public view returns (uint32) {
        uint256 bal = address(this).balance;
        uint256 start = balanceAtLastAttest + depositsSinceAttest;
        uint256 elapsed = block.timestamp - lastAttestAt;
        if (start <= bal || elapsed == 0) return type(uint32).max;
        uint256 days_ = bal * elapsed / ((start - bal) * 1 days);
        return days_ > type(uint32).max ? type(uint32).max : uint32(days_);
    }

    function tokens() external view returns (TokenRef[] memory) {
        return _tokens;
    }

    function canaryChains() external view returns (uint256[] memory) {
        return _canaryChains;
    }

    struct Status {
        HeirloomTypes.Phase phase;
        uint64 lastSeen;
        uint256 lastChain;
        bytes32 lastOriginTx;
        uint64 deadline;
        uint64 graceEndsAt;
        uint32 refusedTotal;
        uint256 brakedCount;
        uint64 pendingSeq;
        bool pendingOpen;
        uint8 pendingTries;
        uint256 cronTopic;
        uint32 runwayDays;
    }

    function status() external view returns (Status memory) {
        return Status(
            phase,
            lastSeen,
            lastChain,
            lastOriginTx,
            deadline(),
            graceEndsAt,
            refusedTotal,
            brakedCount,
            pending.seq,
            pending.open,
            pending.tries,
            cronTopic,
            runwayDays()
        );
    }
}

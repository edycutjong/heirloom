// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {HeirloomTypes, IHeirloomVault} from "./HeirloomTypes.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @title HeirloomVault
/// @notice Holds a small estate on Base. The owner can withdraw at any time; the heir can claim only after the
///         reactive contract on Reactive Network has seen the owner silent for T + grace, and only in two steps
///         separated by `claimDelay`. Any owner action resets the vault to ARMED and is visible to the reactive
///         contract as `OwnerActive`, an unspoofable proof of life.
/// @dev `sync` is the ONLY callback. Both guards are required (docs: "use both, always"): the caller must be the
///      callback proxy, and the injected first argument must equal `callbackSender` (measured on Day 1: the
///      requesting reactive contract). No callback ever moves funds.
contract HeirloomVault is AbstractCallback, IHeirloomVault {
    uint256 public constant MAX_TOKENS = 8;
    uint64 public constant MIN_CLAIM_DELAY = 60; // the two-step claim must be two steps

    address public immutable owner;
    address public immutable rc; // informational; authorization uses _CALLBACK_SENDER
    uint64 public immutable claimDelay;
    uint256 public immutable depositCap; // per estate token

    address public heir;
    address public payoutTo; // heir's redirect target (0 = heir)
    HeirloomTypes.VaultState public state;

    uint64 public ownerNonce;
    bytes32 public ownerActionId;
    uint64 public lastAppliedSeq;
    uint64 public graceEndsAt;
    uint64 public claimReadyAt;

    // mirrors from the latest applied snapshot (cheap reads for the status page)
    uint64 public lastSeenMirror;
    uint256 public lastChainMirror;
    bytes32 public lastOriginTxMirror;
    uint32 public runwayDays;

    address[] public estateTokens;
    mapping(address => bool) public isEstateToken;
    mapping(address => bool) public paid;

    uint256 public allowlistCount;
    mapping(uint256 => mapping(address => bool)) public allowlisted;

    event OwnerActive(HeirloomTypes.OwnerKind indexed kind, uint64 nonce, bytes32 actionId);
    event AllowlistChanged(uint256 indexed chainId, address indexed token, bool on);
    event Ack(uint64 indexed seq, uint64 ownerNonce, bytes32 ownerActionId, bool terminal);
    event StateChanged(HeirloomTypes.VaultState from, HeirloomTypes.VaultState to, uint64 seq);
    event Attested(uint64 indexed seq, uint64 lastSeen, uint256 lastChain, bytes32 originTx, uint32 runwayDays);
    event ClaimInitiated(address indexed by, uint64 readyAt);
    event ClaimCancelled(uint64 seq);
    event Released(address indexed to, address indexed token, uint256 amount);
    event ReleaseFailed(address indexed token);
    event EstateReleased();
    event Retired();
    event PayoutRedirected(address to);
    event HeirChanged(address heir);
    event SyncDeferred(uint64 indexed seq, uint64 graceEndsAt);
    event RetireFailed(address indexed token);
    event Swept(address indexed token, address to, uint256 amount);

    error NotOwner();
    error NotHeir();
    error Terminal();
    error BadState(HeirloomTypes.VaultState state);
    error TooEarly(uint64 readyAt);
    error OverCap(uint256 balance, uint256 cap);
    error TooManyTokens();
    error ZeroAddress();
    error ClaimDelayTooShort();
    error TransferFailed2(address token);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier notTerminal() {
        if (_terminal()) revert Terminal();
        _;
    }

    /// @param proxy_ the destination callback proxy on this chain
    /// @param callbackSender_ the identity the proxy injects as the first argument (measured: the reactive contract)
    /// @param owner_ distinct from the deployer, so an everyday wallet can own the vault
    /// @param chainIds_ / tokens_ the initial allowlist, mirrored from the reactive contract's `setVault`
    constructor(
        address proxy_,
        address callbackSender_,
        address owner_,
        address heir_,
        uint64 claimDelay_,
        uint256 depositCap_,
        uint256[] memory chainIds_,
        address[] memory tokens_
    ) payable AbstractCallback(IPayable(payable(proxy_)), callbackSender_) {
        if (owner_ == address(0) || heir_ == address(0) || callbackSender_ == address(0)) revert ZeroAddress();
        if (claimDelay_ < MIN_CLAIM_DELAY) revert ClaimDelayTooShort();
        owner = owner_;
        heir = heir_;
        rc = callbackSender_;
        claimDelay = claimDelay_;
        depositCap = depositCap_;
        if (chainIds_.length != tokens_.length || tokens_.length > MAX_TOKENS) revert TooManyTokens();
        for (uint256 i; i < tokens_.length; i++) {
            if (!allowlisted[chainIds_[i]][tokens_[i]]) {
                allowlisted[chainIds_[i]][tokens_[i]] = true;
                allowlistCount++;
            }
        }
        // version (0, 0) until the first owner action: matches the reactive contract's initial view
    }

    // ------------------------------------------------------------------ owner actions (each = proof of life)

    function deposit(address token, uint256 amount) external onlyOwner notTerminal {
        if (!isEstateToken[token]) {
            if (estateTokens.length >= MAX_TOKENS) revert TooManyTokens();
            isEstateToken[token] = true;
            estateTokens.push(token);
        }
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 bal = IERC20Min(token).balanceOf(address(this));
        if (bal > depositCap) revert OverCap(bal, depositCap);
        _ownerAction(HeirloomTypes.OwnerKind.DEPOSIT, abi.encode(token, amount));
    }

    /// @notice Withdraw an estate token (or native gas reserve with token = 0) at any time before release.
    function withdraw(address token, uint256 amount) external onlyOwner notTerminal {
        _send(token, owner, amount);
        _ownerAction(HeirloomTypes.OwnerKind.WITHDRAW, abi.encode(token, amount));
    }

    function ping() external onlyOwner notTerminal {
        _ownerAction(HeirloomTypes.OwnerKind.PING, "");
    }

    function setHeir(address heir_) external onlyOwner notTerminal {
        if (heir_ == address(0)) revert ZeroAddress();
        heir = heir_;
        payoutTo = address(0);
        emit HeirChanged(heir_);
        _ownerAction(HeirloomTypes.OwnerKind.SET_HEIR, abi.encode(heir_));
    }

    /// @notice Add or remove a watched (chain, token). The reactive contract subscribes/unsubscribes on this event.
    function setAllowlist(uint256 chainId, address token, bool on) external onlyOwner notTerminal {
        if (allowlisted[chainId][token] != on) {
            if (on) {
                if (allowlistCount >= MAX_TOKENS) revert TooManyTokens();
                allowlistCount++;
            } else {
                allowlistCount--;
            }
            allowlisted[chainId][token] = on;
        }
        emit AllowlistChanged(chainId, token, on);
        _ownerAction(HeirloomTypes.OwnerKind.ALLOWLIST, abi.encode(chainId, token, on));
    }

    /// @notice Withdraw everything and end the instance. Emits ONLY `Retired()`; the reactive contract tears down.
    function retire() external onlyOwner notTerminal {
        _setState(HeirloomTypes.VaultState.RETIRED, lastAppliedSeq);
        for (uint256 i; i < estateTokens.length; i++) {
            address t = estateTokens[i];
            (bool okB, bytes memory b) = t.staticcall(abi.encodeCall(IERC20Min.balanceOf, (address(this))));
            uint256 bal = okB && b.length >= 32 ? abi.decode(b, (uint256)) : 0;
            if (bal == 0) continue;
            (bool ok, bytes memory ret) = t.call(abi.encodeCall(IERC20Min.transfer, (owner, bal)));
            // a paused/blacklisted token must not block retirement (the RC would keep billing CRON)
            if (!ok || (ret.length != 0 && (ret.length < 32 || !abi.decode(ret, (bool))))) emit RetireFailed(t);
        }
        if (address(this).balance > 0) {
            (bool okN,) = payable(owner).call{value: address(this).balance}("");
            if (!okN) emit RetireFailed(address(0));
        }
        emit Retired();
    }

    // ------------------------------------------------------------------ the callback

    /// @inheritdoc IHeirloomVault
    function sync(address rvm, HeirloomTypes.Snapshot calldata s)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm)
    {
        if (_terminal()) {
            emit Ack(s.seq, ownerNonce, ownerActionId, true);
            return;
        }
        if (s.seq <= lastAppliedSeq) {
            emit Ack(s.seq, ownerNonce, ownerActionId, false); // replay or stale retry
            return;
        }
        HeirloomTypes.VaultState st0 = state;
        if (
            s.rcPhase == HeirloomTypes.Phase.EXPIRED && block.timestamp < s.graceEndsAt
                && (st0 == HeirloomTypes.VaultState.ARMED || st0 == HeirloomTypes.VaultState.GRACE)
                && s.ownerNonce == ownerNonce && s.ownerActionId == ownerActionId
        ) {
            // Base clock behind the Reactive-computed grace end: do NOT ack, so the RC resends on its next try
            // instead of waiting a whole attest period (keeps I2's bound). Never hastens a transition.
            emit SyncDeferred(s.seq, s.graceEndsAt);
            return;
        }
        lastAppliedSeq = s.seq;
        lastSeenMirror = s.lastSeen;
        lastChainMirror = s.lastChain;
        lastOriginTxMirror = s.originTx;
        runwayDays = s.runwayDays;

        bool current = s.ownerNonce == ownerNonce && s.ownerActionId == ownerActionId;
        HeirloomTypes.VaultState st = state;

        if (s.rcPhase == HeirloomTypes.Phase.ARMED) {
            if (st == HeirloomTypes.VaultState.CLAIM_PENDING) emit ClaimCancelled(s.seq);
            if (st != HeirloomTypes.VaultState.ARMED) _setState(HeirloomTypes.VaultState.ARMED, s.seq);
        } else if (s.rcPhase == HeirloomTypes.Phase.GRACE) {
            if (st == HeirloomTypes.VaultState.GRACE) {
                graceEndsAt = s.graceEndsAt;
            } else if (st == HeirloomTypes.VaultState.CLAIMABLE || st == HeirloomTypes.VaultState.CLAIM_PENDING) {
                // The RC re-enters GRACE only through ARMED, so a newer GRACE snapshot here means it saw life after
                // the expiry this claim rests on and its REVIVE was superseded before landing. Only ever delays.
                if (st == HeirloomTypes.VaultState.CLAIM_PENDING) emit ClaimCancelled(s.seq);
                graceEndsAt = s.graceEndsAt;
                _setState(HeirloomTypes.VaultState.GRACE, s.seq);
            } else if (current && st == HeirloomTypes.VaultState.ARMED) {
                graceEndsAt = s.graceEndsAt;
                _setState(HeirloomTypes.VaultState.GRACE, s.seq);
            }
        } else if (s.rcPhase == HeirloomTypes.Phase.EXPIRED) {
            if (
                current && block.timestamp >= s.graceEndsAt
                    && (st == HeirloomTypes.VaultState.ARMED || st == HeirloomTypes.VaultState.GRACE)
            ) {
                graceEndsAt = s.graceEndsAt;
                _setState(HeirloomTypes.VaultState.CLAIMABLE, s.seq);
            }
        }

        if (s.kind == HeirloomTypes.Kind.ATTEST) {
            emit Attested(s.seq, s.lastSeen, s.lastChain, s.originTx, s.runwayDays);
        }
        emit Ack(s.seq, ownerNonce, ownerActionId, false);
    }

    // ------------------------------------------------------------------ the claim (anyone presses; pays only the heir)

    function initiateClaim() external {
        if (state != HeirloomTypes.VaultState.CLAIMABLE) revert BadState(state);
        claimReadyAt = uint64(block.timestamp) + claimDelay;
        _setState(HeirloomTypes.VaultState.CLAIM_PENDING, lastAppliedSeq);
        emit ClaimInitiated(msg.sender, claimReadyAt);
    }

    function finalizeClaim() external {
        if (state != HeirloomTypes.VaultState.CLAIM_PENDING) revert BadState(state);
        if (block.timestamp < claimReadyAt) revert TooEarly(claimReadyAt);
        _setState(HeirloomTypes.VaultState.RELEASED, lastAppliedSeq);
        emit EstateReleased();
        for (uint256 i; i < estateTokens.length; i++) {
            _release(estateTokens[i]);
        }
    }

    /// @notice Retry a token whose transfer failed at finalize (paused / blacklisted). Anyone may call.
    function finalizeToken(address token) external {
        if (state != HeirloomTypes.VaultState.RELEASED) revert BadState(state);
        if (!isEstateToken[token]) revert ZeroAddress();
        _release(token);
    }

    /// @notice After RELEASED, anything left that is not an unpaid estate token (direct transfers, top-ups after
    ///         payout, the native gas reserve with token = 0) goes to the payee. Anyone may call.
    function sweep(address token) external {
        if (state != HeirloomTypes.VaultState.RELEASED) revert BadState(state);
        if (isEstateToken[token] && !paid[token]) revert BadState(state); // use finalizeToken
        uint256 bal = token == address(0) ? address(this).balance : IERC20Min(token).balanceOf(address(this));
        _send(token, payee(), bal);
        emit Swept(token, payee(), bal);
    }

    /// @notice The heir may redirect the payout (e.g. a blacklisted heir address).
    function redirectPayout(address to) external {
        if (msg.sender != heir) revert NotHeir();
        if (to == address(0)) revert ZeroAddress();
        payoutTo = to;
        emit PayoutRedirected(to);
    }

    // ------------------------------------------------------------------ views

    function claimCanInitiate() external view returns (bool) {
        return state == HeirloomTypes.VaultState.CLAIMABLE;
    }

    function estateTokenCount() external view returns (uint256) {
        return estateTokens.length;
    }

    function payee() public view returns (address) {
        return payoutTo == address(0) ? heir : payoutTo;
    }

    // ------------------------------------------------------------------ internals

    function _terminal() internal view returns (bool) {
        return state == HeirloomTypes.VaultState.RELEASED || state == HeirloomTypes.VaultState.RETIRED;
    }

    function _ownerAction(HeirloomTypes.OwnerKind kind, bytes memory args) internal {
        uint64 n = ++ownerNonce;
        bytes32 id = keccak256(abi.encode(ownerActionId, block.number, block.timestamp, kind, args));
        ownerActionId = id;
        HeirloomTypes.VaultState st = state;
        if (st == HeirloomTypes.VaultState.CLAIM_PENDING) emit ClaimCancelled(lastAppliedSeq);
        if (st != HeirloomTypes.VaultState.ARMED) _setState(HeirloomTypes.VaultState.ARMED, lastAppliedSeq);
        emit OwnerActive(kind, n, id);
    }

    function _setState(HeirloomTypes.VaultState to, uint64 seq) internal {
        emit StateChanged(state, to, seq);
        state = to;
    }

    function _release(address token) internal {
        if (paid[token]) return;
        // Never reverts: one broken token must not block the others (or keep the reactive contract alive).
        (bool okB, bytes memory b) = token.staticcall(abi.encodeCall(IERC20Min.balanceOf, (address(this))));
        if (!okB || b.length < 32) {
            emit ReleaseFailed(token);
            return;
        }
        uint256 bal = abi.decode(b, (uint256));
        address to = payee();
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Min.transfer, (to, bal)));
        if (ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))))) {
            paid[token] = true;
            emit Released(to, token, bal);
        } else {
            emit ReleaseFailed(token);
        }
    }

    function _send(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool okN,) = payable(to).call{value: amount}("");
            if (!okN) revert TransferFailed2(token);
            return;
        }
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Min.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed2(token);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Min.transferFrom, (from, to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed2(token);
    }
}

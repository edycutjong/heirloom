// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {CallbackResult} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";
import {OmniReactiveTest} from "reactive-kit/test/OmniReactiveTest.sol";
import {CronTopics} from "reactive-kit/CronTopics.sol";
import {CallbackFailureWatch} from "reactive-kit/CallbackFailureWatch.sol";
import {HeirloomReactive} from "../src/HeirloomReactive.sol";
import {HeirloomVault} from "../src/HeirloomVault.sol";
import {HeirloomTypes} from "../src/HeirloomTypes.sol";

/// Minimal ERC-20 (Transfer from = owner is the heartbeat; zero-value transferFrom is the spoof surface, as on
/// Circle USDC, measured Day 1). `paused` makes transfers revert (release-failure path).
contract TestToken {
    mapping(address => uint256) public balanceOf;
    bool public paused;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        return _move(msg.sender, to, v);
    }

    /// No allowance check on purpose: a zero-value transferFrom(owner, x, 0) must succeed for ANYONE (the spoof).
    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        return _move(from, to, v);
    }

    function _move(address from, address to, uint256 v) internal returns (bool) {
        require(!paused, "paused");
        balanceOf[from] -= v;
        balanceOf[to] += v;
        emit Transfer(from, to, v);
        return true;
    }
}

/// Chainlink-style aggregator: only the event shape matters to the canary.
contract TestAggregator {
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    uint256 public round;

    function beat() external {
        emit AnswerUpdated(int256(2000e8), ++round, block.timestamp);
    }
}

abstract contract HeirloomBase is OmniReactiveTest {
    uint256 internal constant BASE = 84532;
    uint256 internal constant ETH = 11155111;
    uint256 internal constant UNI = 1301;
    uint64 internal constant T0 = 1_000_000;

    // demo-tier constants (architecture.md: demo 10 min / 5 min / 3 min / 5 min, ackTimeout 30 s, Cron10 ~ 11 s)
    uint64 internal constant T_ = 600;
    uint64 internal constant GRACE = 300;
    uint64 internal constant FREEZE = 180;
    uint64 internal constant ATTEST = 300;
    uint64 internal constant ACK = 30;
    uint64 internal constant TICK = 11;
    uint64 internal constant BRAKE_WINDOW = 600;
    uint32 internal constant MAX_REFUSED = 20;
    uint64 internal constant CLAIM_DELAY = 180;
    uint256 internal constant CAP = 5_000_000; // 5 USDC (6 decimals)

    address internal owner = makeAddr("owner");
    address internal heir = makeAddr("heir");
    address internal stranger = makeAddr("stranger");

    TestToken internal usdcBase;
    TestToken internal usdcEth;
    TestToken internal usdcUni;
    TestToken internal fakeToken;
    TestAggregator internal agg;
    HeirloomReactive internal rc;
    HeirloomVault internal vault;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(T0);
        usdcBase = new TestToken();
        usdcEth = new TestToken();
        usdcUni = new TestToken();
        fakeToken = new TestToken();
        agg = new TestAggregator();
        onChain(address(usdcBase), BASE);
        onChain(address(usdcEth), ETH);
        onChain(address(usdcUni), UNI);
        onChain(address(fakeToken), BASE);
        onChain(address(agg), BASE);
        usdcBase.mint(owner, 100e6);
        usdcEth.mint(owner, 100e6);
        usdcUni.mint(owner, 100e6);
    }

    function _cfg() internal view virtual returns (HeirloomReactive.Config memory c) {
        c = HeirloomReactive.Config({
            T: T_,
            grace: GRACE,
            freezeCap: FREEZE,
            attestEvery: ATTEST,
            ackTimeout: ACK,
            tickPeriod: TICK,
            brakeWindow: BRAKE_WINDOW,
            maxRefusedPerWindow: MAX_REFUSED,
            cronTopic: CronTopics.CRON10,
            graceCronTopic: 0,
            destChainId: BASE,
            callbackProxy: address(proxy)
        });
    }

    /// @param canaryGap 0 = no canary entry
    function _deploy(HeirloomReactive.Config memory c, uint64 canaryGap) internal {
        rc = new HeirloomReactive{value: 10 ether}(owner, c);
        HeirloomReactive.TokenRef[] memory refs = new HeirloomReactive.TokenRef[](3);
        refs[0] = HeirloomReactive.TokenRef(BASE, address(usdcBase));
        refs[1] = HeirloomReactive.TokenRef(ETH, address(usdcEth));
        refs[2] = HeirloomReactive.TokenRef(UNI, address(usdcUni));
        uint256[] memory chains = new uint256[](3);
        address[] memory toks = new address[](3);
        for (uint256 i; i < 3; i++) {
            chains[i] = refs[i].chainId;
            toks[i] = refs[i].token;
        }
        vault = new HeirloomVault{value: 1 ether}(address(proxy), address(rc), owner, heir, CLAIM_DELAY, CAP, chains, toks);
        onChain(address(vault), BASE);
        onChain(address(proxy), BASE);
        HeirloomReactive.CanaryInit[] memory cans = new HeirloomReactive.CanaryInit[](canaryGap == 0 ? 0 : 1);
        if (canaryGap != 0) cans[0] = HeirloomReactive.CanaryInit(BASE, address(agg), canaryGap);
        rc.setVault(address(vault), refs, cans);
    }

    function _deployDefault() internal {
        _deploy(_cfg(), 0);
    }

    // ------------------------------------------------------------------ actions

    function heartbeat(TestToken tok, uint256 v) internal returns (CallbackResult[] memory) {
        return cycle(owner, address(tok), abi.encodeCall(TestToken.transfer, (stranger, v)));
    }

    /// A stranger's zero-value transferFrom(owner -> stranger, 0): Transfer(from = owner, value 0).
    function spoof(TestToken tok) internal returns (CallbackResult[] memory) {
        return cycle(stranger, address(tok), abi.encodeCall(TestToken.transferFrom, (owner, stranger, 0)));
    }

    /// A canary heartbeat (third-party feed update), delivered to the RC.
    function beat() internal returns (CallbackResult[] memory) {
        return cycle(stranger, address(agg), abi.encodeCall(TestAggregator.beat, ()));
    }

    function ownerCall(bytes memory data) internal returns (CallbackResult[] memory) {
        return cycle(owner, address(vault), data);
    }

    function tickAt(uint256 ts) internal returns (CallbackResult[] memory) {
        vm.warp(ts);
        return cron(CronTopics.CRON10);
    }

    /// Advance to `ts` with CRON10 ticks every TICK seconds (callbacks + Acks settle each tick).
    function runUntil(uint256 ts) internal {
        while (block.timestamp + TICK <= ts) {
            tickAt(block.timestamp + TICK);
        }
    }

    function deliverAs(IReactive.LogRecord memory l) internal {
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
    }

    function failureLog(uint64 seq) internal view returns (IReactive.LogRecord memory l) {
        HeirloomTypes.Snapshot memory s;
        s.seq = seq;
        bytes memory payload = abi.encodeCall(HeirloomVault.sync, (address(rc), s));
        l.chainId = BASE;
        l.contractAddress = address(proxy);
        l.topic0 = CallbackFailureWatch.TOPIC;
        l.topic1 = uint256(uint160(address(vault)));
        l.data = abi.encode(payload);
        l.opCode = 2;
        l.txHash = uint256(keccak256(abi.encode("fail", seq, block.timestamp)));
    }

    // ------------------------------------------------------------------ assertions

    function assertPhase(HeirloomTypes.Phase p) internal view {
        assertEq(uint8(rc.phase()), uint8(p), "rc phase");
    }

    function assertVault(HeirloomTypes.VaultState s) internal view {
        assertEq(uint8(vault.state()), uint8(s), "vault state");
    }

    function _pendingOpen() internal view returns (bool open) {
        (,,, open,) = rc.pending();
    }

    function _pendingTries() internal view returns (uint8 tries) {
        (,, tries,,) = rc.pending();
    }

    function _pendingSeq() internal view returns (uint64 seq) {
        (seq,,,,) = rc.pending();
    }

    /// Drive an instance from `now` to CLAIMABLE through real ticks.
    function toClaimable() internal {
        runUntil(rc.deadline() + TICK);
        assertPhase(HeirloomTypes.Phase.GRACE);
        runUntil(rc.graceEndsAt() + TICK);
        assertPhase(HeirloomTypes.Phase.EXPIRED);
        assertVault(HeirloomTypes.VaultState.CLAIMABLE);
    }
}

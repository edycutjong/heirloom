// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @title ProbeCallback
/// @notice Day-1 spike destination on Base Sepolia. Records the address the callback proxy injects as the first
///         argument (the identity Heirloom's vault must later pin as `callbackSender`).
/// @dev Deliberately guarded by `onlyServiceProvider` only: the injected identity is what is being measured, so it
///      cannot be checked yet. Production callbacks use BOTH guards. `failNext` makes one callback revert so the
///      proxy's CallbackFailure event can be observed on chain.
contract ProbeCallback is AbstractCallback {
    address public immutable owner;
    bool public failNext;
    uint256 public pings;
    address public lastRvm;

    event Pinged(
        address indexed rvm, uint256 indexed seq, uint256 originChainId, uint256 originTx, uint256 receivedAt
    );

    error NotOwner();
    error ProbeFail(uint256 seq);

    constructor(address callbackProxy_) payable AbstractCallback(IPayable(payable(callbackProxy_)), address(0)) {
        owner = msg.sender;
    }

    function setFailNext(bool v) external {
        if (msg.sender != owner) revert NotOwner();
        failNext = v;
    }

    function ping(address rvm, uint256 seq, uint256 originChainId, uint256 originTx) external onlyServiceProvider {
        if (failNext) {
            failNext = false;
            revert ProbeFail(seq);
        }
        pings++;
        lastRvm = rvm;
        emit Pinged(rvm, seq, originChainId, originTx, block.timestamp);
    }

    function drain() external {
        if (msg.sender != owner) revert NotOwner();
        (bool ok,) = payable(owner).call{value: address(this).balance}("");
        require(ok, "drain");
    }
}

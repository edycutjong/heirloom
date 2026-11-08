// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Shared vocabulary of the reactive contract (Reactive Network) and the vault (Base).
library HeirloomTypes {
    /// Evidence label of a `sync` snapshot. The vault acts on `rcPhase` + its own state, never on `kind`.
    enum Kind {
        ATTEST,
        GRACE,
        CANCEL,
        EXPIRE,
        REVIVE
    }

    /// The reactive contract's view. DONE = torn down (every subscription removed).
    enum Phase {
        ARMED,
        GRACE,
        EXPIRED,
        DONE
    }

    /// Release state machine on the vault. RELEASED and RETIRED are terminal.
    enum VaultState {
        ARMED,
        GRACE,
        CLAIMABLE,
        CLAIM_PENDING,
        RELEASED,
        RETIRED
    }

    /// Owner action recorded in `OwnerActive(kind, nonce, actionId)`.
    enum OwnerKind {
        DEPOSIT,
        WITHDRAW,
        PING,
        SET_HEIR,
        ALLOWLIST
    }

    /// One full-state snapshot. Every snapshot is complete, so a newer `seq` supersedes a lost older one.
    struct Snapshot {
        uint64 seq;
        Kind kind;
        Phase rcPhase;
        uint64 ownerNonce; // the vault owner-action version the RC last ingested
        bytes32 ownerActionId;
        uint64 lastSeen; // Reactive time of the latest accepted proof of life
        uint256 lastChain;
        bytes32 originTx;
        uint64 graceEndsAt;
        uint32 runwayDays;
    }
}

/// @notice The vault's callback surface, as the reactive contract encodes it.
interface IHeirloomVault {
    /// @param rvm placeholder; the callback proxy overwrites it with the requesting reactive contract.
    function sync(address rvm, HeirloomTypes.Snapshot calldata s) external;
}

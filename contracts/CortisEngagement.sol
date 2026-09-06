// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Minimal interface into CortisPassport for ownership checks on attestations.
interface ICortisPassport {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @title CortisEngagement
 * @notice On-chain engagement layer for Cortis (personal AI operator product).
 *         Tracks wallet-scoped daily check-ins (the DAU driver) and per-agent
 *         attestations of "Map" and "Workflow" results.
 *
 * @dev    Pre-TGE this contract is GAS-ONLY. There is no token, no fee, no stake.
 *         Sybil resistance = gas cost + bound on-chain identity (passport) only.
 *
 *         TGE-ADDITIVE DESIGN: a settable `corToken` address (default address(0))
 *         is reserved so that post-TGE fee / stake / reward hooks can attach here
 *         WITHOUT redeploying this core contract. No token logic is implemented now.
 */
contract CortisEngagement is Ownable {
    // ─────────────────────────────────────────────────────────────────────
    // Config
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Minimum spacing between check-ins (rolling 24h window).
    uint256 public constant CHECK_IN_INTERVAL = 24 hours;

    /// @notice If the gap since the last check-in exceeds this, the streak resets.
    uint256 public constant STREAK_RESET_GAP = 48 hours;

    /// @notice Points awarded for a check-in.
    uint256 public checkInPoints = 10;

    /// @notice Additional points per consecutive-day streak (streak * streakBonus).
    uint256 public streakBonus = 2;

    /// @notice Points awarded for attesting a map result.
    uint256 public attestMapPoints = 5;

    /// @notice Points awarded for attesting a workflow result.
    uint256 public attestWorkflowPoints = 5;

    /// @notice Passport contract used for per-agent ownership checks (settable).
    ICortisPassport public passport;

    /// @notice Reserved for TGE. Default address(0). Post-TGE fee/stake hooks attach
    ///         here without redeploying this contract. Not used pre-TGE.
    address public corToken;

    // ─────────────────────────────────────────────────────────────────────
    // Per-wallet state
    // ─────────────────────────────────────────────────────────────────────

    mapping(address => uint256) public points;
    mapping(address => uint256) public streak;
    mapping(address => uint256) public lastCheckIn;
    mapping(address => uint256) public totalCheckIns;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event CheckedIn(address indexed user, uint256 streak, uint256 totalCheckIns, uint256 points);
    event MapAttested(address indexed user, uint256 indexed passportId, bytes32 mapHash, uint256 ts);
    event WorkflowAttested(address indexed user, uint256 indexed passportId, bytes32 workflowHash, uint256 ts);
    event PointsConfigUpdated(uint256 checkInPoints, uint256 streakBonus, uint256 attestMapPoints, uint256 attestWorkflowPoints);
    event PassportUpdated(address indexed passport);
    event CorTokenUpdated(address indexed corToken);

    // ─────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Check-in attempted before the 24h window elapsed.
    error CheckInTooSoon(uint256 nextAllowed);

    /// @dev Attestation references a passport not owned by the caller.
    error NotAgentOwner();

    /// @dev Attestation attempted before a passport contract has been configured.
    error PassportNotSet();

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────────────────────────────
    // Check-in (wallet-scoped, once per rolling 24h) — the DAU driver
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Daily check-in. No passport required. First call always allowed.
     * @dev    Enforces a rolling 24h window. Streak increments if the previous
     *         check-in was within STREAK_RESET_GAP, otherwise it resets to 1.
     */
    function checkIn() external {
        uint256 last = lastCheckIn[msg.sender];

        if (last != 0) {
            uint256 nextAllowed = last + CHECK_IN_INTERVAL;
            if (block.timestamp < nextAllowed) revert CheckInTooSoon(nextAllowed);
        }

        // Streak logic: continue if within reset gap, else reset.
        uint256 newStreak;
        if (last != 0 && block.timestamp <= last + STREAK_RESET_GAP) {
            newStreak = streak[msg.sender] + 1;
        } else {
            newStreak = 1;
        }

        streak[msg.sender] = newStreak;
        lastCheckIn[msg.sender] = block.timestamp;
        totalCheckIns[msg.sender] += 1;

        uint256 gained = checkInPoints + (newStreak * streakBonus);
        points[msg.sender] += gained;

        emit CheckedIn(msg.sender, newStreak, totalCheckIns[msg.sender], points[msg.sender]);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Attestations (per-agent / per-passport, unlimited per day)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Attest a "Map me" result on-chain for one of your agents.
     * @param passportId The passport (agent) this map belongs to. Must be owned by caller.
     * @param mapHash    keccak256 hash of the generated map JSON.
     */
    function attestMap(uint256 passportId, bytes32 mapHash) external {
        _requireAgentOwner(passportId);
        points[msg.sender] += attestMapPoints;
        emit MapAttested(msg.sender, passportId, mapHash, block.timestamp);
    }

    /**
     * @notice Attest a "Generate workflow" result on-chain for one of your agents.
     * @param passportId   The passport (agent) this workflow belongs to. Must be owned by caller.
     * @param workflowHash keccak256 hash of the generated workflow definition.
     */
    function attestWorkflow(uint256 passportId, bytes32 workflowHash) external {
        _requireAgentOwner(passportId);
        points[msg.sender] += attestWorkflowPoints;
        emit WorkflowAttested(msg.sender, passportId, workflowHash, block.timestamp);
    }

    /// @dev Reverts unless a passport contract is set and the caller owns `passportId`.
    function _requireAgentOwner(uint256 passportId) internal view {
        if (address(passport) == address(0)) revert PassportNotSet();
        if (passport.ownerOf(passportId) != msg.sender) revert NotAgentOwner();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Seconds until the caller (or `user`) may check in again; 0 if ready now.
    function timeUntilNextCheckIn(address user) external view returns (uint256) {
        uint256 last = lastCheckIn[user];
        if (last == 0) return 0;
        uint256 nextAllowed = last + CHECK_IN_INTERVAL;
        if (block.timestamp >= nextAllowed) return 0;
        return nextAllowed - block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner config
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Owner-settable point values for all engagement actions.
    function setPoints(
        uint256 _checkInPoints,
        uint256 _streakBonus,
        uint256 _attestMapPoints,
        uint256 _attestWorkflowPoints
    ) external onlyOwner {
        checkInPoints = _checkInPoints;
        streakBonus = _streakBonus;
        attestMapPoints = _attestMapPoints;
        attestWorkflowPoints = _attestWorkflowPoints;
        emit PointsConfigUpdated(_checkInPoints, _streakBonus, _attestMapPoints, _attestWorkflowPoints);
    }

    /// @notice Wire the passport contract used for attestation ownership checks.
    function setPassport(address _passport) external onlyOwner {
        passport = ICortisPassport(_passport);
        emit PassportUpdated(_passport);
    }

    /// @notice Reserved for TGE. Sets the $COR token address for future fee/stake hooks.
    /// @dev    No token logic is executed pre-TGE; this only stores the address.
    function setCorToken(address _corToken) external onlyOwner {
        corToken = _corToken;
        emit CorTokenUpdated(_corToken);
    }
}

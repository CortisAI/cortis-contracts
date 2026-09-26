// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Security revision: see audit/SECURITY_REVIEW.md and audit/INTEGRATION.md.

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IAgentPassport} from "./interfaces/ICortis.sol";

/**
 * @title CortisEngagement
 * @notice The immutable engagement core. Wallet daily check-in (the growth /
 *         airdrop scoreboard) plus per-agent activity records.
 *
 * @dev This is the simplified proof-free model. There is NO attestor, NO
 *      attested-run award, NO boost, and NO points-spending path. On-chain
 *      points are a public, monotonically increasing engagement score; the
 *      real reward eligibility is decided off-chain from the event history and
 *      wallet snapshot. Because nothing on-chain gates token value, points are
 *      intentionally farmable and carry no Sybil claim — filtering happens off
 *      chain.
 *
 *      The wallet daily check-in payout is NOT flat. It follows an accelerating
 *      streak curve (award = CHECKIN_LIN_COEFF*streak + CHECKIN_QUAD_COEFF*
 *      streak^2, capped at CHECKIN_MAX_AWARD): a gentle start that rewards
 *      long-term daily users
 *      with rapidly growing payouts. Any gap of more than one day resets the
 *      streak to 1, so the curve has teeth.
 *
 *      This contract computes no composite score and is never placed behind a
 *      proxy. If it is ever defective the answer is a new deployment plus an
 *      audited state import, not an upgrade that can silently rewrite history.
 */
contract CortisEngagement is AccessControl, Pausable {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // --------------------------------------------------------------- points
    /// @dev Per-agent relationship heartbeat. Flat +1, kept minimal.
    uint64 public constant CHECKIN_POINTS = 1;

    // ----------------------------------------------------- wallet check-in curve
    //
    // The wallet-scoped daily check-in is the free, farmable growth loop and the
    // primary DAU driver. Its payout accelerates with the consecutive-day
    // streak: award = CHECKIN_LIN_COEFF*streak + CHECKIN_QUAD_COEFF*streak^2,
    // capped at CHECKIN_MAX_AWARD.
    //
    //   day 1  -> 25        day 30 -> 2,490
    //   day 7  -> 259       day 45 -> 5,085
    //   day 14 -> 714       day 60 -> 8,580
    //   day 21 -> 1,365     day 66 -> 10,000 (cap)
    //
    // Any gap of more than one day resets the streak to 1. This is not Sybil
    // resistance: automated farms can check in many wallets at low opBNB gas.
    // Reward eligibility is decided off-chain.
    uint64 public constant CHECKIN_LIN_COEFF = 23;
    uint64 public constant CHECKIN_QUAD_COEFF = 2;
    uint64 public constant CHECKIN_MAX_AWARD = 10_000;

    IAgentPassport public immutable PASSPORT;

    /// @dev Per-agent relationship state (packed).
    struct AgentState {
        uint32 lastCheckInDay;
        bool everCheckedIn;
        uint16 currentStreak;
        uint16 bestStreak;
        uint32 checkInCount;
        uint64 points;
        uint64 mapCount;
        uint64 workflowCount;
    }

    /// @dev Wallet-scoped daily check-in state (packed). No passport required.
    struct WalletState {
        uint32 lastCheckInDay;
        bool everCheckedIn;
        uint16 currentStreak;
        uint16 bestStreak;
        uint32 checkInCount;
        uint64 points;
        uint32 mapCount;
        uint32 workflowCount;
        uint32 deployCount;
    }

    mapping(address account => WalletState) private _wallets;
    mapping(uint256 agentId => AgentState) private _agents;

    event CheckedIn(
        uint256 indexed agentId,
        address indexed ownerAccount,
        uint32 indexed day,
        uint16 currentStreak,
        uint32 checkInCount,
        uint64 points
    );

    /// @notice Wallet-scoped daily check-in (no passport). The DAU driver.
    /// @param awarded points minted by this specific check-in (curve of streak).
    event WalletCheckedIn(
        address indexed account,
        uint32 indexed day,
        uint16 currentStreak,
        uint32 checkInCount,
        uint64 points,
        uint64 awarded
    );

    event WalletMapped(address indexed account, uint32 mapCount, uint64 points);
    event WalletWorkflowGenerated(address indexed account, bytes32 indexed workflowIdHash, uint32 workflowCount, uint64 points);
    event WalletAgentDeployed(address indexed account, uint32 deployCount, uint64 points);

    event Mapped(uint256 indexed agentId, address indexed ownerAccount, uint64 mapCount, uint64 points);
    event WorkflowGenerated(
        uint256 indexed agentId,
        address indexed ownerAccount,
        bytes32 indexed workflowIdHash,
        uint64 workflowCount,
        uint64 points
    );

    error PassportInactive(uint256 agentId);
    error NotPassportOwner(uint256 agentId, address caller);
    error AgentAlreadyCheckedInToday(uint256 agentId, uint32 day);
    error WalletAlreadyCheckedInToday(address account, uint32 day);
    error InvalidConfiguration();
    error InvalidAgentId(uint256 agentId);

    constructor(address admin, address guardian, address passport) {
        if (admin == address(0) || guardian == address(0) || passport.code.length == 0) {
            revert InvalidConfiguration();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        PASSPORT = IAgentPassport(passport);
    }

    // --------------------------------------------------------------- check-in

    /**
     * @notice Wallet-scoped daily check-in. One call per caller wallet per UTC
     *         day, no passport required, opBNB gas only. The top-level DAU
     *         action: a user can check in from tap one before minting any agent.
     * @dev Payout accelerates with the consecutive-day streak:
     *      award = CHECKIN_LIN_COEFF*streak + CHECKIN_QUAD_COEFF*streak^2,
     *      capped at CHECKIN_MAX_AWARD. A gap of more than one day resets to 1.
     */
    function checkIn() external whenNotPaused {
        uint32 today = uint32(block.timestamp / 1 days);
        WalletState storage w = _wallets[msg.sender];

        if (w.everCheckedIn && w.lastCheckInDay == today) revert WalletAlreadyCheckedInToday(msg.sender, today);

        bool consecutive = w.everCheckedIn && w.lastCheckInDay + 1 == today;

        w.everCheckedIn = true;
        w.currentStreak = consecutive ? _nextStreak(w.currentStreak) : 1;
        if (w.currentStreak > w.bestStreak) w.bestStreak = w.currentStreak;
        w.lastCheckInDay = today;

        uint64 awarded = _checkInAward(w.currentStreak);

        w.checkInCount += 1;
        w.points += awarded;

        emit WalletCheckedIn(msg.sender, today, w.currentStreak, w.checkInCount, w.points, awarded);
    }

    /**
     * @notice Wallet-scoped Map Me generation. No passport; unlimited; no points.
     */
    function mapMe() external whenNotPaused {
        WalletState storage w = _wallets[msg.sender];
        w.mapCount += 1;
        emit WalletMapped(msg.sender, w.mapCount, w.points);
    }

    /**
     * @notice Wallet-scoped workflow generation. No passport; unlimited; no points.
     */
    function generateWorkflow() external whenNotPaused {
        WalletState storage w = _wallets[msg.sender];
        w.workflowCount += 1;
        emit WalletWorkflowGenerated(msg.sender, bytes32(0), w.workflowCount, w.points);
    }

    /**
     * @notice Wallet-scoped agent deployment record. No passport; unlimited; no points.
     */
    function deployAgent() external whenNotPaused {
        WalletState storage w = _wallets[msg.sender];
        w.deployCount += 1;
        emit WalletAgentDeployed(msg.sender, w.deployCount, w.points);
    }

    /**
     * @notice Record that this owner-agent relationship was active today.
     * @dev One check-in per active passport per UTC day. Flat +1.
     */
    function checkIn(uint256 agentId) external whenNotPaused {
        _requireActiveOwnedPassport(agentId);

        uint32 today = uint32(block.timestamp / 1 days);
        AgentState storage a = _agents[agentId];

        if (a.everCheckedIn && a.lastCheckInDay == today) revert AgentAlreadyCheckedInToday(agentId, today);

        bool consecutive = a.everCheckedIn && a.lastCheckInDay + 1 == today;
        a.everCheckedIn = true;
        a.currentStreak = consecutive ? _nextStreak(a.currentStreak) : 1;
        if (a.currentStreak > a.bestStreak) a.bestStreak = a.currentStreak;
        a.lastCheckInDay = today;

        a.checkInCount += 1;
        a.points += CHECKIN_POINTS;

        emit CheckedIn(agentId, msg.sender, today, a.currentStreak, a.checkInCount, a.points);
    }

    // ----------------------------------------------------------- engagement

    /**
     * @notice Record a Map Me knowledge-map generation for this agent.
     * @dev Owner-gated, unlimited, awards no points. Self-attested UI telemetry.
     */
    function mapMe(uint256 agentId) external whenNotPaused {
        _requireActiveOwnedPassport(agentId);
        AgentState storage a = _agents[agentId];
        a.mapCount += 1;
        emit Mapped(agentId, msg.sender, a.mapCount, a.points);
    }

    /**
     * @notice Record a workflow generation for this agent.
     * @dev workflowIdHash may be zero for an ad hoc build; carried in the event
     *      only. Awards no points.
     */
    function generateWorkflow(uint256 agentId, bytes32 workflowIdHash) external whenNotPaused {
        _requireActiveOwnedPassport(agentId);
        AgentState storage a = _agents[agentId];
        a.workflowCount += 1;
        emit WorkflowGenerated(agentId, msg.sender, workflowIdHash, a.workflowCount, a.points);
    }

    // ----------------------------------------------------------------- admin

    /// @dev Guardian is a circuit breaker, not an operator: it can pause and
    ///      never unpause. Restoring service is an admin decision.
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ views

    function stateOf(uint256 agentId) external view returns (AgentState memory) {
        return _agents[agentId];
    }

    function checkedInToday(uint256 agentId) external view returns (bool) {
        AgentState storage a = _agents[agentId];
        return a.everCheckedIn && a.lastCheckInDay == uint32(block.timestamp / 1 days);
    }

    function walletStateOf(address account) external view returns (WalletState memory) {
        return _wallets[account];
    }

    function walletCheckedInToday(address account) external view returns (bool) {
        WalletState storage w = _wallets[account];
        return w.everCheckedIn && w.lastCheckInDay == uint32(block.timestamp / 1 days);
    }

    /**
     * @notice Preview the award for the next wallet check-in and the streak it
     *         would land on. Not an eligibility flag; pair with
     *         walletCheckedInToday.
     */
    function walletNextCheckInAward(address account) external view returns (uint64 award, uint16 streakAfter) {
        WalletState storage w = _wallets[account];
        uint32 today = uint32(block.timestamp / 1 days);

        if (!w.everCheckedIn) {
            streakAfter = 1;
        } else if (w.lastCheckInDay == today) {
            // Already checked in today; preview tomorrow's consecutive step.
            streakAfter = _nextStreak(w.currentStreak);
        } else if (w.lastCheckInDay + 1 == today) {
            streakAfter = _nextStreak(w.currentStreak);
        } else {
            // A gap resets the streak.
            streakAfter = 1;
        }

        award = _checkInAward(streakAfter);
    }

    // -------------------------------------------------------------- internals

    /// @dev Accelerating streak curve: award = lin*streak + quad*streak^2, capped.
    function _checkInAward(uint16 streak) private pure returns (uint64) {
        uint256 s = uint256(streak);
        uint256 award = uint256(CHECKIN_LIN_COEFF) * s + uint256(CHECKIN_QUAD_COEFF) * s * s;
        if (award > CHECKIN_MAX_AWARD) return CHECKIN_MAX_AWARD;
        return uint64(award);
    }

    function _requireActiveOwnedPassport(uint256 agentId) private view {
        if (agentId == 0 || agentId > type(uint240).max) revert InvalidAgentId(agentId);
        IAgentPassport.Passport memory p = PASSPORT.passportOf(agentId);
        if (p.owner != msg.sender) revert NotPassportOwner(agentId, msg.sender);
        if (!p.active) revert PassportInactive(agentId);
    }

    function _nextStreak(uint16 streak) private pure returns (uint16) {
        return streak == type(uint16).max ? streak : streak + 1;
    }
}

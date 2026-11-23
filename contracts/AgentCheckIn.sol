// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AgentCheck Daily — AgentCheckIn
/// @notice Daily check-in gated by Agent ID. One Agent ID per user (non-transferable
///         ERC-721 on BNB Chain), so one check-in per person per day.
/// @dev Agent ID contract (BSC): 0x60b9262456de011f7d15a54cdd8c48baaa8b022f
///      Holder check: balanceOf(address) > 0.
///      Referral: checkIn(referrer) pays +20 base points to the referrer,
///      ONLY on the invitee's first-ever check-in and only if the referrer
///      holds an Agent ID, has already checked in at least once, is not the
///      invitee themselves, and the invitee has never recorded a referrer.
///      Tier bonus: the referrer's total invite count sets a percentage
///      bonus applied to ALL of their base points (check-in + referral),
///      retroactively — 1-9 invites +0%, 10-19 +20%, 20-49 +30%, 50+ +50%.
///      pointsOf() returns the boosted effective points; totalPoints() is
///      the sum of all users' effective points, so the PrizeDistributor
///      shares prizes by effective points. The invitee's own points are
///      never affected by the referrer's tier. Points are points only —
///      the prize share itself is conditional on the project winning a
///      hackathon prize; nothing is guaranteed.
///      No token, no tax, no mint, no user-fund transfers. This contract never
///      holds or moves user funds. Owner permissions are disclosed below and
///      in contracts/README.md.
/// @custom:owner-permissions
///   - pause() / unpause(): halt check-ins in an emergency (e.g. Agent ID
///     contract migration). Does NOT move funds, does NOT change points.
///   - setAgentIdContract(address): point at a new Agent ID contract ONLY if
///     Binance/SPACE ID migrates the official Agent ID contract. Cannot point
///     at an arbitrary contract to fake holders without it being visible
///     on-chain (event + BscScan verification).
///   - transferOwnership(address): hand ownership to a multisig / new admin.
///   Owner CANNOT: mint points, edit/delete existing points, change past
///   check-ins, change a recorded referrer, withdraw anything (contract holds
///   no funds), or check in on behalf of another user.
/// @dev Ownership is set by an explicit initialOwner constructor argument
///      (NOT msg.sender), so the contract can be deployed through a CREATE2
///      factory — where msg.sender is the factory — and still belong to the
///      intended owner wallet.
interface IAgentId {
    function balanceOf(address account) external view returns (uint256);
}

contract AgentCheckIn {
    // ---- Owner (minimal Ownable, no external imports) ----
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "AgentCheckIn: not owner");
        _;
    }

    /// @param agentIdContract_ The official Agent ID contract (BSC).
    /// @param initialOwner_ The owner wallet. Explicit (not msg.sender) so
    ///        factory deployment still assigns ownership to this address.
    constructor(address agentIdContract_, address initialOwner_) {
        require(agentIdContract_ != address(0), "AgentCheckIn: zero Agent ID address");
        require(initialOwner_ != address(0), "AgentCheckIn: zero owner");
        owner = initialOwner_;
        agentIdContract = agentIdContract_;
        emit OwnershipTransferred(address(0), initialOwner_);
        emit AgentIdContractSet(address(0), agentIdContract_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "AgentCheckIn: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---- Config ----
    address public agentIdContract;
    bool public paused;

    event AgentIdContractSet(address indexed previous, address indexed current);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    modifier whenNotPaused() {
        require(!paused, "AgentCheckIn: paused");
        _;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setAgentIdContract(address newAgentIdContract) external onlyOwner {
        require(newAgentIdContract != address(0), "AgentCheckIn: zero Agent ID address");
        emit AgentIdContractSet(agentIdContract, newAgentIdContract);
        agentIdContract = newAgentIdContract;
    }

    // ---- Points scale (10-point system) ----
    /// @notice Points earned for one daily check-in.
    uint256 public constant CHECKIN_POINTS = 10;
    /// @notice Base bonus points paid to a valid referrer, per referred invitee.
    ///         The referrer's effective points are base * (100 + tierPct) / 100,
    ///         so this +20 itself is also boosted once a tier is reached.
    uint256 public constant REFERRAL_BONUS = 20;

    /// @notice Referral tiers: bonus percentage on the referrer's ALL base
    ///         points (check-in + referral), applied retroactively.
    ///         1-9 invites: +0%; 10-19: +20%; 20-49: +30%; 50+: +50%.
    ///         Example: 22 check-ins (220) + 10 invites (200) = 420 base,
    ///         at the 10-invite tier -> 420 * 120 / 100 = 504 effective.
    ///         50 invites + 22 check-ins = 1220 base -> 1220 * 150 / 100
    ///         = 1830 effective. Integer division rounds down.
    function bonusPctOf(address user) public view returns (uint256) {
        uint256 n = referralCount[user];
        if (n >= 50) return 50;
        if (n >= 20) return 30;
        if (n >= 10) return 20;
        return 0;
    }

    /// @notice Base points of a user (check-in + referral, before tier bonus).
    mapping(address => uint256) private _basePoints;
    /// @notice Effective points of a user (base * (100 + tierPct) / 100),
    ///         kept in sync by _syncPoints so pointsOf()/totalPoints() are
    ///         always consistent without looping over users.
    mapping(address => uint256) private _effectivePoints;

    /// @notice The referrer recorded for an invitee (address(0) = none ever recorded).
    ///         Set at most once, on the invitee's first-ever check-in.
    mapping(address => address) public referredBy;
    /// @notice Number of invitees a referrer has successfully brought in.
    mapping(address => uint256) public referralCount;
    /// @notice Bonus points a referrer has earned from referrals.
    mapping(address => uint256) public referralPoints;

    event ReferralRewarded(
        address indexed referrer,
        address indexed invitee,
        uint256 bonus // base bonus (+20); effective gain may be larger if the
        // referrer's tier rose on this referral (retroactive boost)
    );

    /// @notice Emitted when a referral pushes the referrer into a higher
    ///         bonus tier (e.g. 9 -> 10 invites: 0% -> 20%).
    event ReferralTierChanged(
        address indexed referrer,
        uint256 referralCount,
        uint256 bonusPct
    );

    // ---- State ----
    /// @notice UTC day (block.timestamp / 1 days) of the user's last check-in.
    mapping(address => uint256) public lastCheckInDay;
    mapping(address => uint256) public checkInCount;
    /// @notice Current consecutive-day streak.
    mapping(address => uint256) public currentStreak;

    uint256 public totalPoints;
    uint256 public totalCheckers; // unique addresses that have ever checked in

    event CheckedIn(
        address indexed user,
        uint256 indexed day,
        uint256 points, // user's total points AFTER this check-in
        uint256 totalPoints,
        uint256 streak
    );

    /// @notice Check in for today (UTC day). 10 points per day, Agent ID holders only.
    /// @param referrer The address that invited msg.sender, or address(0) for
    ///        no referral. Only honoured on the invitee's first-ever check-in,
    ///        and only if the referrer holds an Agent ID, has already checked
    ///        in at least once, is not the invitee, and the invitee has never
    ///        recorded a referrer. A valid referral pays REFERRAL_BONUS (20
    ///        base) points to the referrer, on top of the invitee's normal
    ///        +10; the referrer's tier bonus then applies to their whole
    ///        base, so crossing into 10/20/50 invites retroactively boosts
    ///        all of the referrer's earlier points too. On later days the
    ///        parameter is ignored (no repeat bonus).
    function checkIn(address referrer) external whenNotPaused {
        require(
            IAgentId(agentIdContract).balanceOf(msg.sender) > 0,
            "AgentCheckIn: no Agent ID"
        );
        uint256 day = block.timestamp / 1 days;
        require(lastCheckInDay[msg.sender] != day, "AgentCheckIn: already checked in today");

        // Streak: consecutive UTC days continue, a gap resets to 1.
        uint256 streak = 1;
        if (lastCheckInDay[msg.sender] == day - 1) {
            streak = currentStreak[msg.sender] + 1;
        }
        // Note: day == 0 cannot happen on a live chain (timestamp > 0), and
        // day - 1 underflow is impossible for any realistic timestamp.

        bool isFirstEver = (checkInCount[msg.sender] == 0);

        if (isFirstEver) {
            totalCheckers += 1;
        }

        lastCheckInDay[msg.sender] = day;
        currentStreak[msg.sender] = streak;
        checkInCount[msg.sender] += 1;
        _basePoints[msg.sender] += CHECKIN_POINTS;
        _syncPoints(msg.sender);

        emit CheckedIn(msg.sender, day, _effectivePoints[msg.sender], totalPoints, streak);

        // Referral bonus: one-time, first-ever check-in only. All conditions
        // must hold, otherwise the parameter is silently ignored (the
        // check-in itself still succeeds and still earns its normal +10).
        if (
            isFirstEver &&
            referrer != address(0) &&
            referrer != msg.sender &&
            referredBy[msg.sender] == address(0) &&
            IAgentId(agentIdContract).balanceOf(referrer) > 0 &&
            checkInCount[referrer] > 0
        ) {
            referredBy[msg.sender] = referrer;
            uint256 oldPct = bonusPctOf(referrer);
            referralCount[referrer] += 1;
            referralPoints[referrer] += REFERRAL_BONUS;
            _basePoints[referrer] += REFERRAL_BONUS;
            // _syncPoints recomputes the referrer's effective points from
            // the new base and (possibly new) tier, so a tier crossing
            // retroactively boosts ALL of the referrer's earlier base
            // points; totalPoints moves by exactly the effective delta.
            _syncPoints(referrer);
            uint256 newPct = bonusPctOf(referrer);
            if (newPct != oldPct) {
                emit ReferralTierChanged(referrer, referralCount[referrer], newPct);
            }

            emit ReferralRewarded(referrer, msg.sender, REFERRAL_BONUS);
        }
    }

    /// @notice Recompute a user's effective points from base points and
    ///         current tier, adjusting totalPoints by the exact delta so
    ///         totalPoints always equals the sum of all pointsOf() values.
    ///         Called after every base-points change (own check-in or a
    ///         referral reward). Never double-counts: effective points are
    ///         always derived from base, never added on top of old effective.
    function _syncPoints(address user) private {
        uint256 eff = (_basePoints[user] * (100 + bonusPctOf(user))) / 100;
        uint256 old = _effectivePoints[user];
        if (eff >= old) {
            totalPoints += (eff - old);
        } else {
            totalPoints -= (old - eff);
        }
        _effectivePoints[user] = eff;
    }

    // ---- Views ----
    /// @notice Effective points: base * (100 + tierPct) / 100. This is the
    ///         number PrizeDistributor uses for prize shares.
    function pointsOf(address user) external view returns (uint256) {
        return _effectivePoints[user];
    }

    /// @notice Base points before the tier bonus (check-in + referral).
    function basePointsOf(address user) external view returns (uint256) {
        return _basePoints[user];
    }

    function hasCheckedInToday(address user) external view returns (bool) {
        return lastCheckInDay[user] == block.timestamp / 1 days;
    }

    function streakOf(address user) external view returns (uint256) {
        return currentStreak[user];
    }
}

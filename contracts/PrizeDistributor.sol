// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AgentCheck Daily — PrizeDistributor
/// @notice Pull-payment prize distributor. If the project wins a hackathon
///         prize, the owner deposits 50% of it (USDC) into this contract,
///         freezes the points snapshot, and each check-in user calls claim()
///         THEMSELVES to receive userPoints * deposited / totalPointsSnapshot.
///         userPoints here is AgentCheckIn.pointsOf(), i.e. the tier-boosted
///         EFFECTIVE points (base check-in + referral points multiplied by
///         the referrer's tier bonus: 0%/20%/30%/50%); totalPointsSnapshot
///         must equal AgentCheckIn.totalPoints(), the sum of effective points.
///         No auto-transfers, no transfers on behalf of users, no promises:
///         claimable amounts are zero until a prize is actually deposited
///         and claims are enabled.
/// @dev USDC on BSC: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d (18 decimals
///      on BSC — do NOT assume 6 decimals; all math uses raw token amounts).
///      Rounding: integer division rounds down per user; dust stays in the
///      contract and is withdrawable by the owner only after the claim
///      deadline (90 days after claims are enabled).
/// @custom:owner-permissions
///   - Funding is a plain ERC-20 transfer of USDC to this contract (owner
///     sends USDC, no contract function pulls funds).
///   - setSnapshotAndEnable(uint256): freezes totalPointsSnapshot and the
///     deposited amount (read from this contract's USDC balance at that
///     moment), enables claims, starts the 90-day claim window. Callable
///     ONCE — snapshot cannot be changed afterwards.
///   - withdrawUnclaimed(): after the 90-day deadline, owner may withdraw
///     the remaining USDC (unclaimed shares + rounding dust). Before the
///     deadline this reverts. If claims were never enabled, owner may
///     recover deposited USDC at any time (no user has a claim yet).
///   - transferOwnership(address): hand ownership to a multisig / new admin.
///   Owner CANNOT: change any user's points (points are read live from the
///   AgentCheckIn contract), change a user's claimable amount after the
///   snapshot, claim on behalf of a user, or withdraw before the deadline.
/// @dev Ownership is set by an explicit initialOwner constructor argument
///      (NOT msg.sender), so the contract can be deployed through a CREATE2
///      factory — where msg.sender is the factory — and still belong to the
///      intended owner wallet.

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IAgentCheckIn {
    function pointsOf(address user) external view returns (uint256);
}

contract PrizeDistributor {
    // ---- Owner (minimal Ownable, no external imports) ----
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "PrizeDistributor: not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "PrizeDistributor: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---- Config (immutable) ----
    address public immutable usdc;
    address public immutable checkIn;

    uint256 public constant CLAIM_WINDOW = 90 days;

    // ---- State ----
    uint256 public totalDeposited; // raw USDC amount frozen at snapshot time
    uint256 public totalPointsSnapshot; // frozen total check-in points
    bool public claimsEnabled;
    uint256 public claimsEnabledAt;
    uint256 public claimDeadline; // claimsEnabledAt + 90 days, 0 if never enabled

    mapping(address => bool) public claimed;
    mapping(address => uint256) public claimedAmount;

    bool private _locked; // reentrancy guard (no imports)

    modifier nonReentrant() {
        require(!_locked, "PrizeDistributor: reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    event SnapshotEnabled(uint256 totalDeposited, uint256 totalPointsSnapshot, uint256 claimDeadline);
    event Claimed(address indexed user, uint256 indexed points, uint256 amount);
    event UnclaimedWithdrawn(address indexed to, uint256 amount);

    /// @param usdc_ USDC token (BSC).
    /// @param checkIn_ The AgentCheckIn contract to read points from.
    /// @param initialOwner_ The owner wallet. Explicit (not msg.sender) so
    ///        factory deployment still assigns ownership to this address.
    constructor(address usdc_, address checkIn_, address initialOwner_) {
        require(usdc_ != address(0), "PrizeDistributor: zero USDC address");
        require(checkIn_ != address(0), "PrizeDistributor: zero check-in address");
        require(initialOwner_ != address(0), "PrizeDistributor: zero owner");
        owner = initialOwner_;
        usdc = usdc_;
        checkIn = checkIn_;
        emit OwnershipTransferred(address(0), initialOwner_);
    }

    /// @notice Freeze the prize and open claims. Call ONCE, AFTER the owner
    ///         has transferred the full USDC prize share to this contract.
    /// @param totalPointsSnapshot_ Total check-in points at snapshot time
    ///        (must equal AgentCheckIn.totalPoints() at that moment, or a
    ///        lower value if the owner intentionally excludes ineligible
    ///        points — in that case document the reason publicly).
    function setSnapshotAndEnable(uint256 totalPointsSnapshot_) external onlyOwner {
        require(!claimsEnabled, "PrizeDistributor: already enabled");
        require(totalPointsSnapshot_ > 0, "PrizeDistributor: zero snapshot");
        uint256 balance = IERC20Minimal(usdc).balanceOf(address(this));
        require(balance > 0, "PrizeDistributor: no USDC deposited");

        totalDeposited = balance;
        totalPointsSnapshot = totalPointsSnapshot_;
        claimsEnabled = true;
        claimsEnabledAt = block.timestamp;
        claimDeadline = block.timestamp + CLAIM_WINDOW;

        emit SnapshotEnabled(balance, totalPointsSnapshot_, claimDeadline);
    }

    /// @notice Amount this user can claim right now (0 if ineligible / already claimed).
    function claimable(address user) public view returns (uint256) {
        if (!claimsEnabled || claimed[user] || totalPointsSnapshot == 0) return 0;
        uint256 points = IAgentCheckIn(checkIn).pointsOf(user);
        if (points == 0) return 0;
        return (points * totalDeposited) / totalPointsSnapshot;
    }

    /// @notice Claim your prize share. You must call this yourself; nobody
    ///         can claim on your behalf and nothing is sent automatically.
    function claim() external nonReentrant {
        require(claimsEnabled, "PrizeDistributor: claims not enabled");
        require(!claimed[msg.sender], "PrizeDistributor: already claimed");
        uint256 amount = claimable(msg.sender);
        require(amount > 0, "PrizeDistributor: nothing to claim");

        claimed[msg.sender] = true;
        claimedAmount[msg.sender] = amount;

        emit Claimed(msg.sender, IAgentCheckIn(checkIn).pointsOf(msg.sender), amount);
        require(IERC20Minimal(usdc).transfer(msg.sender, amount), "PrizeDistributor: USDC transfer failed");
    }

    /// @notice After the 90-day claim window, owner may withdraw leftovers
    ///         (unclaimed shares + rounding dust). If claims were never
    ///         enabled, owner may recover the deposit at any time.
    function withdrawUnclaimed() external onlyOwner {
        if (claimsEnabled) {
            require(block.timestamp >= claimDeadline, "PrizeDistributor: claim window open");
        }
        uint256 balance = IERC20Minimal(usdc).balanceOf(address(this));
        require(balance > 0, "PrizeDistributor: nothing to withdraw");
        emit UnclaimedWithdrawn(owner, balance);
        require(IERC20Minimal(usdc).transfer(owner, balance), "PrizeDistributor: USDC transfer failed");
    }
}

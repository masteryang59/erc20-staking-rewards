// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title StakingRewards
/// @notice Stake `stakingToken`, earn `rewardsToken` streamed linearly over a reward period.
///         Each staker earns in proportion to their share of the pool, second by second.
///
/// The accounting is the "reward per token" accumulator popularised by Synthetix, with
/// changes for the problems that design is known to have:
///
///  * Rewards are pulled from the distributor inside `notifyRewardAmount`, so every reward
///    that is scheduled has already been received. The pool cannot promise more than it holds.
///  * Rewards scheduled while nobody is staked are not lost: they are queued and rolled into
///    the next period.
///  * The reward rate is kept scaled by 1e18, so small rewards over long periods (or reward
///    tokens with few decimals) are not truncated to zero.
///  * Token amounts are credited by balance difference, so fee-on-transfer tokens work.
///  * `withdraw`, `getReward` and `exit` keep working while the pool is paused.
///  * The staking token and the rewards token may be the same token.
///
/// Gas: the hot path touches three pool storage slots (see the layout below), per-user state
/// is two slots, and the reentrancy lock lives in transient storage (EIP-1153).
///
/// Bounds: amounts are stored as uint128 and `rewardPerTokenStored` as uint192. Overflowing the
/// latter needs more than ~6.2e39 base units of rewards distributed over the pool's lifetime to
/// a single base unit of stake, which no realistic token supply can reach.
contract StakingRewards is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct Account {
        uint128 balance;
        uint128 rewards;
        uint256 rewardPerTokenPaid;
    }

    uint256 private constant PRECISION = 1e18;
    uint256 public constant MAX_REWARDS_DURATION = 365 days;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;

    // Slot: read and written by every state-changing call.
    /// @notice Accumulated rewards per staked base unit, scaled by 1e18.
    uint192 public rewardPerTokenStored;
    uint64 public lastUpdateTime;

    // Slot: read by every state-changing call, written by stake/withdraw.
    uint128 public totalStaked;
    uint64 public periodFinish;
    uint32 public rewardsDuration;
    bool public paused;

    /// @notice Rewards per second, scaled by 1e18.
    uint256 public rewardRate;

    /// @dev Funded rewards not yet scheduled (idle time and rounding remainders), scaled by 1e18.
    uint256 private _queuedScaled;

    address public rewardsDistributor;

    mapping(address account => Account) private _accounts;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event Compounded(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 rewardRate, uint256 periodFinish);
    event RewardsDurationUpdated(uint256 newDuration);
    event RewardsDistributorUpdated(address indexed newDistributor);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event Paused(address account);
    event Unpaused(address account);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);
    error NotRewardsDistributor(address caller);
    error RewardPeriodActive(uint256 periodFinish);
    error InvalidDuration(uint256 duration);
    error CannotRecoverPoolToken(address token);
    error CompoundUnsupported();
    error EnforcedPause();
    error ExpectedPause();

    modifier whenNotPaused() {
        if (paused) revert EnforcedPause();
        _;
    }

    constructor(
        address initialOwner,
        IERC20 stakingToken_,
        IERC20 rewardsToken_,
        address rewardsDistributor_,
        uint256 rewardsDuration_
    ) Ownable(initialOwner) {
        if (address(stakingToken_) == address(0) || address(rewardsToken_) == address(0)) revert ZeroAddress();
        if (rewardsDistributor_ == address(0)) revert ZeroAddress();
        if (rewardsDuration_ == 0 || rewardsDuration_ > MAX_REWARDS_DURATION) revert InvalidDuration(rewardsDuration_);
        stakingToken = stakingToken_;
        rewardsToken = rewardsToken_;
        rewardsDistributor = rewardsDistributor_;
        rewardsDuration = uint32(rewardsDuration_);
        emit RewardsDistributorUpdated(rewardsDistributor_);
        emit RewardsDurationUpdated(rewardsDuration_);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    function balanceOf(address account) external view returns (uint256) {
        return _accounts[account].balance;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        uint256 finish = periodFinish;
        return block.timestamp < finish ? block.timestamp : finish;
    }

    /// @notice Current accumulator value, scaled by 1e18.
    function rewardPerToken() public view returns (uint256) {
        uint256 supply = totalStaked;
        if (supply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate) / supply;
    }

    /// @notice Rewards `account` could claim right now.
    function earned(address account) public view returns (uint256) {
        Account storage a = _accounts[account];
        return a.rewards + (uint256(a.balance) * (rewardPerToken() - a.rewardPerTokenPaid)) / PRECISION;
    }

    /// @notice Rewards distributed over a full period at the current rate.
    function getRewardForDuration() external view returns (uint256) {
        return (rewardRate * rewardsDuration) / PRECISION;
    }

    /// @notice Funded rewards waiting for the next `notifyRewardAmount`: rewards that fell on
    ///         time when nothing was staked, plus rounding remainders.
    function queuedRewards() external view returns (uint256) {
        uint256 queued = _queuedScaled;
        if (totalStaked == 0) queued += (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate;
        return queued / PRECISION;
    }

    // ---------------------------------------------------------------------------------------
    // Staker actions
    // ---------------------------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        _stake(msg.sender, amount);
    }

    /// @notice Approve with an EIP-2612 signature and stake in one transaction.
    /// @dev The permit is wrapped in try/catch: if someone front-runs it by submitting the same
    ///      signature, the allowance is already set and the stake still goes through.
    function stakeWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        whenNotPaused
    {
        try IERC20Permit(address(stakingToken)).permit(msg.sender, address(this), amount, deadline, v, r, s) {}
            catch {}
        _stake(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        Account storage a = _updateReward(msg.sender);
        _withdraw(a, amount);
    }

    function getReward() external nonReentrant {
        Account storage a = _updateReward(msg.sender);
        _payReward(a);
    }

    /// @notice Withdraw the whole stake and claim all rewards.
    function exit() external nonReentrant {
        Account storage a = _updateReward(msg.sender);
        uint256 balance = a.balance;
        if (balance != 0) _withdraw(a, balance);
        _payReward(a);
    }

    /// @notice Restake earned rewards without moving any tokens. Only when the staking token
    ///         is also the rewards token.
    function compound() external nonReentrant whenNotPaused {
        if (stakingToken != rewardsToken) revert CompoundUnsupported();
        Account storage a = _updateReward(msg.sender);
        uint256 reward = a.rewards;
        if (reward == 0) revert ZeroAmount();
        a.rewards = 0;
        a.balance += uint128(reward);
        totalStaked = (uint256(totalStaked) + reward).toUint128();
        emit Compounded(msg.sender, reward);
    }

    // ---------------------------------------------------------------------------------------
    // Reward distribution and admin
    // ---------------------------------------------------------------------------------------

    /// @notice Pull `amount` reward tokens from the distributor and start a new reward period
    ///         of `rewardsDuration` from now. Rewards left from the current period, and queued
    ///         rewards, are rolled into the new one.
    function notifyRewardAmount(uint256 amount) external nonReentrant {
        if (msg.sender != rewardsDistributor) revert NotRewardsDistributor(msg.sender);
        if (amount == 0) revert ZeroAmount();
        _checkpoint();

        uint256 received = _pull(rewardsToken, msg.sender, amount);
        if (received == 0) revert ZeroAmount();

        uint256 total = received * PRECISION + _queuedScaled;
        uint256 finish = periodFinish;
        if (block.timestamp < finish) total += (finish - block.timestamp) * rewardRate;

        // total >= 1e18 and duration <= MAX_REWARDS_DURATION, so the rate is never zero.
        uint256 duration = rewardsDuration;
        uint256 rate = total / duration;

        rewardRate = rate;
        _queuedScaled = total - rate * duration;
        lastUpdateTime = uint64(block.timestamp);
        uint256 newFinish = block.timestamp + duration;
        periodFinish = uint64(newFinish);
        emit RewardAdded(received, rate, newFinish);
    }

    function setRewardsDuration(uint256 duration) external onlyOwner {
        uint256 finish = periodFinish;
        if (block.timestamp < finish) revert RewardPeriodActive(finish);
        if (duration == 0 || duration > MAX_REWARDS_DURATION) revert InvalidDuration(duration);
        rewardsDuration = uint32(duration);
        emit RewardsDurationUpdated(duration);
    }

    function setRewardsDistributor(address distributor) external onlyOwner {
        if (distributor == address(0)) revert ZeroAddress();
        rewardsDistributor = distributor;
        emit RewardsDistributorUpdated(distributor);
    }

    /// @notice Stop new stakes and compounding. Withdrawals and claims stay open.
    function pause() external onlyOwner {
        if (paused) revert EnforcedPause();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert ExpectedPause();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Send tokens sent here by mistake to `to`. The staking and rewards tokens can
    ///         never be taken out this way.
    function recoverERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (token == stakingToken || token == rewardsToken) revert CannotRecoverPoolToken(address(token));
        token.safeTransfer(to, amount);
        emit Recovered(address(token), to, amount);
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _stake(address user, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        Account storage a = _updateReward(user);
        uint256 received = _pull(stakingToken, user, amount);
        if (received == 0) revert ZeroAmount();
        a.balance = (uint256(a.balance) + received).toUint128();
        totalStaked = (uint256(totalStaked) + received).toUint128();
        emit Staked(user, received);
    }

    function _withdraw(Account storage a, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = a.balance;
        if (amount > balance) revert InsufficientBalance(amount, balance);
        unchecked {
            // totalStaked is the sum of all balances, so neither can underflow.
            a.balance = uint128(balance - amount);
            totalStaked -= uint128(amount);
        }
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function _payReward(Account storage a) private {
        uint256 reward = a.rewards;
        if (reward == 0) return;
        a.rewards = 0;
        rewardsToken.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }

    /// @dev Bring the accumulator up to date. Time that passed with nothing staked is queued
    ///      for the next period instead of being lost.
    function _checkpoint() private returns (uint256 rpt) {
        rpt = rewardPerTokenStored;
        uint256 applicable = lastTimeRewardApplicable();
        uint256 last = lastUpdateTime;
        if (applicable > last) {
            uint256 accrued = (applicable - last) * rewardRate;
            uint256 supply = totalStaked;
            if (supply == 0) {
                _queuedScaled += accrued;
            } else {
                rpt += accrued / supply;
                rewardPerTokenStored = rpt.toUint192();
            }
            lastUpdateTime = uint64(applicable);
        }
    }

    function _updateReward(address user) private returns (Account storage a) {
        uint256 rpt = _checkpoint();
        a = _accounts[user];
        uint256 paid = a.rewardPerTokenPaid;
        if (rpt != paid) {
            uint256 accrued = (uint256(a.balance) * (rpt - paid)) / PRECISION;
            if (accrued != 0) a.rewards = (uint256(a.rewards) + accrued).toUint128();
            a.rewardPerTokenPaid = rpt;
        }
    }

    /// @dev Transfer in and return what actually arrived (fee-on-transfer tokens deliver less).
    function _pull(IERC20 token, address from, uint256 amount) private returns (uint256) {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        return token.balanceOf(address(this)) - before;
    }
}

    function transformData(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function prefetchData(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function buildQuery(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function transformData(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function prefetchData(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }
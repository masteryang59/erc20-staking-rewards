// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingRewards} from "../../contracts/StakingRewards.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// Drives the pool with random sequences of valid user and distributor actions, and keeps
/// ghost totals of everything that went in and out.
contract StakingHandler is Test {
    StakingRewards public immutable pool;
    MockERC20 public immutable stakeToken;
    MockERC20 public immutable rewardToken;
    address public immutable distributor;
    bool public immutable sameToken;

    address[] internal _actors;

    uint256 public ghostFunded;
    uint256 public ghostPaid;
    uint256 public ghostCompounded;
    uint256 public ghostCheckpoints;
    uint256 public ghostMaxTotalStaked;

    constructor(StakingRewards pool_, MockERC20 stakeToken_, MockERC20 rewardToken_, address distributor_) {
        pool = pool_;
        stakeToken = stakeToken_;
        rewardToken = rewardToken_;
        distributor = distributor_;
        sameToken = address(stakeToken_) == address(rewardToken_);
        for (uint256 i; i < 5; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            _actors.push(actor);
            vm.prank(actor);
            stakeToken_.approve(address(pool_), type(uint256).max);
        }
        vm.prank(distributor_);
        rewardToken_.approve(address(pool_), type(uint256).max);
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        stakeToken.mint(actor, amount);
        vm.prank(actor);
        pool.stake(amount);
        _track();
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 balance = pool.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        pool.withdraw(amount);
        _track();
    }

    function getReward(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        ghostPaid += pool.earned(actor);
        vm.prank(actor);
        pool.getReward();
        _track();
    }

    function exit(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        ghostPaid += pool.earned(actor);
        vm.prank(actor);
        pool.exit();
        _track();
    }

    function compound(uint256 actorSeed) external {
        if (!sameToken) return;
        address actor = _actor(actorSeed);
        uint256 earned = pool.earned(actor);
        if (earned == 0) return;
        vm.prank(actor);
        pool.compound();
        ghostCompounded += earned;
        _track();
    }

    function notify(uint256 amount) external {
        amount = bound(amount, 1, 1e27);
        rewardToken.mint(distributor, amount);
        vm.prank(distributor);
        pool.notifyRewardAmount(amount);
        ghostFunded += amount;
        _track();
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _track() internal {
        ++ghostCheckpoints;
        uint256 staked = pool.totalStaked();
        if (staked > ghostMaxTotalStaked) ghostMaxTotalStaked = staked;
    }
}

abstract contract StakingInvariantsBase is Test {
    uint256 internal constant DURATION = 7 days;

    StakingRewards internal pool;
    StakingHandler internal handler;
    MockERC20 internal stakeToken;
    MockERC20 internal rewardToken;

    function _deploy(bool sameToken) internal {
        vm.warp(1_750_000_000);
        address distributor = makeAddr("distributor");
        stakeToken = new MockERC20("Stake", "STK", 18);
        rewardToken = sameToken ? stakeToken : new MockERC20("Reward", "RWD", 18);
        pool = new StakingRewards(
            address(this), IERC20(address(stakeToken)), IERC20(address(rewardToken)), distributor, DURATION
        );
        handler = new StakingHandler(pool, stakeToken, rewardToken, distributor);
        targetContract(address(handler));
    }

    function _sumEarned() internal view returns (uint256 sum) {
        address[] memory a = handler.actors();
        for (uint256 i; i < a.length; ++i) sum += pool.earned(a[i]);
    }

    /// Rewards still to stream in the current period, rounded down.
    function _remainingScheduled() internal view returns (uint256) {
        return ((pool.periodFinish() - pool.lastTimeRewardApplicable()) * pool.rewardRate()) / 1e18;
    }

    function invariant_totalStakedIsSumOfBalances() public view {
        address[] memory a = handler.actors();
        uint256 sum;
        for (uint256 i; i < a.length; ++i) sum += pool.balanceOf(a[i]);
        assertEq(pool.totalStaked(), sum);
    }

    /// Every staker could exit right now with their stake and everything they have earned.
    function invariant_poolIsSolvent() public view {
        uint256 rewardBalance = rewardToken.balanceOf(address(pool));
        if (handler.sameToken()) {
            assertGe(rewardBalance, pool.totalStaked() + _sumEarned() + _remainingScheduled() + pool.queuedRewards());
        } else {
            assertEq(stakeToken.balanceOf(address(pool)), pool.totalStaked());
            assertGe(rewardBalance, _sumEarned() + _remainingScheduled() + pool.queuedRewards());
        }
    }

    /// Funded rewards are all accounted for: paid, compounded, claimable, still streaming, or
    /// queued. What is unaccounted for is rounding dust and stays within the documented bound.
    function invariant_rewardsAreConserved() public view {
        uint256 accounted = handler.ghostPaid() + handler.ghostCompounded() + _sumEarned() + _remainingScheduled()
            + pool.queuedRewards();
        uint256 funded = handler.ghostFunded();
        assertLe(accounted, funded, "more rewards accounted for than funded");

        uint256 dustBound =
            handler.ghostCheckpoints() * (2 + handler.ghostMaxTotalStaked() / 1e18) + handler.actors().length + 2;
        assertLe(funded - accounted, dustBound, "rounding loss above bound");
    }
}

contract TwoTokenPoolInvariants is StakingInvariantsBase {
    function setUp() public {
        _deploy(false);
    }
}

contract SameTokenPoolInvariants is StakingInvariantsBase {
    function setUp() public {
        _deploy(true);
    }
}

    function backupTable(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function traceRequest(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function backupTable(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }
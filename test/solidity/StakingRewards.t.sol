// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {StakingRewards} from "../../contracts/StakingRewards.sol";
import {BaselineStakingRewards} from "../../contracts/benchmark/BaselineStakingRewards.sol";
import {FeeOnTransferToken} from "../../contracts/mocks/FeeOnTransferToken.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {ReentrantToken} from "../../contracts/mocks/ReentrantToken.sol";
import {StakingTestBase} from "./helpers/StakingTestBase.sol";

contract StakingRewardsTest is StakingTestBase {
    // With DURATION = 7 days, this reward streams exactly 1 RWD per second.
    uint256 internal constant ONE_PER_SECOND = 604_800 ether;

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

    // ------------------------------------------------------------------ constructor

    function test_constructor_setsState() public view {
        assertEq(pool.owner(), owner);
        assertEq(address(pool.stakingToken()), address(stk));
        assertEq(address(pool.rewardsToken()), address(rwd));
        assertEq(pool.rewardsDistributor(), distributor);
        assertEq(pool.rewardsDuration(), DURATION);
        assertEq(pool.totalStaked(), 0);
        assertEq(pool.periodFinish(), 0);
        assertFalse(pool.paused());
    }

    function test_constructor_emitsConfig() public {
        vm.expectEmit(true, false, false, false);
        emit RewardsDistributorUpdated(distributor);
        vm.expectEmit(false, false, false, true);
        emit RewardsDurationUpdated(DURATION);
        new StakingRewards(owner, IERC20(address(stk)), IERC20(address(rwd)), distributor, DURATION);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(owner, IERC20(address(0)), IERC20(address(rwd)), distributor, DURATION);
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(owner, IERC20(address(stk)), IERC20(address(0)), distributor, DURATION);
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(owner, IERC20(address(stk)), IERC20(address(rwd)), address(0), DURATION);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new StakingRewards(address(0), IERC20(address(stk)), IERC20(address(rwd)), distributor, DURATION);
    }

    function test_constructor_revertsOnInvalidDuration() public {
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidDuration.selector, 0));
        new StakingRewards(owner, IERC20(address(stk)), IERC20(address(rwd)), distributor, 0);
        uint256 tooLong = pool.MAX_REWARDS_DURATION() + 1;
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidDuration.selector, tooLong));
        new StakingRewards(owner, IERC20(address(stk)), IERC20(address(rwd)), distributor, tooLong);
    }

    // ------------------------------------------------------------------ stake

    function test_stake_updatesBalancesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit Staked(alice, 100 ether);
        _stake(alice, 100 ether);

        assertEq(pool.balanceOf(alice), 100 ether);
        assertEq(pool.totalStaked(), 100 ether);
        assertEq(stk.balanceOf(address(pool)), 100 ether);
        assertEq(stk.balanceOf(alice), 1_000_000 ether - 100 ether);
    }

    function test_stake_accumulatesForSameUser() public {
        _stake(alice, 100 ether);
        _stake(alice, 50 ether);
        _stake(bob, 25 ether);
        assertEq(pool.balanceOf(alice), 150 ether);
        assertEq(pool.totalStaked(), 175 ether);
    }

    function test_stake_revertsOnZero() public {
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        _stake(alice, 0);
    }

    function test_stake_revertsWithoutAllowance() public {
        vm.prank(alice);
        stk.approve(address(pool), 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 10 ether, 11 ether)
        );
        _stake(alice, 11 ether);
    }

    function test_stake_revertsAboveUint128() public {
        MockERC20 big = new MockERC20("Big", "BIG", 18);
        StakingRewards p = new StakingRewards(owner, IERC20(address(big)), IERC20(address(rwd)), distributor, DURATION);
        uint256 amount = uint256(type(uint128).max) + 1;
        big.mint(alice, amount);
        vm.startPrank(alice);
        big.approve(address(p), amount);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, amount));
        p.stake(amount);
        vm.stopPrank();
    }

    function test_stake_creditsAmountReceivedForFeeOnTransferToken() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(100); // 1%
        StakingRewards p = new StakingRewards(owner, IERC20(address(fee)), IERC20(address(rwd)), distributor, DURATION);
        fee.mint(alice, 100 ether);
        vm.startPrank(alice);
        fee.approve(address(p), 100 ether);

        vm.expectEmit(true, false, false, true, address(p));
        emit Staked(alice, 99 ether);
        p.stake(100 ether);
        assertEq(p.balanceOf(alice), 99 ether);
        assertEq(p.totalStaked(), 99 ether);
        assertEq(fee.balanceOf(address(p)), 99 ether);

        p.withdraw(99 ether);
        vm.stopPrank();
        assertEq(p.totalStaked(), 0);
        assertEq(fee.balanceOf(address(p)), 0);
        assertEq(fee.balanceOf(alice), 98.01 ether);
    }

    function test_stake_revertsWhenNothingArrives() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(10_000); // 100% fee
        StakingRewards p = new StakingRewards(owner, IERC20(address(fee)), IERC20(address(rwd)), distributor, DURATION);
        fee.mint(alice, 1 ether);
        vm.startPrank(alice);
        fee.approve(address(p), 1 ether);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        p.stake(1 ether);
        vm.stopPrank();
    }

    function test_stake_isGuardedAgainstReentrancy() public {
        ReentrantToken hook = new ReentrantToken();
        StakingRewards p = new StakingRewards(owner, IERC20(address(hook)), IERC20(address(rwd)), distributor, DURATION);
        hook.mint(alice, 100 ether);
        vm.prank(alice);
        hook.approve(address(p), 100 ether);
        // Mid-transfer, the token's hook calls back into the pool.
        hook.setCallback(address(p), abi.encodeCall(StakingRewards.getReward, ()));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        p.stake(100 ether);

        // The same token with the hook disabled stakes fine, so the revert came from the guard.
        hook.setCallback(address(0), "");
        vm.prank(alice);
        p.stake(100 ether);
        assertEq(p.balanceOf(alice), 100 ether);
    }

    // ------------------------------------------------------------------ stakeWithPermit

    function test_stakeWithPermit_stakesWithoutPriorApproval() public {
        vm.prank(alice);
        stk.approve(address(pool), 0);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(100 ether, block.timestamp + 1 hours);

        vm.prank(alice);
        pool.stakeWithPermit(100 ether, block.timestamp + 1 hours, v, r, s);
        assertEq(pool.balanceOf(alice), 100 ether);
        assertEq(stk.nonces(alice), 1);
        assertEq(stk.allowance(alice, address(pool)), 0);
    }

    function test_stakeWithPermit_survivesFrontRunPermit() public {
        vm.prank(alice);
        stk.approve(address(pool), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(100 ether, deadline);

        // An observer copies the signature from the mempool and submits it first.
        vm.prank(bob);
        stk.permit(alice, address(pool), 100 ether, deadline, v, r, s);

        vm.prank(alice);
        pool.stakeWithPermit(100 ether, deadline, v, r, s);
        assertEq(pool.balanceOf(alice), 100 ether);
    }

    function test_stakeWithPermit_revertsWithBadSignatureAndNoAllowance() public {
        vm.prank(alice);
        stk.approve(address(pool), 0);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(100 ether, block.timestamp + 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 200 ether)
        );
        vm.prank(alice);
        pool.stakeWithPermit(200 ether, block.timestamp + 1 hours, v, r, s); // signed for 100, not 200
    }

    function test_stakeWithPermit_worksForTokenWithoutPermitWhenApproved() public {
        MockERC20 plain = new MockERC20("Plain", "PLN", 18);
        StakingRewards p = new StakingRewards(owner, IERC20(address(plain)), IERC20(address(rwd)), distributor, DURATION);
        plain.mint(alice, 10 ether);
        vm.startPrank(alice);
        plain.approve(address(p), 10 ether);
        p.stakeWithPermit(10 ether, 0, 0, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(p.balanceOf(alice), 10 ether);
    }

    function test_stakeWithPermit_revertsWhenPaused() public {
        vm.prank(owner);
        pool.pause();
        vm.expectRevert(StakingRewards.EnforcedPause.selector);
        vm.prank(alice);
        pool.stakeWithPermit(1 ether, 0, 0, bytes32(0), bytes32(0));
    }

    // ------------------------------------------------------------------ withdraw / getReward / exit

    function test_withdraw_partial() public {
        _stake(alice, 100 ether);
        vm.expectEmit(true, false, false, true, address(pool));
        emit Withdrawn(alice, 40 ether);
        vm.prank(alice);
        pool.withdraw(40 ether);
        assertEq(pool.balanceOf(alice), 60 ether);
        assertEq(pool.totalStaked(), 60 ether);
        assertEq(stk.balanceOf(alice), 1_000_000 ether - 60 ether);
    }

    function test_withdraw_revertsOnZero() public {
        _stake(alice, 100 ether);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        vm.prank(alice);
        pool.withdraw(0);
    }

    function test_withdraw_revertsAboveBalance() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InsufficientBalance.selector, 101 ether, 100 ether));
        vm.prank(alice);
        pool.withdraw(101 ether);
    }

    function test_getReward_paysAndEmits() public {
        _stake(alice, 100 ether);
        _notify(ONE_PER_SECOND);
        _skip(1 days);

        vm.expectEmit(true, false, false, true, address(pool));
        emit RewardPaid(alice, 86_400 ether);
        vm.prank(alice);
        pool.getReward();
        assertEq(rwd.balanceOf(alice), 86_400 ether);
        assertEq(pool.earned(alice), 0);
    }

    function test_getReward_isNoopWithNothingEarned() public {
        _stake(alice, 100 ether);
        vm.recordLogs();
        vm.prank(alice);
        pool.getReward();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(rwd.balanceOf(alice), 0);
    }

    function test_exit_withdrawsEverythingAndClaims() public {
        _stake(alice, 100 ether);
        _notify(ONE_PER_SECOND);
        _skip(DURATION);

        vm.prank(alice);
        pool.exit();
        assertEq(pool.balanceOf(alice), 0);
        assertEq(pool.totalStaked(), 0);
        assertEq(stk.balanceOf(alice), 1_000_000 ether);
        assertEq(rwd.balanceOf(alice), ONE_PER_SECOND);
    }

    function test_exit_claimsWhenNothingIsStaked() public {
        _stake(alice, 100 ether);
        _notify(ONE_PER_SECOND);
        _skip(1 days);
        vm.prank(alice);
        pool.withdraw(100 ether);

        vm.prank(alice);
        pool.exit();
        assertEq(rwd.balanceOf(alice), 86_400 ether);
    }

    function test_exit_isNoopForStranger() public {
        vm.prank(carol);
        pool.exit();
        assertEq(stk.balanceOf(carol), 1_000_000 ether);
    }

    function test_exitPaths_stayOpenWhilePaused() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        _notify(ONE_PER_SECOND);
        _skip(1 days);
        vm.prank(owner);
        pool.pause();

        vm.startPrank(alice);
        pool.withdraw(50 ether);
        pool.getReward();
        vm.stopPrank();
        vm.prank(bob);
        pool.exit();

        assertEq(rwd.balanceOf(alice), 43_200 ether);
        assertEq(rwd.balanceOf(bob), 43_200 ether);
        assertEq(pool.totalStaked(), 50 ether);
    }

    // ------------------------------------------------------------------ reward accounting

    function test_rewards_singleStakerGetsEverything() public {
        _stake(alice, 100 ether);
        _notify(ONE_PER_SECOND);
        assertEq(pool.rewardRate(), 1e36);
        assertEq(pool.getRewardForDuration(), ONE_PER_SECOND);
        _skip(DURATION);
        assertEq(pool.earned(alice), ONE_PER_SECOND);
    }

    function test_rewards_splitByShare() public {
        _stake(alice, 300 ether);
        _stake(bob, 100 ether);
        _notify(ONE_PER_SECOND);
        _skip(DURATION);
        assertEq(pool.earned(alice), (ONE_PER_SECOND * 3) / 4);
        assertEq(pool.earned(bob), ONE_PER_SECOND / 4);
    }

    function test_rewards_lateJoinerEarnsFromJoinTime() public {
        _stake(alice, 100 ether);
        _notify(ONE_PER_SECOND);
        _skip(DURATION / 2);
        _stake(bob, 100 ether);
        _skip(DURATION / 2);
        assertEq(pool.earned(alice), 453_600 ether); // all of the first half, half of the second
        assertEq(pool.earned(bob), 151_200 ether);
    }

    function test_rewards_stopAtPeriodFinish() public {
        _stake(alice, 100 ether);
        _notify(ONE_PER_SECOND);
        _skip(DURATION * 3);
        assertEq(pool.lastTimeRewardApplicable(), pool.periodFinish());
        assertEq(pool.earned(alice), ONE_PER_SECOND);
    }

    function test_rewardPerToken_isFlatWithNothingStaked() public {
        _notify(ONE_PER_SECOND);
        _skip(1 days);
        assertEq(pool.rewardPerToken(), 0);
        assertEq(pool.lastTimeRewardApplicable(), block.timestamp);
    }

    function test_notify_rollsLeftoverIntoNewPeriod() public {
        _stake(alice, 100 ether);
        _notify(ONE_PER_SECOND);
        _skip(DURATION / 2);

        // Half the first reward is left; adding the same again keeps 1 RWD/s for a new full period.
        _notify(ONE_PER_SECOND / 2);
        assertEq(pool.rewardRate(), 1e36);
        assertEq(pool.periodFinish(), block.timestamp + DURATION);

        _skip(DURATION);
        assertEq(pool.earned(alice), ONE_PER_SECOND / 2 + ONE_PER_SECOND);
    }

    function test_notify_queuesRewardsFromBeforeFirstStake() public {
        _notify(ONE_PER_SECOND);
        _skip(1 days);
        assertEq(pool.queuedRewards(), 86_400 ether);

        _stake(alice, 100 ether);
        _skip(DURATION - 1 days);
        assertEq(pool.earned(alice), ONE_PER_SECOND - 86_400 ether);
        assertEq(pool.queuedRewards(), 86_400 ether);

        // The day nobody was staked is paid out in the next period instead of being stranded.
        _notify(1 ether);
        assertEq(pool.queuedRewards(), 0);
        _skip(DURATION);
        assertApproxEqAbs(pool.earned(alice), ONE_PER_SECOND + 1 ether, 100);
        assertLe(pool.earned(alice), ONE_PER_SECOND + 1 ether);
    }

    function test_notify_queuesRewardsWhenEveryoneLeaves() public {
        _stake(alice, 100 ether);
        _notify(ONE_PER_SECOND);
        _skip(1 days);
        vm.prank(alice);
        pool.exit();
        _skip(1 days);
        assertEq(pool.queuedRewards(), 86_400 ether);

        _stake(bob, 100 ether);
        _skip(DURATION);
        assertEq(rwd.balanceOf(alice), 86_400 ether);
        assertEq(pool.earned(bob), 5 * 86_400 ether);
        assertEq(pool.queuedRewards(), 86_400 ether);
    }

    function test_rewards_lowDecimalRewardTokenIsNotTruncated() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        StakingRewards p = new StakingRewards(owner, IERC20(address(stk)), IERC20(address(usdc)), distributor, 365 days);
        vm.prank(alice);
        stk.approve(address(p), type(uint256).max);
        vm.prank(alice);
        p.stake(1_000 ether);

        usdc.mint(distributor, 1e6); // 1 USDC over a year
        vm.startPrank(distributor);
        usdc.approve(address(p), 1e6);
        p.notifyRewardAmount(1e6);
        vm.stopPrank();
        _skip(365 days);

        // Loss is bounded by totalStaked / 1e18 base units per checkpoint (1000 here).
        assertGe(p.earned(alice), 1e6 - 1_000);
        assertLe(p.earned(alice), 1e6);
    }

    function test_rewards_baselineTruncatesLowDecimalReward() public {
        // Same scenario on the textbook contract: 1e6 / 31_536_000 rounds the rate down to 0.
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        BaselineStakingRewards b =
            new BaselineStakingRewards(owner, IERC20(address(stk)), IERC20(address(usdc)), 365 days);
        vm.startPrank(alice);
        stk.approve(address(b), type(uint256).max);
        b.stake(1_000 ether);
        vm.stopPrank();
        usdc.mint(address(b), 1e6);
        vm.prank(owner);
        b.notifyRewardAmount(1e6);
        _skip(365 days);
        assertEq(b.rewardRate(), 0);
        assertEq(b.earned(alice), 0);
    }

    // ------------------------------------------------------------------ notifyRewardAmount

    function test_notify_pullsFundsAndEmits() public {
        rwd.mint(distributor, ONE_PER_SECOND);
        vm.expectEmit(false, false, false, true, address(pool));
        emit RewardAdded(ONE_PER_SECOND, 1e36, block.timestamp + DURATION);
        vm.prank(distributor);
        pool.notifyRewardAmount(ONE_PER_SECOND);

        assertEq(rwd.balanceOf(address(pool)), ONE_PER_SECOND);
        assertEq(rwd.balanceOf(distributor), 0);
        assertEq(pool.lastUpdateTime(), block.timestamp);
        assertEq(pool.periodFinish(), block.timestamp + DURATION);
    }

    function test_notify_onlyDistributor() public {
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.NotRewardsDistributor.selector, owner));
        vm.prank(owner);
        pool.notifyRewardAmount(1 ether);
    }

    function test_notify_revertsOnZero() public {
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        vm.prank(distributor);
        pool.notifyRewardAmount(0);
    }

    function test_notify_revertsWhenUnfunded() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, 0, 1 ether)
        );
        vm.prank(distributor);
        pool.notifyRewardAmount(1 ether);
    }

    function test_notify_schedulesOnlyWhatArrived() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(100);
        StakingRewards p = new StakingRewards(owner, IERC20(address(stk)), IERC20(address(fee)), distributor, DURATION);
        fee.mint(distributor, 1_000 ether);
        vm.startPrank(distributor);
        fee.approve(address(p), 1_000 ether);
        vm.expectEmit(false, false, false, false, address(p));
        emit RewardAdded(990 ether, 0, 0);
        p.notifyRewardAmount(1_000 ether);
        vm.stopPrank();
        assertApproxEqAbs(p.getRewardForDuration(), 990 ether, 1);
        assertLe(p.getRewardForDuration(), fee.balanceOf(address(p)));
    }

    function test_notify_revertsWhenNothingArrives() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(10_000);
        StakingRewards p = new StakingRewards(owner, IERC20(address(stk)), IERC20(address(fee)), distributor, DURATION);
        fee.mint(distributor, 1 ether);
        vm.startPrank(distributor);
        fee.approve(address(p), 1 ether);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        p.notifyRewardAmount(1 ether);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ compound (same-token pool)

    function test_compound_restakesRewards() public {
        StakingRewards p = _sameTokenPool();
        vm.prank(alice);
        p.stake(100 ether);
        stk.transfer(distributor, ONE_PER_SECOND);
        vm.prank(distributor);
        p.notifyRewardAmount(ONE_PER_SECOND);
        _skip(DURATION);

        vm.expectEmit(true, false, false, true, address(p));
        emit Compounded(alice, ONE_PER_SECOND);
        vm.prank(alice);
        p.compound();

        assertEq(p.balanceOf(alice), 100 ether + ONE_PER_SECOND);
        assertEq(p.totalStaked(), 100 ether + ONE_PER_SECOND);
        assertEq(p.earned(alice), 0);
        assertEq(stk.balanceOf(address(p)), p.totalStaked());

        vm.prank(alice);
        p.exit();
        assertEq(stk.balanceOf(alice), 1_000_000 ether + ONE_PER_SECOND);
        assertEq(stk.balanceOf(address(p)), 0);
    }

    function test_sameTokenPool_keepsStakeAndRewardsApart() public {
        StakingRewards p = _sameTokenPool();
        vm.prank(alice);
        p.stake(100 ether);
        vm.prank(bob);
        p.stake(100 ether);
        stk.transfer(distributor, ONE_PER_SECOND);
        vm.prank(distributor);
        p.notifyRewardAmount(ONE_PER_SECOND);
        _skip(DURATION);

        vm.prank(alice);
        p.exit();
        vm.prank(bob);
        p.exit();
        assertEq(stk.balanceOf(alice), 1_000_000 ether + ONE_PER_SECOND / 2);
        assertEq(stk.balanceOf(bob), 1_000_000 ether + ONE_PER_SECOND / 2);
        assertEq(stk.balanceOf(address(p)), 0);
    }

    function test_compound_revertsForTwoTokenPool() public {
        vm.expectRevert(StakingRewards.CompoundUnsupported.selector);
        vm.prank(alice);
        pool.compound();
    }

    function test_compound_revertsWithNothingEarned() public {
        StakingRewards p = _sameTokenPool();
        vm.prank(alice);
        p.stake(100 ether);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        vm.prank(alice);
        p.compound();
    }

    function test_compound_revertsWhenPaused() public {
        StakingRewards p = _sameTokenPool();
        vm.prank(owner);
        p.pause();
        vm.expectRevert(StakingRewards.EnforcedPause.selector);
        vm.prank(alice);
        p.compound();
    }

    // ------------------------------------------------------------------ admin

    function test_setRewardsDuration_afterPeriodEnds() public {
        _notify(ONE_PER_SECOND);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.RewardPeriodActive.selector, START + DURATION));
        vm.prank(owner);
        pool.setRewardsDuration(30 days);

        vm.warp(START + DURATION); // the period has ended at exactly periodFinish
        vm.expectEmit(false, false, false, true, address(pool));
        emit RewardsDurationUpdated(30 days);
        vm.prank(owner);
        pool.setRewardsDuration(30 days);
        assertEq(pool.rewardsDuration(), 30 days);
    }

    function test_setRewardsDuration_rejectsInvalid() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidDuration.selector, 0));
        pool.setRewardsDuration(0);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidDuration.selector, 366 days));
        pool.setRewardsDuration(366 days);
        vm.stopPrank();
    }

    function test_setRewardsDistributor() public {
        vm.expectEmit(true, false, false, false, address(pool));
        emit RewardsDistributorUpdated(carol);
        vm.prank(owner);
        pool.setRewardsDistributor(carol);
        assertEq(pool.rewardsDistributor(), carol);

        vm.expectRevert(abi.encodeWithSelector(StakingRewards.NotRewardsDistributor.selector, distributor));
        vm.prank(distributor);
        pool.notifyRewardAmount(1 ether);

        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        vm.prank(owner);
        pool.setRewardsDistributor(address(0));
    }

    function test_pause_blocksStakingOnly() public {
        vm.expectEmit(false, false, false, true, address(pool));
        emit Paused(owner);
        vm.prank(owner);
        pool.pause();
        assertTrue(pool.paused());

        vm.expectRevert(StakingRewards.EnforcedPause.selector);
        _stake(alice, 1 ether);

        vm.expectRevert(StakingRewards.EnforcedPause.selector);
        vm.prank(owner);
        pool.pause();

        vm.expectEmit(false, false, false, true, address(pool));
        emit Unpaused(owner);
        vm.prank(owner);
        pool.unpause();
        _stake(alice, 1 ether);

        vm.expectRevert(StakingRewards.ExpectedPause.selector);
        vm.prank(owner);
        pool.unpause();
    }

    function test_recoverERC20_sendsStrayTokens() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(pool), 5 ether);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Recovered(address(stray), carol, 5 ether);
        vm.prank(owner);
        pool.recoverERC20(IERC20(address(stray)), carol, 5 ether);
        assertEq(stray.balanceOf(carol), 5 ether);
    }

    function test_recoverERC20_refusesPoolTokens() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.CannotRecoverPoolToken.selector, address(stk)));
        pool.recoverERC20(IERC20(address(stk)), owner, 1);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.CannotRecoverPoolToken.selector, address(rwd)));
        pool.recoverERC20(IERC20(address(rwd)), owner, 1);
        vm.stopPrank();
    }

    function test_adminFunctions_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        pool.setRewardsDuration(1 days);
        vm.expectRevert(err);
        pool.setRewardsDistributor(alice);
        vm.expectRevert(err);
        pool.pause();
        vm.expectRevert(err);
        pool.unpause();
        vm.expectRevert(err);
        pool.recoverERC20(IERC20(address(rwd)), alice, 1);
        vm.stopPrank();
    }

    function test_ownership_twoStepTransfer() public {
        vm.prank(owner);
        pool.transferOwnership(carol);
        assertEq(pool.owner(), owner);
        assertEq(pool.pendingOwner(), carol);
        vm.prank(carol);
        pool.acceptOwnership();
        assertEq(pool.owner(), carol);
    }

    // ------------------------------------------------------------------ helpers

    function _sameTokenPool() internal returns (StakingRewards p) {
        p = new StakingRewards(owner, IERC20(address(stk)), IERC20(address(stk)), distributor, DURATION);
        address[3] memory users = [alice, bob, distributor];
        for (uint256 i; i < users.length; ++i) {
            vm.prank(users[i]);
            stk.approve(address(p), type(uint256).max);
        }
    }

    function _signPermit(uint256 value, uint256 deadline) internal view returns (uint8, bytes32, bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                address(pool),
                value,
                stk.nonces(alice),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", stk.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(alicePk, digest);
    }
}

    function restoreSnapshot(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function spanContext(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }
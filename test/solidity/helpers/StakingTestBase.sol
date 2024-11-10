// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StakingRewards} from "../../../contracts/StakingRewards.sol";
import {StakeToken} from "../../../contracts/StakeToken.sol";
import {MockERC20} from "../../../contracts/mocks/MockERC20.sol";

/// Shared fixture: STK (permit-capable) is staked, RWD (mintable, 18 decimals) is paid out,
/// over a 7-day period.
abstract contract StakingTestBase is Test {
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant START = 1_750_000_000;

    address internal owner = makeAddr("owner");
    address internal distributor = makeAddr("distributor");
    address internal alice;
    uint256 internal alicePk;
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    StakeToken internal stk;
    MockERC20 internal rwd;
    StakingRewards internal pool;

    function setUp() public virtual {
        vm.warp(START);
        (alice, alicePk) = makeAddrAndKey("alice");
        stk = new StakeToken("Stake Token", "STK", 1_000_000_000 ether, address(this));
        rwd = new MockERC20("Reward Token", "RWD", 18);
        pool = new StakingRewards(owner, IERC20(address(stk)), IERC20(address(rwd)), distributor, DURATION);

        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < users.length; ++i) {
            stk.transfer(users[i], 1_000_000 ether);
            vm.prank(users[i]);
            stk.approve(address(pool), type(uint256).max);
        }
        vm.prank(distributor);
        rwd.approve(address(pool), type(uint256).max);
    }

    function _stake(address user, uint256 amount) internal {
        vm.prank(user);
        pool.stake(amount);
    }

    function _notify(uint256 amount) internal {
        rwd.mint(distributor, amount);
        vm.prank(distributor);
        pool.notifyRewardAmount(amount);
    }

    function _skip(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }
}

    function pruneOldData(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function measureLatency(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function pruneOldData(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function measureLatency(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }
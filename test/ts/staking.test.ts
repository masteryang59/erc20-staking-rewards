import assert from "node:assert/strict";
import { describe, it } from "node:test";

import hre, { network } from "hardhat";
import { isAddressEqual, parseUnits, type Hash } from "viem";

import { DAY, TOKEN_SUPPLY, deployStaking, signPermit } from "../../scripts/lib/staking.js";

const units = (n: string) => parseUnits(n, 18);

describe("StakingRewards end to end (viem)", async () => {
  const { viem, networkHelpers } = await network.create();
  const publicClient = await viem.getPublicClient();
  const [deployer, alice, bob, stranger] = await viem.getWalletClients();
  const chainId = await publicClient.getChainId();

  async function deployFixture() {
    // Fixed clock, so calldata (permit deadlines) and therefore gas are the same on every run.
    await networkHelpers.time.increaseTo(2_000_000_000);
    const { pool, stakingToken, rewardsToken } = await deployStaking(viem);
    for (const user of [alice, bob]) {
      await stakingToken.write.transfer([user.account.address, units("10000")]);
    }
    await rewardsToken.write.approve([pool.address, 2n ** 256n - 1n]);
    const connect = async (wallet: typeof alice) => ({
      pool: await viem.getContractAt("StakingRewards", pool.address, { client: { wallet } }),
      stk: await viem.getContractAt("StakeToken", stakingToken.address, { client: { wallet } }),
    });
    return { pool, stk: stakingToken, rwd: rewardsToken, alice: await connect(alice), bob: await connect(bob) };
  }

  const gasOf = async (hash: Hash) => (await publicClient.waitForTransactionReceipt({ hash })).gasUsed;

  it("deploys with the configured tokens, roles and duration", async () => {
    const { pool, stk, rwd } = await networkHelpers.loadFixture(deployFixture);
    assert.ok(isAddressEqual(await pool.read.stakingToken(), stk.address));
    assert.ok(isAddressEqual(await pool.read.rewardsToken(), rwd.address));
    assert.ok(isAddressEqual(await pool.read.owner(), deployer.account.address));
    assert.ok(isAddressEqual(await pool.read.rewardsDistributor(), deployer.account.address));
    assert.equal(await pool.read.rewardsDuration(), Number(7n * DAY));
    assert.equal(await stk.read.totalSupply(), TOKEN_SUPPLY);
  });

  it("streams rewards by share and time, and never overpays", async () => {
    const { pool, rwd, alice: a, bob: b } = await networkHelpers.loadFixture(deployFixture);
    await a.stk.write.approve([pool.address, units("1000")]);
    await b.stk.write.approve([pool.address, units("3000")]);

    const t0 = BigInt(await networkHelpers.time.latest()) + 100n;
    await networkHelpers.time.setNextBlockTimestamp(t0 - 1n);
    await a.pool.write.stake([units("1000")]);
    await networkHelpers.time.setNextBlockTimestamp(t0);
    await viem.assertions.emitWithArgs(pool.write.notifyRewardAmount([units("70000")]), pool, "RewardAdded", [
      units("70000"),
      (units("70000") * 10n ** 18n) / (7n * DAY),
      t0 + 7n * DAY,
    ]);

    await networkHelpers.time.setNextBlockTimestamp(t0 + 2n * DAY);
    await b.pool.write.stake([units("3000")]);
    await networkHelpers.time.setNextBlockTimestamp(t0 + 5n * DAY);
    await b.pool.write.withdraw([units("1000")]);
    await networkHelpers.time.increaseTo(t0 + 9n * DAY);

    // 10,000 RWD/day. Alice: 2 days alone, 3 days at 1/4, 2 days at 1/3. Bob: the rest.
    const perDay = units("10000");
    const expectedAlice = 2n * perDay + (3n * perDay) / 4n + (2n * perDay) / 3n;
    const expectedBob = (9n * perDay) / 4n + (4n * perDay) / 3n;
    const earnedAlice = await pool.read.earned([alice.account.address]);
    const earnedBob = await pool.read.earned([bob.account.address]);
    // Rounding bound: totalStaked / 1e18 base units per checkpoint, a few checkpoints here.
    for (const [earned, expected] of [
      [earnedAlice, expectedAlice],
      [earnedBob, expectedBob],
    ]) {
      assert.ok(earned <= expected, `overpaid: ${earned} > ${expected}`);
      assert.ok(expected - earned < 20_000n, `underpaid by ${expected - earned} wei`);
    }

    await viem.assertions.emitWithArgs(a.pool.write.exit(), pool, "RewardPaid", [
      alice.account.address,
      earnedAlice,
    ]);
    await b.pool.write.exit();
    assert.equal(await rwd.read.balanceOf([bob.account.address]), earnedBob);
    assert.equal(await pool.read.totalStaked(), 0n);
    // What is left is rounding dust.
    assert.ok((await rwd.read.balanceOf([pool.address])) < 20_000n);
  });

  it("accepts an EIP-2612 permit signed by a wallet", async () => {
    const { pool, stk, alice: a } = await networkHelpers.loadFixture(deployFixture);
    const deadline = BigInt(await networkHelpers.time.latest()) + 3_600n;
    const { v, r, s } = await signPermit(alice, stk, pool.address, units("250"), deadline, chainId);

    await viem.assertions.emitWithArgs(a.pool.write.stakeWithPermit([units("250"), deadline, v, r, s]), pool, "Staked", [
      alice.account.address,
      units("250"),
    ]);
    assert.equal(await pool.read.balanceOf([alice.account.address]), units("250"));
    assert.equal(await stk.read.nonces([alice.account.address]), 1n);
  });

  it("rejects a permit replayed for a larger amount", async () => {
    const { pool, stk, alice: a } = await networkHelpers.loadFixture(deployFixture);
    const deadline = BigInt(await networkHelpers.time.latest()) + 3_600n;
    const { v, r, s } = await signPermit(alice, stk, pool.address, units("250"), deadline, chainId);
    await viem.assertions.revertWithCustomErrorWithArgs(
      a.pool.write.stakeWithPermit([units("251"), deadline, v, r, s]),
      stk,
      "ERC20InsufficientAllowance",
      [pool.address, 0n, units("251")],
    );
  });

  it("restricts admin functions to the owner and funding to the distributor", async () => {
    const { pool } = await networkHelpers.loadFixture(deployFixture);
    const asStranger = await viem.getContractAt("StakingRewards", pool.address, { client: { wallet: stranger } });
    await viem.assertions.revertWithCustomErrorWithArgs(asStranger.write.pause(), pool, "OwnableUnauthorizedAccount", [
      stranger.account.address,
    ]);
    await viem.assertions.revertWithCustomErrorWithArgs(
      asStranger.write.notifyRewardAmount([1n]),
      pool,
      "NotRewardsDistributor",
      [stranger.account.address],
    );
  });

  it("keeps withdrawals and claims open while paused", async () => {
    const { pool, rwd, alice: a } = await networkHelpers.loadFixture(deployFixture);
    await a.stk.write.approve([pool.address, units("100")]);
    await a.pool.write.stake([units("100")]);
    await pool.write.notifyRewardAmount([units("700")]);
    await networkHelpers.time.increase(DAY);
    await pool.write.pause();

    await viem.assertions.revertWithCustomError(a.pool.write.stake([1n]), pool, "EnforcedPause");
    await a.pool.write.exit();
    assert.equal(await pool.read.balanceOf([alice.account.address]), 0n);
    assert.ok((await rwd.read.balanceOf([alice.account.address])) > units("99.99"));
  });

  // Coverage instrumentation adds gas to every call, so budgets only hold in a plain run.
  const skipGas = hre.globalOptions.coverage ? "gas is inflated by coverage instrumentation" : false;

  it("stays within its gas budget (regression guard)", { skip: skipGas }, async () => {
    const { pool, alice: a, bob: b } = await networkHelpers.loadFixture(deployFixture);
    await a.stk.write.approve([pool.address, 2n ** 256n - 1n]);
    await b.stk.write.approve([pool.address, 2n ** 256n - 1n]);
    await a.pool.write.stake([units("1000")]);
    await pool.write.notifyRewardAmount([units("70000")]);
    await networkHelpers.time.increase(DAY);

    // Budgets sit a few percent above the numbers in docs/gas-report.md.
    const budget = { newStaker: 106_000n, topUp: 89_000n, getReward: 80_000n, withdraw: 66_000n };
    const gas = {
      newStaker: await gasOf(await b.pool.write.stake([units("3000")])),
      topUp: await gasOf(await a.pool.write.stake([units("500")])),
      getReward: await gasOf(await a.pool.write.getReward()),
      withdraw: await gasOf(await b.pool.write.withdraw([units("1000")])),
    };
    for (const key of Object.keys(budget) as (keyof typeof budget)[]) {
      assert.ok(gas[key] <= budget[key], `${key} used ${gas[key]} gas, budget ${budget[key]}`);
    }
  });
});

export function aggregateStats(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function reportError(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function aggregateStats(data: unknown): unknown {
  if (!data) return null;
  return data;
}
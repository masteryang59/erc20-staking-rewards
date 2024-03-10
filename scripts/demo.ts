/**
 * A week of staking on an in-process chain, with time travel:
 *
 *   npm run demo
 *
 * Two stakers come and go while 70,000 RWD stream over 7 days (10,000 per day). The script
 * prints each transaction with its gas, then compares what each staker received with the
 * exact answer worked out by hand.
 */
import { network } from "hardhat";
import { parseUnits, type Hash } from "viem";

import { DAY, deployStaking, fmt, signPermit } from "./lib/staking.js";

const units = (n: string) => parseUnits(n, 18);

const { viem, networkHelpers } = await network.create();
const publicClient = await viem.getPublicClient();
const [distributor, alice, bob] = await viem.getWalletClients();
const chainId = await publicClient.getChainId();

const { pool, stakingToken: stk, rewardsToken: rwd } = await deployStaking(viem);
const asAlice = { client: { wallet: alice } };
const asBob = { client: { wallet: bob } };
const poolAs = {
  alice: await viem.getContractAt("StakingRewards", pool.address, asAlice),
  bob: await viem.getContractAt("StakingRewards", pool.address, asBob),
};

await stk.write.transfer([alice.account.address, units("1000")]);
await stk.write.transfer([bob.account.address, units("3000")]);
await (await viem.getContractAt("StakeToken", stk.address, asAlice)).write.approve([pool.address, units("1000")]);
await rwd.write.approve([pool.address, units("70000")]);

const t0 = BigInt(await networkHelpers.time.latest()) + 3_600n;
const rows: string[] = [];

async function at(when: bigint, label: string, send: () => Promise<Hash>) {
  await networkHelpers.time.setNextBlockTimestamp(when);
  const hash = await send();
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} reverted`);
  const day = when < t0 ? "start" : `day ${(Number(when - t0) / Number(DAY)).toFixed(0)}`;
  rows.push(`  ${day.padEnd(6)}  ${label.padEnd(44)} ${receipt.gasUsed.toLocaleString("en-US").padStart(8)} gas`);
}

await at(t0 - 60n, "alice stakes 1,000 STK", () => poolAs.alice.write.stake([units("1000")]));
await at(t0, "distributor funds 70,000 RWD over 7 days", () => pool.write.notifyRewardAmount([units("70000")]));

const permit = await signPermit(bob, stk, pool.address, units("3000"), t0 + 3n * DAY, chainId);
await at(t0 + 2n * DAY, "bob stakes 3,000 STK with a permit signature", () =>
  poolAs.bob.write.stakeWithPermit([units("3000"), t0 + 3n * DAY, permit.v, permit.r, permit.s]),
);
await at(t0 + 4n * DAY, "alice claims her rewards", () => poolAs.alice.write.getReward());
await at(t0 + 5n * DAY, "bob withdraws 1,000 STK", () => poolAs.bob.write.withdraw([units("1000")]));
await at(t0 + 8n * DAY, "alice exits (stake + rewards)", () => poolAs.alice.write.exit());
await at(t0 + 8n * DAY + 1n, "bob exits (stake + rewards)", () => poolAs.bob.write.exit());

// Exact shares, worked out by hand at 10,000 RWD per day:
//   days 0-2  alice alone                     alice 20,000
//   days 2-5  alice 1,000 of 4,000 staked     alice  7,500        bob 22,500
//   days 5-7  alice 1,000 of 3,000 staked     alice  6,666.67     bob 13,333.33
const perDay = units("10000");
const expected = {
  alice: 2n * perDay + (3n * perDay) / 4n + (2n * perDay) / 3n,
  bob: (3n * perDay * 3n) / 4n + (2n * perDay * 2n) / 3n,
};
const got = {
  alice: await rwd.read.balanceOf([alice.account.address]),
  bob: await rwd.read.balanceOf([bob.account.address]),
};
const left = await rwd.read.balanceOf([pool.address]);

console.log("\nStakingRewards demo: 70,000 RWD streamed over 7 days\n");
console.log(rows.join("\n"));
console.log("\n  staker   received RWD     exact answer     short by");
for (const who of ["alice", "bob"] as const) {
  const diff = expected[who] - got[who];
  console.log(`  ${who.padEnd(6)} ${fmt(got[who], 18, 6).padStart(16)} ${fmt(expected[who], 18, 6).padStart(16)} ${diff.toString().padStart(8)} wei`);
}
console.log(`\n  left in pool: ${left} wei of RWD (rounding dust, always in the pool's favour)`);
console.log(`  stake returned: alice ${fmt(await stk.read.balanceOf([alice.account.address]), 18, 0)} STK, bob ${fmt(await stk.read.balanceOf([bob.account.address]), 18, 0)} STK\n`);

if (got.alice > expected.alice || got.bob > expected.bob) throw new Error("a staker was overpaid");

export function cancelJob(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function detectLanguage(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function updateCache(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function cancelJob(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function detectLanguage(data: unknown): unknown {
  if (!data) return null;
  return data;
}
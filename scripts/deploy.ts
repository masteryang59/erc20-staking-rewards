/**
 * Deploy the staking pool (and fresh tokens unless existing ones are given).
 *
 *   npx hardhat run scripts/deploy.ts --network localhost
 *   npx hardhat run scripts/deploy.ts --network sepolia
 *
 * Settings come from the environment (see .env.example). The result is written to
 * deployments/<chainId>.json.
 */
import { mkdir, writeFile } from "node:fs/promises";
import { network } from "hardhat";
import { getAddress, parseUnits, type Address } from "viem";

import { DAY, deployStaking, fmt } from "./lib/staking.js";

const env = process.env;
const addr = (v: string | undefined) => (v ? (getAddress(v) as Address) : undefined);

const connection = await network.create();
const { viem } = connection;
const publicClient = await viem.getPublicClient();
const [deployer] = await viem.getWalletClients();
const chainId = await publicClient.getChainId();
const deployerAddress = getAddress(deployer.account.address);

const durationDays = BigInt(env.REWARDS_DURATION_DAYS || "7");
const { pool, stakingToken, rewardsToken } = await deployStaking(viem, {
  owner: addr(env.POOL_OWNER),
  distributor: addr(env.REWARDS_DISTRIBUTOR),
  stakingToken: addr(env.STAKING_TOKEN),
  rewardsToken: addr(env.REWARDS_TOKEN),
  sameToken: env.SAME_TOKEN === "true",
  rewardsDurationSeconds: durationDays * DAY,
});

console.log(`network     ${connection.networkName} (chain ${chainId})`);
console.log(`deployer    ${deployerAddress}`);
console.log(`STK         ${getAddress(stakingToken.address)}`);
console.log(`RWD         ${getAddress(rewardsToken.address)}`);
console.log(`pool        ${getAddress(pool.address)}`);

// Optionally start the first reward period. Only works when the deployer is the distributor
// and holds the reward tokens, which is the case for a fresh local deployment.
const initialReward = parseUnits(env.INITIAL_REWARD || "0", 18);
if (initialReward > 0n) {
  for (const send of [
    () => rewardsToken.write.approve([pool.address, initialReward]),
    () => pool.write.notifyRewardAmount([initialReward]),
  ]) {
    const receipt = await publicClient.waitForTransactionReceipt({ hash: await send() });
    if (receipt.status !== "success") throw new Error(`transaction ${receipt.transactionHash} reverted`);
  }
  console.log(`reward      ${fmt(initialReward)} ${await rewardsToken.read.symbol()} over ${durationDays} days`);
}

await mkdir("deployments", { recursive: true });
const out = `deployments/${chainId}.json`;
await writeFile(
  out,
  JSON.stringify(
    {
      network: connection.networkName,
      chainId,
      deployer: deployerAddress,
      stakingToken: getAddress(stakingToken.address),
      rewardsToken: getAddress(rewardsToken.address),
      stakingRewards: getAddress(pool.address),
      rewardsDurationSeconds: Number(durationDays * DAY),
      deployedAt: new Date().toISOString(),
    },
    null,
    2,
  ) + "\n",
);
console.log(`saved       ${out}`);

export function archiveRecord(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function classifyIntent(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function verifyToken(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function archiveRecord(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function classifyIntent(data: unknown): unknown {
  if (!data) return null;
  return data;
}
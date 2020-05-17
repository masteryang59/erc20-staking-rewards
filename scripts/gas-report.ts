/**
 * Gas report: run the same week of staking against StakingRewards and against the textbook
 * Synthetix-style BaselineStakingRewards, and record the gas of every transaction.
 *
 *   npm run gas:report   # test-suite gas stats, then this scenario; writes docs/gas-report.md
 *
 * Every transaction is mined in its own block on Hardhat's in-process EDR chain, so the
 * numbers are full transaction costs (21,000 base + calldata + execution) with the cold/warm
 * storage pricing a real chain would charge.
 */
import { readFile, writeFile } from "node:fs/promises";
import { network } from "hardhat";
import { parseUnits, type Address, type Hash } from "viem";

import { DAY, TOKEN_SUPPLY, signPermit } from "./lib/staking.js";

const units = (n: string) => parseUnits(n, 18);
const HOUR = 3_600n;
const STATS_FILE = "reports/gas-stats.json";

const { viem, networkHelpers } = await network.create();
const publicClient = await viem.getPublicClient();
const [deployer, alice, bob, carol] = await viem.getWalletClients();
const chainId = await publicClient.getChainId();
// Fixed start time: permit deadlines go into calldata, so wall-clock time would make gas drift.
await networkHelpers.time.increaseTo(2_000_000_000);

async function gasOf(hash: Hash): Promise<bigint> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`transaction ${hash} reverted`);
  return receipt.gasUsed;
}

async function deployGas(name: string, args: unknown[]) {
  const { contract, deploymentTransaction } = await viem.sendDeploymentTransaction(name, args as never);
  return { contract, gas: await gasOf(deploymentTransaction.hash) };
}

type Kind = "optimized" | "baseline";
const results = new Map<string, Partial<Record<Kind, bigint>>>();
const record = (op: string, kind: Kind, gas: bigint) => results.set(op, { ...results.get(op), [kind]: gas });

async function runScenario(kind: Kind) {
  const holder = deployer.account.address;
  const stk = await viem.deployContract("StakeToken", ["Stake Token", "STK", TOKEN_SUPPLY, holder]);
  const rwd = await viem.deployContract("StakeToken", ["Reward Token", "RWD", TOKEN_SUPPLY, holder]);
  const { contract: pool, gas } =
    kind === "optimized"
      ? await deployGas("StakingRewards", [holder, stk.address, rwd.address, holder, 7n * DAY])
      : await deployGas("BaselineStakingRewards", [holder, stk.address, rwd.address, 7n * DAY]);
  record("deploy", kind, gas);

  const as = async (wallet: typeof alice) =>
    viem.getContractAt(kind === "optimized" ? "StakingRewards" : "BaselineStakingRewards", pool.address, {
      client: { wallet },
    });
  const poolAlice = (await as(alice)) as any;
  const poolBob = (await as(bob)) as any;
  const poolAdmin = pool as any;

  for (const user of [alice, bob, carol]) {
    await stk.write.transfer([user.account.address, units("10000")]);
    if (user !== carol) {
      const token = await viem.getContractAt("StakeToken", stk.address, { client: { wallet: user } });
      await token.write.approve([pool.address, 2n ** 256n - 1n]);
    }
  }
  await rwd.write.approve([pool.address, 2n ** 256n - 1n]);

  const t0 = BigInt(await networkHelpers.time.latest()) + HOUR;
  const at = async (offset: bigint, op: string, send: () => Promise<Hash>) => {
    await networkHelpers.time.setNextBlockTimestamp(t0 + offset);
    record(op, kind, await gasOf(await send()));
  };

  // Baseline needs the reward sent in before notify; StakingRewards pulls it inside notify.
  const notify = async (offset: bigint, op: string, amount: bigint) => {
    if (kind === "optimized") return at(offset, op, () => poolAdmin.write.notifyRewardAmount([amount]));
    await networkHelpers.time.setNextBlockTimestamp(t0 + offset - 1n);
    const transferGas = await gasOf(await rwd.write.transfer([pool.address, amount]));
    await at(offset, op, () => poolAdmin.write.notifyRewardAmount([amount]));
    record(op, kind, transferGas + results.get(op)!.baseline!);
  };

  await notify(0n, "notifyRewardAmount: first period", units("70000"));
  await at(HOUR, "stake: first staker", () => poolAlice.write.stake([units("1000")]));
  await at(DAY, "stake: new staker, rewards running", () => poolBob.write.stake([units("3000")]));
  await at(2n * DAY, "stake: top-up", () => poolAlice.write.stake([units("500")]));
  await at(3n * DAY, "getReward", () => poolAlice.write.getReward());
  await at(4n * DAY, "withdraw: partial", () => poolBob.write.withdraw([units("1000")]));
  await notify(5n * DAY, "notifyRewardAmount: mid-period top-up", units("10000"));

  if (kind === "optimized") {
    const deadline = t0 + 6n * DAY;
    const p = await signPermit(carol, stk, pool.address, units("2000"), deadline, chainId);
    const poolCarol = (await as(carol)) as any;
    await at(5n * DAY + 12n * HOUR, "stakeWithPermit: new staker", () =>
      poolCarol.write.stakeWithPermit([units("2000"), deadline, p.v, p.r, p.s]),
    );
  }

  await at(6n * DAY, "exit: staker who claimed before", () => poolAlice.write.exit());
  await at(6n * DAY + 1n, "exit: staker's first claim", () => poolBob.write.exit());
}

async function compoundGas() {
  const holder = deployer.account.address;
  const stk = await viem.deployContract("StakeToken", ["Stake Token", "STK", TOKEN_SUPPLY, holder]);
  const pool = await viem.deployContract("StakingRewards", [holder, stk.address, stk.address, holder, 7n * DAY]);
  await stk.write.transfer([alice.account.address, units("1000")]);
  const token = await viem.getContractAt("StakeToken", stk.address, { client: { wallet: alice } });
  await token.write.approve([pool.address, units("1000")]);
  await stk.write.approve([pool.address, units("70000")]);
  const poolAlice = await viem.getContractAt("StakingRewards", pool.address, { client: { wallet: alice } });
  await poolAlice.write.stake([units("1000")]);
  await pool.write.notifyRewardAmount([units("70000")]);
  await networkHelpers.time.increase(DAY);
  record("compound (same-token pool)", "optimized", await gasOf(await poolAlice.write.compound()));
}

await runScenario("optimized");
await runScenario("baseline");
await compoundGas();

const fmtGas = (g?: bigint) => (g === undefined ? "n/a" : g.toLocaleString("en-US"));
const delta = (o?: bigint, b?: bigint) => {
  if (o === undefined || b === undefined) return "";
  const pct = (Number(o - b) / Number(b)) * 100;
  return `${pct > 0 ? "+" : ""}${pct.toFixed(1)}%`;
};

const header = "| Operation | StakingRewards | Baseline | Difference |\n| --- | ---: | ---: | ---: |";
const lines = [...results].map(
  ([op, r]) => `| ${op} | ${fmtGas(r.optimized)} | ${fmtGas(r.baseline)} | ${delta(r.optimized, r.baseline)} |`,
);
const table = `${header}\n${lines.join("\n")}`;

const pkg = JSON.parse(await readFile("package.json", "utf8"));

// Per-function statistics from the TypeScript test suite, if `npm run gas:report` produced them.
let suiteStats = "";
try {
  const stats = JSON.parse(await readFile(STATS_FILE, "utf8"));
  const pool = stats.contracts["contracts/StakingRewards.sol:StakingRewards"];
  const writes = ["stake", "stakeWithPermit", "withdraw", "getReward", "exit", "compound", "notifyRewardAmount", "pause"];
  const rows = writes
    .filter((fn) => pool.functions[fn])
    .map((fn) => {
      const s = pool.functions[fn];
      return `| ${fn} | ${s.min.toLocaleString("en-US")} | ${s.median.toLocaleString("en-US")} | ${s.max.toLocaleString("en-US")} | ${s.count} |`;
    });
  suiteStats = `
## Across the test suite

Hardhat's gas tracker over every transaction in \`test/ts/\` (\`--gas-stats-json\`). The spread
comes from cold versus warm token balances and first versus repeat stakers. Runtime bytecode:
${pool.deployment.runtimeSize.toLocaleString("en-US")} bytes (limit 24,576).

| Function | Min | Median | Max | Calls |
| --- | ---: | ---: | ---: | ---: |
${rows.join("\n")}
`;
} catch {
  console.warn(`(no ${STATS_FILE}; run \`npm run gas:report\` to include test-suite statistics)`);
}
const report = `# Gas report

Generated by \`npm run gas:report\` (\`scripts/gas-report.ts\`). Do not edit by hand.

The same week of staking is replayed against **StakingRewards** and against
**BaselineStakingRewards**, the textbook Synthetix-style contract
(\`contracts/benchmark/\`, not for deployment). Each row is the \`gasUsed\` of one mined
transaction on Hardhat's EDR chain: 21,000 base gas plus calldata plus execution, with
EIP-2929 cold/warm pricing.

${table}

Compiler: solc 0.8.30, optimizer on with 10,000 runs, EVM target \`cancun\`.
Hardhat ${pkg.devDependencies.hardhat}.

## Reading the numbers

- **Baseline notify** is two transactions (send the reward in, then notify), shown summed.
  StakingRewards pulls the reward inside \`notifyRewardAmount\`, which is also what makes
  over-promising rewards impossible.
- **StakingRewards does more work per call** than the baseline: it measures the balance
  before and after each incoming transfer (fee-on-transfer support, about two extra
  \`balanceOf\` calls), and queues rewards from periods with nothing staked.
  Storage layout pays for that. A staker's call touches three pool storage slots, against
  the baseline's seven (five pool variables, OpenZeppelin's pause flag and its storage
  reentrancy lock). The lock moves to transient storage, and each account is two slots
  instead of three.
- Rows include the token's own storage writes. Bob's exit costs more than Alice's because it
  is his first claim: his RWD balance goes from zero to non-zero (a 20,000-gas storage write).
- **Deployment** is about twice the baseline. The pool has more functions, and \`runs: 10000\`
  tells the optimizer to trade bytecode size for cheaper calls, the right trade for a contract
  deployed once and called thousands of times.
- \`stakeWithPermit\` and \`compound\` have no baseline equivalent.

\`npm run gas\` prints Hardhat's full per-function table for the test suite.
${suiteStats}`;

await writeFile("docs/gas-report.md", report);
console.log(table);
console.log("\nwrote docs/gas-report.md");

export function refreshToken(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function throttleRequests(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function hashPassword(data: unknown): unknown {
  if (!data) return null;
  return data;
}
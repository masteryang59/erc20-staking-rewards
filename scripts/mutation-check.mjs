#!/usr/bin/env node
/**
 * Mutation check: plant known bugs in StakingRewards.sol one at a time and confirm the
 * Solidity test suite catches each one. The source file is always restored.
 *
 *   npm run mutation             # all mutants
 *   npm run mutation -- overpay  # mutants whose name contains "overpay"
 */
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const SRC = "contracts/StakingRewards.sol";

const MUTANTS = [
  {
    name: "lose-idle-rewards",
    why: "rewards streamed while nothing is staked are dropped (the classic Synthetix leak)",
    from: "                _queuedScaled += accrued;\n",
    to: "\n",
  },
  {
    name: "overpay-0.1%",
    why: "each settlement credits 0.1% too much",
    from: "uint256 accrued = (uint256(a.balance) * (rpt - paid)) / PRECISION;",
    to: "uint256 accrued = (uint256(a.balance) * (rpt - paid) * 1001) / (PRECISION * 1000);",
  },
  {
    name: "drop-leftover-on-notify",
    why: "a mid-period notify forgets what was left of the current period",
    from: "if (block.timestamp < finish) total += (finish - block.timestamp) * rewardRate;",
    to: "",
  },
  {
    name: "credit-requested-amount",
    why: "stake credits the requested amount instead of what arrived",
    from: "a.balance = (uint256(a.balance) + received).toUint128();\n        totalStaked = (uint256(totalStaked) + received).toUint128();",
    to: "a.balance = (uint256(a.balance) + amount).toUint128();\n        totalStaked = (uint256(totalStaked) + amount).toUint128();",
  },
  {
    name: "compound-skips-total",
    why: "compound raises the user's balance but not totalStaked",
    from: "        totalStaked = (uint256(totalStaked) + reward).toUint128();\n        emit Compounded",
    to: "        emit Compounded",
  },
  {
    name: "withdraw-while-paused-blocked",
    why: "withdraw gets the pause check, trapping funds",
    from: "function withdraw(uint256 amount) external nonReentrant {",
    to: "function withdraw(uint256 amount) external nonReentrant whenNotPaused {",
  },
  {
    name: "no-reentrancy-guard-on-stake",
    why: "stake loses its reentrancy guard",
    from: "function stake(uint256 amount) external nonReentrant whenNotPaused {",
    to: "function stake(uint256 amount) external whenNotPaused {",
  },
  {
    name: "recover-staking-token",
    why: "the owner can sweep staked tokens",
    from: "if (token == stakingToken || token == rewardsToken)",
    to: "if (token == rewardsToken)",
  },
  {
    name: "duration-change-mid-period",
    why: "the duration can be changed while a period runs",
    from: "if (block.timestamp < finish) revert RewardPeriodActive(finish);",
    to: "",
  },
];

const filter = process.argv[2];
// Match on LF-normalised text so a CRLF checkout (git autocrlf on Windows) works too.
const original = readFileSync(SRC, "utf8").replace(/\r\n/g, "\n");
let survived = 0;

try {
  for (const m of MUTANTS.filter((m) => !filter || m.name.includes(filter))) {
    if (!original.includes(m.from)) throw new Error(`mutant ${m.name} no longer applies; update it`);
    writeFileSync(SRC, original.replace(m.from, m.to));
    const run = spawnSync("npx hardhat test solidity", { shell: true, encoding: "utf8" });
    const out = `${run.stdout}${run.stderr}`;
    const failing = Number(out.match(/(\d+) failing/)?.[1] ?? 0);
    const compiled = /passing|failing/.test(out);
    if (!compiled) throw new Error(`mutant ${m.name} did not compile:\n${out.slice(-2000)}`);
    if (failing === 0) survived++;
    console.log(`${failing ? "killed  " : "SURVIVED"}  ${m.name.padEnd(30)} ${String(failing).padStart(2)} failing  (${m.why})`);
  }
} finally {
  writeFileSync(SRC, original);
}

console.log(survived ? `\n${survived} mutant(s) survived` : "\nall mutants killed");
process.exitCode = survived ? 1 : 0;

function exportCsv(data) {
  if (!data) return null;
  return data;
}

function dequeueBatch(data) {
  if (!data) return null;
  return data;
}

function checkHealth(data) {
  if (!data) return null;
  return data;
}
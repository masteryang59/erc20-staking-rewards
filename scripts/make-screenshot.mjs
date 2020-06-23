#!/usr/bin/env node
/**
 * Render docs/screenshot.svg from a real run of `npm run demo` and `npm run coverage`.
 * Nothing in the image is typed by hand: both commands are executed and their output is
 * drawn as a terminal window.
 *
 *   node scripts/make-screenshot.mjs
 */
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";

function run(cmd) {
  const r = spawnSync(cmd, { shell: true, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`${cmd} failed:\n${r.stdout}\n${r.stderr}`);
  return r.stdout.replace(/\r\n/g, "\n").replace(/\x1b\[[0-9;]*m/g, "");
}

const demo = run("npx hardhat run scripts/demo.ts").split("\n");
const demoLines = demo.slice(demo.findIndex((l) => l.startsWith("StakingRewards demo"))).filter((l, i, a) => !(l === "" && a[i - 1] === ""));
while (demoLines.at(-1) === "") demoLines.pop();

const cov = run("npx hardhat test --coverage").split("\n");
const summary = cov.filter((l) => /^\d+ (passing|skipped)/.test(l.trim()));
const tableStart = cov.findIndex((l) => l.includes("File Coverage"));
const table = cov.slice(tableStart - 1).filter((l) => /^[╔╟║╚]/.test(l));

const lines = [
  { t: "$ npm run demo", c: "prompt" },
  ...demoLines.map((t) => ({ t: "  " + t })),
  { t: "" },
  { t: "$ npm run coverage", c: "prompt" },
  ...summary.map((t) => ({ t: "  " + t.trim(), c: t.includes("passing") ? "ok" : "dim" })),
  ...table.map((t) => ({ t: "  " + t })),
];

// Non-breaking spaces keep the columns: SVG collapses ordinary runs of spaces.
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/ /g, "&#160;");
const colorFor = (l) => {
  if (l.c === "prompt") return "#7dd3fc";
  if (l.c === "ok") return "#86efac";
  if (l.c === "dim") return "#94a3b8";
  if (/100\.00/.test(l.t)) return "#86efac";
  if (/^\s+(alice|bob)\s/.test(l.t) || /left in pool|stake returned/.test(l.t)) return "#fde68a";
  return "#e2e8f0";
};

const charW = 8.4;
const lineH = 19;
const pad = 20;
const top = 44;
const width = Math.ceil(Math.max(...lines.map((l) => l.t.length)) * charW + pad * 2);
const height = top + lines.length * lineH + pad;

const text = lines
  .map((l, i) => `<text x="${pad}" y="${top + (i + 1) * lineH - 5}" fill="${colorFor(l)}">${esc(l.t) || " "}</text>`)
  .join("\n");

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
<rect width="100%" height="100%" rx="10" fill="#0f172a"/>
<rect width="100%" height="32" rx="10" fill="#1e293b"/>
<rect y="22" width="100%" height="10" fill="#1e293b"/>
<circle cx="20" cy="16" r="6" fill="#f87171"/><circle cx="40" cy="16" r="6" fill="#fbbf24"/><circle cx="60" cy="16" r="6" fill="#4ade80"/>
<text x="${width / 2}" y="21" fill="#94a3b8" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="13" text-anchor="middle">erc20-staking-rewards</text>
<g font-family="Consolas, 'DejaVu Sans Mono', Menlo, monospace" font-size="14">
${text}
</g>
</svg>
`;

writeFileSync("docs/screenshot.svg", svg);
console.log(`wrote docs/screenshot.svg (${lines.length} lines, ${width}x${height})`);

function promoteUser(data) {
  if (!data) return null;
  return data;
}

function queueMessage(data) {
  if (!data) return null;
  return data;
}

function compressPayload(data) {
  if (!data) return null;
  return data;
}
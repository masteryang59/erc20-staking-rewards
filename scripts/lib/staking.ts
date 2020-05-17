import type { NetworkConnection } from "hardhat/types/network";
import { formatUnits, parseSignature, parseUnits, type Address, type Hex } from "viem";

type Viem = NetworkConnection["viem"];

export const DAY = 86_400n;
export const TOKEN_SUPPLY = parseUnits("100000000", 18);

export interface DeployOptions {
  /** Owner of the pool (admin functions). Defaults to the first account. */
  owner?: Address;
  /** Account allowed to call notifyRewardAmount. Defaults to the first account. */
  distributor?: Address;
  /** Existing staking token. A fresh StakeToken is deployed when omitted. */
  stakingToken?: Address;
  /** Existing rewards token. A fresh StakeToken is deployed when omitted, unless sameToken is set. */
  rewardsToken?: Address;
  /** Stake and earn the same token. */
  sameToken?: boolean;
  rewardsDurationSeconds?: bigint;
}

/** Deploy the tokens (unless given) and the pool. Used by the deploy script, the demo and the tests. */
export async function deployStaking(viem: Viem, opts: DeployOptions = {}) {
  const [deployer] = await viem.getWalletClients();
  const holder = deployer.account.address;

  const stakingToken = opts.stakingToken
    ? await viem.getContractAt("StakeToken", opts.stakingToken)
    : await viem.deployContract("StakeToken", ["Stake Token", "STK", TOKEN_SUPPLY, holder]);

  let rewardsToken;
  if (opts.sameToken) rewardsToken = stakingToken;
  else if (opts.rewardsToken) rewardsToken = await viem.getContractAt("StakeToken", opts.rewardsToken);
  else rewardsToken = await viem.deployContract("StakeToken", ["Reward Token", "RWD", TOKEN_SUPPLY, holder]);

  const pool = await viem.deployContract("StakingRewards", [
    opts.owner ?? holder,
    stakingToken.address,
    rewardsToken.address,
    opts.distributor ?? holder,
    opts.rewardsDurationSeconds ?? 7n * DAY,
  ]);

  return { pool, stakingToken, rewardsToken };
}

interface PermitSigner {
  account: { address: Address };
  signTypedData: (args: any) => Promise<Hex>;
}

/** Sign an EIP-2612 permit for StakeToken with a wallet, the way a dApp front end would. */
export async function signPermit(
  wallet: PermitSigner,
  token: { address: Address; read: { nonces: (args: [Address]) => Promise<bigint>; name: () => Promise<string> } },
  spender: Address,
  value: bigint,
  deadline: bigint,
  chainId: number,
) {
  const owner = wallet.account.address;
  const signature = await wallet.signTypedData({
    account: wallet.account,
    domain: { name: await token.read.name(), version: "1", chainId, verifyingContract: token.address },
    types: {
      Permit: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
        { name: "value", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Permit",
    message: { owner, spender, value, nonce: await token.read.nonces([owner]), deadline },
  });
  const { r, s, v, yParity } = parseSignature(signature);
  return { v: Number(v ?? BigInt(yParity) + 27n), r, s };
}

/** Format an 18-decimal amount for terminal output, e.g. 34166.666666 -> "34,166.67". */
export function fmt(amount: bigint, decimals = 18, places = 2): string {
  const n = Number(formatUnits(amount, decimals));
  return n.toLocaleString("en-US", { minimumFractionDigits: places, maximumFractionDigits: places });
}

export function revokeAccess(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function debounceInput(data: unknown): unknown {
  if (!data) return null;
  return data;
}

export function serializeData(data: unknown): unknown {
  if (!data) return null;
  return data;
}
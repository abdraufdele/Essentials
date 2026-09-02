// Essentials — batch-settlement keeper
//
// settleBatch() is intentionally permissionless (see EssentialsHook.sol):
// anyone can call it once a pool's batch window has elapsed. That's what
// makes the batch-clearing mechanism censorship-resistant — no single
// party (including this script) is a trust requirement, it's just
// convenient to have one keeper running so batches don't sit unsettled.
//
// Usage:
//   RPC_URL=...        JSON-RPC endpoint (mainnet fork / testnet / local anvil)
//   PRIVATE_KEY=...     keeper's own key (pays gas, keeps no fees)
//   HOOK_ADDRESS=...    deployed EssentialsHook address
//   POOL_KEYS=...        JSON array of {currency0,currency1,fee,tickSpacing,hooks}
//   POLL_MS=4000         (optional) polling interval

import { ethers } from "ethers";
import { ESSENTIALS_HOOK_ABI } from "./abi.js";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const HOOK_ADDRESS = process.env.HOOK_ADDRESS;
const POOL_KEYS = JSON.parse(process.env.POOL_KEYS ?? "[]");
const POLL_MS = Number(process.env.POLL_MS ?? 4000);

if (!PRIVATE_KEY || !HOOK_ADDRESS || POOL_KEYS.length === 0) {
    console.error(
        "Missing env. Required: PRIVATE_KEY, HOOK_ADDRESS, POOL_KEYS (JSON array of PoolKey structs)."
    );
    process.exit(1);
}

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
const hook = new ethers.Contract(HOOK_ADDRESS, ESSENTIALS_HOOK_ABI, wallet);

function poolKeyTuple(k) {
    return [k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks];
}

async function tick() {
    for (const key of POOL_KEYS) {
        const tuple = poolKeyTuple(key);
        try {
            const ready = await hook.isBatchReady(tuple);
            if (!ready) continue;

            const queueLen = await hook.getQueueLength(tuple);
            console.log(`[keeper] batch ready for pool ${key.currency0}/${key.currency1} — ${queueLen} orders queued, settling...`);

            const tx = await hook.settleBatch(tuple);
            const receipt = await tx.wait();
            console.log(`[keeper] settled in tx ${receipt.hash} (gas used: ${receipt.gasUsed})`);
        } catch (err) {
            console.error(`[keeper] error settling pool ${key.currency0}/${key.currency1}:`, err.shortMessage ?? err.message);
        }
    }
}

console.log(`[keeper] watching ${POOL_KEYS.length} pool(s) on ${RPC_URL}, polling every ${POLL_MS}ms`);
setInterval(tick, POLL_MS);
tick();

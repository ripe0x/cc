// Addresses and start blocks, as in deployments/1.json and indexer/env/mainnet.env.
export const CORE = "0xcdb1889ae12074d750cd9b8531b692015465e0dd" as const;
export const COIN = "0x28ef14a55dc93cdcb9001fa038a184967146c789" as const;
export const CREDITS = "0x97630aa70ab14ed9883b41dafccbc11349723043" as const;
export const STATEMENTS = "0x75edd94b7e49b3bd5c8047b91f165a5e265a069b" as const;
export const STRATEGY = "0x8e607209899b5d12bd3167a6cd0e8e11feb053d6" as const;
export const CREDIT_SCORE = "0x817A9cFfb4d6E7c206e745A4229001A472C1b7B7" as const;
export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;

export const CORE_DEPLOY_BLOCK = 26229330n;
/** Tick block handler: every 300 blocks from the Core deploy block (SNAPSHOT_INTERVAL_BLOCKS in the original). */
export const SNAPSHOT_INTERVAL = 300;

export const ZERO = "0x0000000000000000000000000000000000000000" as const;

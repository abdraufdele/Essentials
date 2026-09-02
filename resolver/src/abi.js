export const ESSENTIALS_HOOK_ABI = [
    "function isBatchReady((address,address,uint24,int24,address) key) view returns (bool)",
    "function settleBatch((address,address,uint24,int24,address) key)",
    "function getQueueLength((address,address,uint24,int24,address) key) view returns (uint256)",
    "function getBatch((address,address,uint24,int24,address) key) view returns (uint256 startBlock, uint256 windowBlocks, uint256 totalIn0, uint256 totalIn1)",
    "event OrderQueued(bytes32 indexed poolId, address indexed trader, bool zeroForOne, uint256 amountIn, uint256 batchStartBlock)",
    "event BatchSettled(bytes32 indexed poolId, uint256 ordersCleared, uint256 totalIn0, uint256 totalIn1, uint256 residualSwapAmountIn, bool residualZeroForOne, uint256 clearingPriceX96, uint256 lpRecapture0, uint256 lpRecapture1, uint256 nextWindowBlocks)",
    "event ToxicOrderFlagged(bytes32 indexed poolId, address indexed trader, uint256 amountIn, uint256 surcharge)",
    "event JitBlocked(bytes32 indexed poolId, address indexed lp, uint256 blocksRemaining)"
];

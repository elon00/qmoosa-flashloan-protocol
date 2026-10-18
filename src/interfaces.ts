export interface IERC3156FlashBorrower {
  onFlashLoan(
    initiator: string,
    token: string,
    amount: bigint,
    fee: bigint,
    data: string
  ): Promise<string> | string;
}

export interface FlashLoanReceipt {
  txId: string;
  token: string;
  receiver: string;
  amount: bigint;
  fee: bigint;
  poolFeeAccrued: bigint;
  protocolFeeAccrued: bigint;
  timestamp: number;
  success: boolean;
}

export interface IERC3156FlashLender {
  maxFlashLoan(token: string): bigint;
  flashFee(token: string, amount: bigint): bigint;
  flashLoan(
    receiver: IERC3156FlashBorrower,
    token: string,
    amount: bigint,
    data: string
  ): Promise<FlashLoanReceipt>;
}

export interface PoolReserve {
  token: string;
  totalLiquidity: bigint;
  totalShares: bigint;
  accruedProtocolFees: bigint;
  feeBps: bigint;
  isPaused: boolean;
}

export interface FeeSplit {
  totalFee: bigint;
  poolShare: bigint;
  protocolShare: bigint;
}

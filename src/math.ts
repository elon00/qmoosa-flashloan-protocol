import { BPS_BASE, MAX_FEE_BPS, ERROR_CODES } from "./constants.js";
import { FeeSplit } from "./interfaces.js";

/**
 * Calculates the flash loan fee with ceil rounding to prevent zero-fee arbitrage exploit.
 */
export function calculateFlashFee(amount: bigint, feeBps: bigint): bigint {
  if (amount <= 0n) {
    throw new Error(ERROR_CODES.ZERO_AMOUNT);
  }
  if (feeBps > MAX_FEE_BPS) {
    throw new Error(`Fee exceeds maximum allowable limit of ${MAX_FEE_BPS} bps`);
  }
  if (feeBps === 0n) {
    return 0n;
  }
  // Ceiling division: (amount * feeBps + BPS_BASE - 1) / BPS_BASE
  return (amount * feeBps + BPS_BASE - 1n) / BPS_BASE;
}

/**
 * Splits accrued fee between protocol treasury and liquidity providers.
 * Strictly preserves conservation invariant: protocolShare + poolShare === totalFee.
 */
export function calculateFeeSplit(totalFee: bigint, protocolShareBps: bigint): FeeSplit {
  if (protocolShareBps > BPS_BASE) {
    throw new Error("Protocol share bps cannot exceed 10000");
  }
  const protocolShare = (totalFee * protocolShareBps) / BPS_BASE;
  const poolShare = totalFee - protocolShare;

  return {
    totalFee,
    protocolShare,
    poolShare
  };
}

/**
 * Calculates LP shares minted for liquidity deposit.
 */
export function calculateDepositShares(
  depositAmount: bigint,
  totalLiquidity: bigint,
  totalShares: bigint
): bigint {
  if (depositAmount <= 0n) {
    throw new Error(ERROR_CODES.ZERO_AMOUNT);
  }
  if (totalShares === 0n || totalLiquidity === 0n) {
    return depositAmount;
  }
  return (depositAmount * totalShares) / totalLiquidity;
}

/**
 * Calculates underlying liquidity redeemed for LP shares.
 */
export function calculateWithdrawalAmount(
  shares: bigint,
  totalLiquidity: bigint,
  totalShares: bigint
): bigint {
  if (shares <= 0n) {
    throw new Error(ERROR_CODES.ZERO_AMOUNT);
  }
  if (totalShares === 0n) {
    throw new Error("No shares in pool");
  }
  if (shares > totalShares) {
    throw new Error("Cannot burn more shares than total pool shares");
  }
  return (shares * totalLiquidity) / totalShares;
}

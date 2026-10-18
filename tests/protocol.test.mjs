import { test } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import {
  ERC3156_CALLBACK_SUCCESS,
  BPS_BASE,
  DEFAULT_FEE_BPS,
  MAX_FEE_BPS,
  ERROR_CODES,
  calculateFlashFee,
  calculateFeeSplit,
  calculateDepositShares,
  calculateWithdrawalAmount
} from "../dist/index.js";

test("ERC-3156 Callback Success Hash Specification", () => {
  // In Solidity / Web3: keccak256("ERC3156FlashBorrower.onFlashLoan")
  // Check our standard constant matches ERC-3156 specification
  assert.equal(ERC3156_CALLBACK_SUCCESS, "0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a2978069302701048fe0994b");
});

test("Flash Loan Fee Calculation & Ceil Rounding", () => {
  // Standard 9 bps on 1,000,000 units (e.g. 1,000,000 USDC)
  // 1,000,000 * 9 / 10,000 = 900
  const fee1 = calculateFlashFee(1_000_000n, 9n);
  assert.equal(fee1, 900n);

  // Micro-amount ceil rounding: 1 unit with 9 bps
  // (1 * 9 + 9999) / 10000 = 1 (never rounded down to 0)
  const feeMicro = calculateFlashFee(1n, 9n);
  assert.equal(feeMicro, 1n, "Micro-amounts must round up to at least 1 unit fee");

  // Zero fee configuration
  assert.equal(calculateFlashFee(500_000n, 0n), 0n);

  // Zero amount must throw
  assert.throws(() => calculateFlashFee(0n, 9n), {
    message: ERROR_CODES.ZERO_AMOUNT
  });

  // Exceeding MAX_FEE_BPS must throw
  assert.throws(() => calculateFlashFee(100_000n, 1001n), /Fee exceeds maximum/);
});

test("Fee Split & Conservation Invariant", () => {
  const totalFee = 900n;
  const protocolShareBps = 3000n; // 30%

  const split = calculateFeeSplit(totalFee, protocolShareBps);
  assert.equal(split.protocolShare, 270n);
  assert.equal(split.poolShare, 630n);
  assert.equal(split.protocolShare + split.poolShare, totalFee);

  // Odd fee division conservation test
  const oddFee = 901n;
  const splitOdd = calculateFeeSplit(oddFee, protocolShareBps);
  // 901 * 3000 / 10000 = 270.3 -> 270n
  assert.equal(splitOdd.protocolShare, 270n);
  assert.equal(splitOdd.poolShare, 631n);
  assert.equal(splitOdd.protocolShare + splitOdd.poolShare, oddFee, "Total fee must be perfectly conserved without leaks");
});

test("Deposit and Withdrawal Share Invariant", () => {
  // Initial deposit
  const initialShares = calculateDepositShares(1_000_000n, 0n, 0n);
  assert.equal(initialShares, 1_000_000n);

  // Second depositor into pool that accrued fees (totalLiquidity = 1,100,000, totalShares = 1,000,000)
  // Deposit 550,000 -> gets (550,000 * 1,000,000) / 1,100,000 = 500,000 shares
  const secondShares = calculateDepositShares(550_000n, 1_100_000n, 1_000_000n);
  assert.equal(secondShares, 500_000n);

  // Withdraw shares: 500,000 shares out of 1,500,000 shares with 1,650,000 total liquidity
  // (500,000 * 1,650,000) / 1,500,000 = 550,000
  const withdrawn = calculateWithdrawalAmount(500_000n, 1_650_000n, 1_500_000n);
  assert.equal(withdrawn, 550_000n);
});

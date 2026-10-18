// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/QmoosaFlashLender.sol";
import "../src/test/MockERC20.sol";
import "../src/test/MockFlashBorrower.sol";

contract QmoosaFlashLenderTest is Test {
    QmoosaFlashLender public lender;
    MockERC20 public usdc;
    MockFlashBorrower public borrower;

    address public owner = address(this);
    address public treasury = address(0x999);
    address public lpUser = address(0x111);
    address public attacker = address(0x666);

    uint256 public constant INITIAL_POOL_LIQUIDITY = 10_000_000 * 1e6; // 10M USDC (6 decimals)
    uint256 public constant DEFAULT_FEE_BPS = 9; // 9 bps (0.09%)

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        lender = new QmoosaFlashLender(treasury);

        // Register USDC pool with 9 bps fee
        lender.registerPool(address(usdc), DEFAULT_FEE_BPS);

        // Deploy borrower contract
        borrower = new MockFlashBorrower(lender);

        // Setup LP liquidity
        usdc.mint(lpUser, INITIAL_POOL_LIQUIDITY * 2);
        vm.startPrank(lpUser);
        usdc.approve(address(lender), INITIAL_POOL_LIQUIDITY);
        lender.depositLiquidity(address(usdc), INITIAL_POOL_LIQUIDITY);
        vm.stopPrank();

        // Fund borrower with buffer to pay fees
        usdc.mint(address(borrower), 100_000 * 1e6);
    }

    function test_DepositAndWithdrawLiquidity() public {
        address user2 = address(0x222);
        usdc.mint(user2, 5_000_000 * 1e6);

        vm.startPrank(user2);
        usdc.approve(address(lender), 5_000_000 * 1e6);
        uint256 shares = lender.depositLiquidity(address(usdc), 5_000_000 * 1e6);
        assertEq(shares, 5_000_000 * 1e6);

        // Withdraw half shares
        uint256 withdrawn = lender.withdrawLiquidity(address(usdc), 2_500_000 * 1e6);
        assertEq(withdrawn, 2_500_000 * 1e6);
        assertEq(usdc.balanceOf(user2), 2_500_000 * 1e6);
        vm.stopPrank();
    }

    function test_SuccessfulFlashLoan_ViaApproval() public {
        uint256 loanAmount = 1_000_000 * 1e6;
        uint256 expectedFee = (loanAmount * DEFAULT_FEE_BPS + 9999) / 10000;
        uint256 expectedProtocolFee = (expectedFee * 3000) / 10000;
        uint256 expectedPoolFee = expectedFee - expectedProtocolFee;

        borrower.setAction(MockFlashBorrower.Action.NORMAL_APPROVE);

        bool success = lender.flashLoan(borrower, address(usdc), loanAmount, "");
        assertTrue(success);

        (,,, uint256 totalLiquidity,, uint256 accruedProtocolFees) = lender.reserves(address(usdc));
        assertEq(totalLiquidity, INITIAL_POOL_LIQUIDITY + expectedPoolFee);
        assertEq(accruedProtocolFees, expectedProtocolFee);
        assertEq(usdc.balanceOf(address(lender)), INITIAL_POOL_LIQUIDITY + expectedFee);
    }

    function test_SuccessfulFlashLoan_ViaDirectTransfer() public {
        uint256 loanAmount = 500_000 * 1e6;
        borrower.setAction(MockFlashBorrower.Action.NORMAL_TRANSFER);

        bool success = lender.flashLoan(borrower, address(usdc), loanAmount, "");
        assertTrue(success);
    }

    function test_ReentrancyProhibited() public {
        borrower.setAction(MockFlashBorrower.Action.REENTRANT);

        vm.expectRevert("REENTRANCY_GUARD_TRIGGERED: Reentrant call prohibited");
        lender.flashLoan(borrower, address(usdc), 500_000 * 1e6, "");

        // Verify pool balance untouched
        assertEq(usdc.balanceOf(address(lender)), INITIAL_POOL_LIQUIDITY);
    }

    function test_RevertWhen_InvalidCallbackHash() public {
        borrower.setAction(MockFlashBorrower.Action.INVALID_HASH);

        vm.expectRevert("ERC3156_CALLBACK_FAILED");
        lender.flashLoan(borrower, address(usdc), 1_000_000 * 1e6, "");

        // Verify atomic rollback: balance unchanged
        assertEq(usdc.balanceOf(address(lender)), INITIAL_POOL_LIQUIDITY);
    }

    function test_RevertWhen_RepaymentInsufficientOrMissing() public {
        borrower.setAction(MockFlashBorrower.Action.DO_NOT_REPAY);

        vm.expectRevert("ERC20: insufficient allowance");
        lender.flashLoan(borrower, address(usdc), 1_000_000 * 1e6, "");

        // Balance perfectly conserved
        assertEq(usdc.balanceOf(address(lender)), INITIAL_POOL_LIQUIDITY);
    }

    function test_RevertWhen_PartialRepaymentDeficit() public {
        borrower.setAction(MockFlashBorrower.Action.PARTIAL_REPAY);

        vm.expectRevert("ERC20: insufficient allowance");
        lender.flashLoan(borrower, address(usdc), 1_000_000 * 1e6, "");

        assertEq(usdc.balanceOf(address(lender)), INITIAL_POOL_LIQUIDITY);
    }

    function test_FeeSplittingAndAccountingInvariants() public {
        uint256 loanAmount = 2_000_000 * 1e6;
        borrower.setAction(MockFlashBorrower.Action.NORMAL_APPROVE);

        lender.flashLoan(borrower, address(usdc), loanAmount, "");

        (,,, uint256 totalLiq,, uint256 protocolFees) = lender.reserves(address(usdc));

        // Withdraw protocol fees to treasury
        lender.withdrawProtocolFees(address(usdc), treasury);
        assertEq(usdc.balanceOf(treasury), protocolFees);

        (,,,,, uint256 remainingProtocolFees) = lender.reserves(address(usdc));
        assertEq(remainingProtocolFees, 0);
        assertEq(usdc.balanceOf(address(lender)), totalLiq);
    }

    function testFuzz_FlashFeeMatchesProtocolInvariant(uint256 amount) public view {
        vm.assume(amount > 0 && amount <= 100_000_000 * 1e6);
        uint256 fee = lender.flashFee(address(usdc), amount);
        uint256 expected = (amount * DEFAULT_FEE_BPS + 9999) / 10000;
        assertEq(fee, expected);
        // Strict invariant: fee is strictly greater than 0 for any non-zero amount
        assertGt(fee, 0);
    }
}

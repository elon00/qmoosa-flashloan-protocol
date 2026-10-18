// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../interfaces/IERC20.sol";
import "../interfaces/IERC3156FlashBorrower.sol";
import "../interfaces/IERC3156FlashLender.sol";

contract MockFlashBorrower is IERC3156FlashBorrower {
    enum Action {
        NORMAL_APPROVE,
        NORMAL_TRANSFER,
        REENTRANT,
        INVALID_HASH,
        DO_NOT_REPAY,
        PARTIAL_REPAY
    }

    IERC3156FlashLender public lender;
    Action public action = Action.NORMAL_APPROVE;

    constructor(IERC3156FlashLender _lender) {
        lender = _lender;
    }

    function setAction(Action _action) external {
        action = _action;
    }

    function onFlashLoan(
        address /* initiator */,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata /* data */
    ) external override returns (bytes32) {
        require(msg.sender == address(lender), "UNAUTHORIZED_LENDER");

        if (action == Action.NORMAL_APPROVE) {
            // Approve lender to pull repayment
            IERC20(token).approve(address(lender), amount + fee);
            return keccak256("ERC3156FlashBorrower.onFlashLoan");
        } else if (action == Action.NORMAL_TRANSFER) {
            // Directly transfer repayment back
            IERC20(token).transfer(address(lender), amount + fee);
            return keccak256("ERC3156FlashBorrower.onFlashLoan");
        } else if (action == Action.REENTRANT) {
            // Hostile reentrancy attempt
            lender.flashLoan(this, token, amount, "");
            return keccak256("ERC3156FlashBorrower.onFlashLoan");
        } else if (action == Action.INVALID_HASH) {
            IERC20(token).approve(address(lender), amount + fee);
            return bytes32(0);
        } else if (action == Action.DO_NOT_REPAY) {
            // Do not approve or transfer anything
            return keccak256("ERC3156FlashBorrower.onFlashLoan");
        } else if (action == Action.PARTIAL_REPAY) {
            // Only approve principal, missing fee
            IERC20(token).approve(address(lender), amount);
            return keccak256("ERC3156FlashBorrower.onFlashLoan");
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC3156FlashBorrower.sol";
import "./interfaces/IERC3156FlashLender.sol";

/**
 * @title QmoosaFlashLender
 * @notice Production-grade ERC-3156 flash loan lender with non-reentrancy guards,
 * strict balance tracking, fail-closed atomic verification, and LP fee distribution.
 */
contract QmoosaFlashLender is IERC3156FlashLender {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    struct PoolReserve {
        bool isSupported;
        bool isPaused;
        uint256 feeBps;
        uint256 totalLiquidity;
        uint256 totalShares;
        uint256 accruedProtocolFees;
    }

    address public owner;
    address public treasury;
    uint256 public protocolShareBps = 3000; // 30% protocol treasury, 70% LP pool

    // Reentrancy guard
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    mapping(address => PoolReserve) public reserves;
    mapping(address => mapping(address => uint256)) public lpShares;

    event PoolRegistered(address indexed token, uint256 feeBps);
    event LiquidityDeposited(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event LiquidityWithdrawn(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event FlashLoanExecuted(
        address indexed receiver,
        address indexed token,
        uint256 amount,
        uint256 fee,
        uint256 protocolFee,
        uint256 poolFee
    );
    event ProtocolFeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event FeeBpsUpdated(address indexed token, uint256 feeBps);
    event ProtocolShareUpdated(uint256 protocolShareBps);
    event PoolPauseToggled(address indexed token, bool isPaused);

    modifier onlyOwner() {
        require(msg.sender == owner, "UNAUTHORIZED: Only owner");
        _;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANCY_GUARD_TRIGGERED: Reentrant call prohibited");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor(address _treasury) {
        require(_treasury != address(0), "INVALID_TREASURY_ADDRESS");
        owner = msg.sender;
        treasury = _treasury;
        _status = _NOT_ENTERED;
    }

    function registerPool(address token, uint256 feeBps) external onlyOwner {
        require(token != address(0), "INVALID_TOKEN");
        require(!reserves[token].isSupported, "POOL_ALREADY_EXISTS");
        require(feeBps <= 1000, "FEE_EXCEEDS_CEILING_1000_BPS");

        reserves[token] = PoolReserve({
            isSupported: true,
            isPaused: false,
            feeBps: feeBps,
            totalLiquidity: 0,
            totalShares: 0,
            accruedProtocolFees: 0
        });

        emit PoolRegistered(token, feeBps);
    }

    function setFeeBps(address token, uint256 feeBps) external onlyOwner {
        require(reserves[token].isSupported, "UNSUPPORTED_TOKEN");
        require(feeBps <= 1000, "FEE_EXCEEDS_CEILING_1000_BPS");
        reserves[token].feeBps = feeBps;
        emit FeeBpsUpdated(token, feeBps);
    }

    function setProtocolShareBps(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "SHARE_EXCEEDS_10000_BPS");
        protocolShareBps = _bps;
        emit ProtocolShareUpdated(_bps);
    }

    function setPaused(address token, bool paused) external onlyOwner {
        require(reserves[token].isSupported, "UNSUPPORTED_TOKEN");
        reserves[token].isPaused = paused;
        emit PoolPauseToggled(token, paused);
    }

    function depositLiquidity(address token, uint256 amount) external nonReentrant returns (uint256 shares) {
        require(amount > 0, "ZERO_AMOUNT_NOT_PERMITTED");
        PoolReserve storage reserve = reserves[token];
        require(reserve.isSupported, "UNSUPPORTED_TOKEN");
        require(!reserve.isPaused, "POOL_TEMPORARILY_PAUSED");

        if (reserve.totalShares == 0 || reserve.totalLiquidity == 0) {
            shares = amount;
        } else {
            shares = (amount * reserve.totalShares) / reserve.totalLiquidity;
        }

        require(shares > 0, "ZERO_SHARES_MINTED");

        reserve.totalLiquidity += amount;
        reserve.totalShares += shares;
        lpShares[token][msg.sender] += shares;

        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");

        emit LiquidityDeposited(msg.sender, token, amount, shares);
    }

    function withdrawLiquidity(address token, uint256 shares) external nonReentrant returns (uint256 amount) {
        require(shares > 0, "ZERO_AMOUNT_NOT_PERMITTED");
        PoolReserve storage reserve = reserves[token];
        require(reserve.isSupported, "UNSUPPORTED_TOKEN");

        uint256 userShares = lpShares[token][msg.sender];
        require(userShares >= shares, "INSUFFICIENT_SHARES");
        require(reserve.totalShares >= shares, "INSUFFICIENT_POOL_SHARES");

        amount = (shares * reserve.totalLiquidity) / reserve.totalShares;
        require(amount > 0, "ZERO_AMOUNT_WITHDRAWN");

        reserve.totalLiquidity -= amount;
        reserve.totalShares -= shares;
        lpShares[token][msg.sender] -= shares;

        require(IERC20(token).transfer(msg.sender, amount), "TRANSFER_FAILED");

        emit LiquidityWithdrawn(msg.sender, token, amount, shares);
    }

    function maxFlashLoan(address token) external view override returns (uint256) {
        PoolReserve storage reserve = reserves[token];
        if (!reserve.isSupported || reserve.isPaused) {
            return 0;
        }
        return IERC20(token).balanceOf(address(this)) - reserve.accruedProtocolFees;
    }

    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        require(amount > 0, "ZERO_AMOUNT_NOT_PERMITTED");
        PoolReserve storage reserve = reserves[token];
        require(reserve.isSupported, "UNSUPPORTED_TOKEN");
        if (reserve.feeBps == 0) return 0;
        return (amount * reserve.feeBps + 9999) / 10000;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant returns (bool) {
        PoolReserve storage reserve = reserves[token];
        require(reserve.isSupported, "UNSUPPORTED_TOKEN");
        require(!reserve.isPaused, "POOL_TEMPORARILY_PAUSED");
        require(amount > 0, "ZERO_AMOUNT_NOT_PERMITTED");

        uint256 maxLoan = IERC20(token).balanceOf(address(this)) - reserve.accruedProtocolFees;
        require(amount <= maxLoan, "INSUFFICIENT_LIQUIDITY");

        uint256 fee = flashFee(token, amount);
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Optimistic transfer to borrower
        require(IERC20(token).transfer(address(receiver), amount), "TRANSFER_TO_BORROWER_FAILED");

        // Execute ERC-3156 borrower callback
        bytes32 callbackResult = receiver.onFlashLoan(msg.sender, token, amount, fee, data);
        require(callbackResult == CALLBACK_SUCCESS, "ERC3156_CALLBACK_FAILED");

        // Repayment verification: check if balance is already restored, else attempt transferFrom
        uint256 balanceCurrent = IERC20(token).balanceOf(address(this));
        if (balanceCurrent < balanceBefore + fee) {
            uint256 deficit = (balanceBefore + fee) - balanceCurrent;
            require(IERC20(token).transferFrom(address(receiver), address(this), deficit), "TRANSFER_FROM_FAILED");
        }

        // STRICT INVARIANT ENFORCEMENT: Final balance must be >= balanceBefore + fee
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(balanceAfter >= balanceBefore + fee, "REPAYMENT_INSUFFICIENT_OR_FAILED");

        // Compute fee split
        uint256 protocolFee = (fee * protocolShareBps) / 10000;
        uint256 poolFee = fee - protocolFee;

        // Accounting invariants: pool fee compounds LP reserve, protocol fee accrues to treasury
        reserve.totalLiquidity += poolFee;
        reserve.accruedProtocolFees += protocolFee;

        emit FlashLoanExecuted(address(receiver), token, amount, fee, protocolFee, poolFee);

        return true;
    }

    function withdrawProtocolFees(address token, address to) external onlyOwner nonReentrant {
        require(to != address(0), "INVALID_RECIPIENT");
        PoolReserve storage reserve = reserves[token];
        require(reserve.isSupported, "UNSUPPORTED_TOKEN");
        uint256 fees = reserve.accruedProtocolFees;
        require(fees > 0, "NO_FEES_TO_WITHDRAW");

        reserve.accruedProtocolFees = 0;
        require(IERC20(token).transfer(to, fees), "FEE_TRANSFER_FAILED");

        emit ProtocolFeesWithdrawn(token, to, fees);
    }
}

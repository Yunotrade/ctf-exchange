// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

/// @title GrossBudgetFeeMath — YunoTrade v1.1.0 collateral fee helpers
/// @notice Canonical integer math matching Phase C locked model. No share fees.
library GrossBudgetFeeMath {
    uint256 internal constant BPS_DIVISOR = 10_000;

    error InvalidScale();
    error InvalidPrice();
    error InvalidOrder();

    struct BuyFillInput {
        uint256 q;
        uint256 pi;
        uint256 f;
        uint256 feeRateBps;
        uint256 S;
        /// @dev Signed BUY makerAmount: fee-exclusive notional budget N.
        uint256 M;
        uint256 T;
        /// @dev Cumulative executed notional (not N+f).
        uint256 BUsed;
        uint256 delivered;
        uint256 HPrev;
    }

    struct SellFillInput {
        uint256 q;
        uint256 pi;
        uint256 f;
        uint256 feeRateBps;
        uint256 S;
        uint256 M;
        uint256 T;
        uint256 filledShares;
        uint256 PUsed;
        uint256 HPrev;
    }

    struct FillResult {
        uint256 notional; // N or P
        uint256 settlement; // b (BUY) or R (SELL)
        uint256 HAfter;
        uint256 dCap;
    }

    function executionCollateral(uint256 q, uint256 pi, uint256 S) internal pure returns (uint256) {
        if (S == 0) revert InvalidScale();
        return (q * pi) / S;
    }

    function feeBasisNumerator(uint256 q, uint256 pi, uint256 S) internal pure returns (uint256) {
        if (pi == 0 || pi >= S) revert InvalidPrice();
        uint256 oneMinus = S - pi;
        uint256 m = pi < oneMinus ? pi : oneMinus;
        return q * m;
    }

    function cumulativeCap(uint256 H, uint256 feeRateBps, uint256 S) internal pure returns (uint256) {
        if (S == 0) revert InvalidScale();
        return (H * feeRateBps) / (S * BPS_DIVISOR);
    }

    function deltaCap(uint256 HPrev, uint256 HAfter, uint256 feeRateBps, uint256 S) internal pure returns (uint256) {
        return cumulativeCap(HAfter, feeRateBps, S) - cumulativeCap(HPrev, feeRateBps, S);
    }

    /// @dev ceil(z * T / M)
    function minOut(uint256 z, uint256 T, uint256 M) internal pure returns (uint256) {
        if (M == 0) revert InvalidOrder();
        if (z == 0) return 0;
        return (z * T + (M - 1)) / M;
    }

    function complementNotionals(uint256 q, uint256 pi, uint256 S) internal pure returns (uint256 nYes, uint256 nNo) {
        nYes = executionCollateral(q, pi, S);
        nNo = q - nYes;
    }

    function validateBuyFill(BuyFillInput memory i) internal pure returns (FillResult memory r) {
        require(i.q > 0, "ZeroShares");
        return validateBuyFillWithNotional(i, executionCollateral(i.q, i.pi, i.S));
    }

    /// @dev Validates a BUY using a caller-derived notional. Used for the second leg of exact complement settlement.
    function validateBuyFillWithNotional(BuyFillInput memory i, uint256 notional)
        internal
        pure
        returns (FillResult memory r)
    {
        require(i.q > 0, "ZeroShares");
        r.notional = notional;
        require(r.notional > 0, "ZeroNotional");
        r.HAfter = i.HPrev + feeBasisNumerator(i.q, i.pi, i.S);
        r.dCap = deltaCap(i.HPrev, r.HAfter, i.feeRateBps, i.S);
        require(i.f <= r.dCap, "FeeAboveCap");
        r.settlement = r.notional + i.f;
        // Bet-slip budget is notional-only; fee is pulled on top (settlement = N+f) and capped by dCap.
        require(r.notional <= i.M - i.BUsed, "BudgetExceeded");
        require(i.delivered + i.q >= minOut(i.BUsed + r.notional, i.T, i.M), "MinOutFailed");
    }

    function validateSellFill(SellFillInput memory i) internal pure returns (FillResult memory r) {
        require(i.q > 0, "ZeroShares");
        return validateSellFillWithNotional(i, executionCollateral(i.q, i.pi, i.S));
    }

    /// @dev Validates a SELL using a caller-derived notional. Used for the second leg of exact complement settlement.
    function validateSellFillWithNotional(SellFillInput memory i, uint256 notional)
        internal
        pure
        returns (FillResult memory r)
    {
        require(i.q > 0, "ZeroShares");
        require(i.q <= i.M - i.filledShares, "ShareOverfill");
        r.notional = notional;
        require(r.notional > 0, "ZeroNotional");
        r.HAfter = i.HPrev + feeBasisNumerator(i.q, i.pi, i.S);
        r.dCap = deltaCap(i.HPrev, r.HAfter, i.feeRateBps, i.S);
        require(i.f <= r.dCap, "FeeAboveCap");
        require(i.f <= r.notional, "FeeAboveProceeds");
        require(i.PUsed + r.notional >= minOut(i.filledShares + i.q, i.T, i.M), "GrossProceedsFloor");
        r.settlement = r.notional - i.f;
    }
}

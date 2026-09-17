// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

import { Test } from "forge-std/Test.sol";

import { GrossBudgetFeeMath } from "exchange/libraries/GrossBudgetFeeMath.sol";

/// @dev External wrapper so vm.expectRevert sees a nested call (library is inlined otherwise).
contract GrossBudgetFeeMathHarness {
    function validateBuy(GrossBudgetFeeMath.BuyFillInput memory i)
        external
        pure
        returns (GrossBudgetFeeMath.FillResult memory)
    {
        return GrossBudgetFeeMath.validateBuyFill(i);
    }

    function validateSell(GrossBudgetFeeMath.SellFillInput memory i)
        external
        pure
        returns (GrossBudgetFeeMath.FillResult memory)
    {
        return GrossBudgetFeeMath.validateSellFill(i);
    }
}

contract GrossBudgetFeeMathTest is Test {
    uint256 internal constant S = 1e18;
    GrossBudgetFeeMathHarness internal harness;

    function setUp() public {
        harness = new GrossBudgetFeeMathHarness();
    }

    function testExecutionCollateralAtFortyCents() public {
        uint256 q = 100_000_000;
        uint256 pi = 4e17;
        assertEq(GrossBudgetFeeMath.executionCollateral(q, pi, S), 40_000_000);
    }

    function testComplementSumsToQ(uint64 qRaw, uint128 piRaw) public {
        uint256 q = uint256(qRaw) + 1;
        uint256 pi = bound(uint256(piRaw), 1, S - 1);
        (uint256 nYes, uint256 nNo) = GrossBudgetFeeMath.complementNotionals(q, pi, S);
        assertEq(nYes + nNo, q);
        assertEq(nYes, GrossBudgetFeeMath.executionCollateral(q, pi, S));
    }

    function testDeltaCapTelescopes() public {
        uint256 r = 1000;
        uint256 q = 100_000_000;
        uint256 pi = 4e17;
        uint256 h1 = GrossBudgetFeeMath.feeBasisNumerator(q, pi, S);
        uint256 d1 = GrossBudgetFeeMath.deltaCap(0, h1, r, S);
        uint256 d2 = GrossBudgetFeeMath.deltaCap(h1, 2 * h1, r, S);
        assertEq(d1 + d2, GrossBudgetFeeMath.cumulativeCap(2 * h1, r, S));
    }

    function testPartialFillCapSplitInvariant() public {
        uint256 r = 1000;
        uint256 pi = 4e17;
        uint256 q1 = 40_000_000;
        uint256 q2 = 60_000_000;
        uint256 h1 = GrossBudgetFeeMath.feeBasisNumerator(q1, pi, S);
        uint256 h2 = GrossBudgetFeeMath.feeBasisNumerator(q2, pi, S);
        uint256 hFull = GrossBudgetFeeMath.feeBasisNumerator(q1 + q2, pi, S);
        assertEq(h1 + h2, hFull);
        uint256 d1 = GrossBudgetFeeMath.deltaCap(0, h1, r, S);
        uint256 d2 = GrossBudgetFeeMath.deltaCap(h1, h1 + h2, r, S);
        assertEq(d1 + d2, GrossBudgetFeeMath.cumulativeCap(hFull, r, S));
    }

    function testBuyFillAtCapSucceeds() public {
        uint256 q = 100_000_000;
        uint256 pi = 4e17;
        uint256 r = 1000;
        uint256 hk = GrossBudgetFeeMath.feeBasisNumerator(q, pi, S);
        uint256 f = GrossBudgetFeeMath.cumulativeCap(hk, r, S);
        uint256 n = GrossBudgetFeeMath.executionCollateral(q, pi, S);
        GrossBudgetFeeMath.FillResult memory res = GrossBudgetFeeMath.validateBuyFill(
            GrossBudgetFeeMath.BuyFillInput({
                q: q,
                pi: pi,
                f: f,
                feeRateBps: r,
                S: S,
                M: n,
                T: q,
                BUsed: 0,
                delivered: 0,
                HPrev: 0
            })
        );
        assertEq(res.notional, n);
        assertEq(res.settlement, n + f);
        assertEq(res.dCap, f);
        assertEq(res.HAfter, hk);
    }

    function testBuyNotionalBudgetAllowsFeeOnTop() public {
        // Distinct from at-cap: signed ceiling 1000 bps, charged 30 bps, M still equals N.
        uint256 q = 100_000_000;
        uint256 pi = 4e17;
        uint256 rSigned = 1000;
        uint256 rActual = 30;
        uint256 n = GrossBudgetFeeMath.executionCollateral(q, pi, S);
        uint256 hk = GrossBudgetFeeMath.feeBasisNumerator(q, pi, S);
        uint256 f = GrossBudgetFeeMath.cumulativeCap(hk, rActual, S);
        assertEq(f, 120_000);
        GrossBudgetFeeMath.FillResult memory res = GrossBudgetFeeMath.validateBuyFill(
            GrossBudgetFeeMath.BuyFillInput({
                q: q,
                pi: pi,
                f: f,
                feeRateBps: rSigned,
                S: S,
                M: n,
                T: q,
                BUsed: 0,
                delivered: 0,
                HPrev: 0
            })
        );
        assertEq(res.notional, n);
        assertEq(res.settlement, n + f);
        assertGt(res.dCap, f);
    }

    function testBuyFeeAboveCapReverts() public {
        uint256 q = 100_000_000;
        uint256 pi = 4e17;
        uint256 r = 1000;
        uint256 hk = GrossBudgetFeeMath.feeBasisNumerator(q, pi, S);
        uint256 f = GrossBudgetFeeMath.cumulativeCap(hk, r, S) + 1;
        uint256 n = GrossBudgetFeeMath.executionCollateral(q, pi, S);
        vm.expectRevert(bytes("FeeAboveCap"));
        harness.validateBuy(
            GrossBudgetFeeMath.BuyFillInput({
                q: q,
                pi: pi,
                f: f,
                feeRateBps: r,
                S: S,
                M: n + f + 10,
                T: q,
                BUsed: 0,
                delivered: 0,
                HPrev: 0
            })
        );
    }

    function testBuyBudgetExceededReverts() public {
        uint256 q = 100_000_000;
        uint256 pi = 4e17;
        uint256 n = GrossBudgetFeeMath.executionCollateral(q, pi, S);
        vm.expectRevert(bytes("BudgetExceeded"));
        harness.validateBuy(
            GrossBudgetFeeMath.BuyFillInput({
                q: q,
                pi: pi,
                f: 0,
                feeRateBps: 0,
                S: S,
                M: n - 1,
                T: q,
                BUsed: 0,
                delivered: 0,
                HPrev: 0
            })
        );
    }

    function testBuyMinOutReverts() public {
        // Signed notional 0.40; fill at 0.50 so MinOut fails.
        vm.expectRevert(bytes("MinOutFailed"));
        harness.validateBuy(
            GrossBudgetFeeMath.BuyFillInput({
                q: 50_000_000,
                pi: 5e17,
                f: 0,
                feeRateBps: 0,
                S: S,
                M: 40_000_000,
                T: 100_000_000,
                BUsed: 0,
                delivered: 0,
                HPrev: 0
            })
        );
    }

    function testSellFillNetProceeds() public {
        uint256 q = 100_000_000;
        uint256 pi = 4e17;
        uint256 r = 1000;
        uint256 hk = GrossBudgetFeeMath.feeBasisNumerator(q, pi, S);
        uint256 f = GrossBudgetFeeMath.cumulativeCap(hk, r, S);
        uint256 P = GrossBudgetFeeMath.executionCollateral(q, pi, S);
        GrossBudgetFeeMath.FillResult memory res = GrossBudgetFeeMath.validateSellFill(
            GrossBudgetFeeMath.SellFillInput({
                q: q,
                pi: pi,
                f: f,
                feeRateBps: r,
                S: S,
                M: q,
                T: P,
                filledShares: 0,
                PUsed: 0,
                HPrev: 0
            })
        );
        assertEq(res.notional, P);
        assertEq(res.settlement + f, P);
    }

    function testSellFeeAboveProceedsReverts() public {
        // With r=10000, Cap can exceed P by 1 across a floor boundary; f=P+1 hits FeeAboveProceeds.
        uint256 q = 2 * S + 1;
        uint256 pi = 1;
        uint256 P = GrossBudgetFeeMath.executionCollateral(q, pi, S);
        assertEq(P, 2);
        uint256 HPrev = S - 1;
        uint256 hk = GrossBudgetFeeMath.feeBasisNumerator(q, pi, S);
        uint256 dCap = GrossBudgetFeeMath.deltaCap(HPrev, HPrev + hk, 10_000, S);
        assertGe(dCap, P + 1);
        vm.expectRevert(bytes("FeeAboveProceeds"));
        harness.validateSell(
            GrossBudgetFeeMath.SellFillInput({
                q: q,
                pi: pi,
                f: P + 1,
                feeRateBps: 10_000,
                S: S,
                M: q,
                T: P,
                filledShares: 0,
                PUsed: 0,
                HPrev: HPrev
            })
        );
    }

    function testFuzzComplementNeverIndependentLoss(uint64 qRaw, uint128 piRaw) public {
        uint256 q = uint256(qRaw) % 1_000_000 + 1;
        uint256 pi = bound(uint256(piRaw), 1, S - 1);
        (uint256 a, uint256 b) = GrossBudgetFeeMath.complementNotionals(q, pi, S);
        assertEq(a + b, q);
    }

    function testFuzzDeltaCapNonNegative(uint128 HPrev, uint128 add, uint16 r) public {
        vm.assume(r <= 10_000);
        uint256 HAfter = uint256(HPrev) + uint256(add);
        uint256 d = GrossBudgetFeeMath.deltaCap(HPrev, HAfter, r, S);
        assertGe(GrossBudgetFeeMath.cumulativeCap(HAfter, r, S), GrossBudgetFeeMath.cumulativeCap(HPrev, r, S));
        assertEq(d, GrossBudgetFeeMath.cumulativeCap(HAfter, r, S) - GrossBudgetFeeMath.cumulativeCap(HPrev, r, S));
    }

    function testMinOutCeil() public {
        assertEq(GrossBudgetFeeMath.minOut(0, 100, 40), 0);
        assertEq(GrossBudgetFeeMath.minOut(40, 100, 40), 100);
        assertEq(GrossBudgetFeeMath.minOut(20, 100, 40), 50);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

import { BaseExchangeTest } from "exchange/test/BaseExchangeTest.sol";

import { IFeesEE } from "exchange/interfaces/IFees.sol";
import { Order, Side, FeeFill } from "exchange/libraries/OrderStructs.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC1155 } from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";

contract MatchOrdersWithFeesTest is BaseExchangeTest {
    uint256 internal constant S = 1e18;
    uint256 internal constant Q = 100_000_000;
    uint256 internal constant PI = 4e17;
    uint256 internal constant F = 4_000_000;
    uint256 internal constant N = 40_000_000;
    uint256 internal constant R_BPS = 1000;
    address internal feeRecipient = address(0xFEE);

    function setUp() public override {
        super.setUp();
        _fundCollateral(bob, 200_000_000);
        _mintTestTokens(carla, address(exchange), 200_000_000);
        _fundCollateral(carla, 200_000_000);
        vm.startPrank(admin);
        exchange.setFeeRecipient(feeRecipient);
        exchange.enableV11Only();
        vm.stopPrank();
    }

    function _fundCollateral(address who, uint256 amount) internal {
        deal(address(usdc), who, amount);
        vm.prank(who);
        IERC20(address(usdc)).approve(address(exchange), type(uint256).max);
        vm.prank(who);
        IERC1155(address(ctf)).setApprovalForAll(address(exchange), true);
    }

    function testFeeRecipientCannotBeReassigned() public {
        vm.prank(admin);
        vm.expectRevert(IFeesEE.FeeRecipientAlreadySet.selector);
        exchange.setFeeRecipient(address(0xBEEF));

        assertEq(exchange.getFeeRecipient(), feeRecipient);
    }

    function testComplementaryBuySellAtCap() public {
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, N, Q, R_BPS, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, Q, N, R_BPS, Side.SELL);

        Order[] memory makers = new Order[](1);
        makers[0] = sell;
        FeeFill memory takerFill = FeeFill({ q: Q, pi: PI, f: F });
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: Q, pi: PI, f: F });

        uint256 bobColBefore = usdc.balanceOf(bob);
        uint256 carlaColBefore = usdc.balanceOf(carla);
        uint256 operatorColBefore = usdc.balanceOf(admin);
        uint256 feeRecipientColBefore = usdc.balanceOf(feeRecipient);
        uint256 bobYesBefore = getCTFBalance(bob, yes);
        uint256 carlaYesBefore = getCTFBalance(carla, yes);

        vm.prank(admin);
        exchange.matchOrdersWithFees(buy, makers, takerFill, makerFills);

        assertEq(usdc.balanceOf(bob), bobColBefore - (N + F));
        assertEq(getCTFBalance(bob, yes), bobYesBefore + Q);
        assertEq(usdc.balanceOf(carla), carlaColBefore + (N - F));
        assertEq(getCTFBalance(carla, yes), carlaYesBefore - Q);
        assertEq(usdc.balanceOf(admin), operatorColBefore);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientColBefore + 2 * F);
        assertEq(usdc.balanceOf(address(exchange)), 0);
        assertEq(getCTFBalance(address(exchange), yes), 0);

        bytes32 buyHash = exchange.hashOrder(buy);
        assertEq(exchange.getOrderFillStateV11(buyHash).BUsed, N);
        assertEq(exchange.getOrderFillStateV11(buyHash).delivered, Q);
        assertTrue(exchange.getOrderFillStateV11(buyHash).isFilledOrCancelled);
    }

    function testComplementaryOneDollarAt53Cents() public {
        _assertExactDollarComplementary(1_000_000, 1_886_792, 53e16, false);
    }

    function testComplementaryFiveDollarsAt54Cents() public {
        _assertExactDollarComplementary(5_000_000, 9_259_259, 54e16, false);
    }

    function testComplementarySellTakerUsesCeil() public {
        _assertExactDollarComplementary(1_000_000, 1_886_792, 53e16, true);
    }

    function _assertExactDollarComplementary(uint256 budget, uint256 q, uint256 pi, bool sellTaker) internal {
        uint256 fee = q * (S - pi) * R_BPS / (S * 10_000);
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, budget, q, R_BPS, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, Q, Q * pi / S, R_BPS, Side.SELL);
        Order[] memory makers = new Order[](1);
        makers[0] = sellTaker ? buy : sell;
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: q, pi: pi, f: fee });
        uint256 bobColBefore = usdc.balanceOf(bob);
        uint256 carlaColBefore = usdc.balanceOf(carla);
        uint256 bobYesBefore = getCTFBalance(bob, yes);
        uint256 carlaYesBefore = getCTFBalance(carla, yes);

        vm.prank(admin);
        exchange.matchOrdersWithFees(sellTaker ? sell : buy, makers, makerFills[0], makerFills);

        assertEq(usdc.balanceOf(bob), bobColBefore - budget - fee);
        assertEq(usdc.balanceOf(carla), carlaColBefore + budget - fee);
        assertEq(getCTFBalance(bob, yes), bobYesBefore + q);
        assertEq(getCTFBalance(carla, yes), carlaYesBefore - q);
        assertEq(exchange.getOrderFillStateV11(exchange.hashOrder(buy)).BUsed, budget);
        assertEq(exchange.getOrderFillStateV11(exchange.hashOrder(sell)).BUsed, budget);
        assertEq(exchange.getOrderFillStateV11(exchange.hashOrder(buy)).delivered, q);
        assertEq(budget, q * pi / S + 1);
        assertEq(usdc.balanceOf(feeRecipient), 2 * fee);
        assertEq(usdc.balanceOf(address(exchange)), 0);
    }

    function testMultiMakerComplementaryCeilsEachSlice() public {
        uint256 q = 1_886_792;
        uint256 pi = 53e16;
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, 2_000_000, 2 * q, 0, Side.BUY);
        Order[] memory makers = new Order[](2);
        makers[0] = _createAndSignOrderWithFee(carlaPK, yes, Q, 53_000_000, 0, Side.SELL);
        makers[1] = _resignWithSalt(_createAndSignOrderWithFee(carlaPK, yes, Q, 53_000_000, 0, Side.SELL), carlaPK, 2);
        FeeFill[] memory makerFills = new FeeFill[](2);
        makerFills[0] = FeeFill({ q: q, pi: pi, f: 0 });
        makerFills[1] = makerFills[0];
        uint256 before = usdc.balanceOf(carla);

        vm.prank(admin);
        exchange.matchOrdersWithFees(buy, makers, FeeFill({ q: 2 * q, pi: pi, f: 0 }), makerFills);

        assertEq(exchange.getOrderFillStateV11(exchange.hashOrder(buy)).BUsed, 2_000_000);
        assertEq(exchange.getOrderFillStateV11(exchange.hashOrder(makers[0])).BUsed, 1_000_000);
        assertEq(exchange.getOrderFillStateV11(exchange.hashOrder(makers[1])).BUsed, 1_000_000);
        assertEq(usdc.balanceOf(carla), before + 2_000_000);
        assertEq(usdc.balanceOf(address(exchange)), 0);
    }

    function testComplementaryGenuinelyBelowSellFloorReverts() public {
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, 1_000_000, 1_886_792, 0, Side.BUY);
        Order[] memory makers = new Order[](1);
        makers[0] = _createAndSignOrderWithFee(carlaPK, yes, Q, 53_000_000, 0, Side.SELL);
        FeeFill[] memory fills = new FeeFill[](1);
        fills[0] = FeeFill({ q: 1_886_792, pi: 52e16, f: 0 });
        vm.prank(admin);
        vm.expectRevert(bytes("GrossProceedsFloor"));
        exchange.matchOrdersWithFees(buy, makers, fills[0], fills);
    }

    function testMintFractionalNotionalKeepsFloorAndRemainder() public {
        uint256 q = 1_886_792;
        uint256 floor = 999_999;
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, floor + 1, q, 0, Side.BUY);
        Order[] memory makers = new Order[](1);
        makers[0] = _createAndSignOrderWithFee(carlaPK, no, q - floor, q, 0, Side.BUY);
        FeeFill[] memory fills = new FeeFill[](1);
        fills[0] = FeeFill({ q: q, pi: 53e16, f: 0 });
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carlaBefore = usdc.balanceOf(carla);

        vm.prank(admin);
        exchange.matchOrdersWithFees(buy, makers, fills[0], fills);

        assertEq(exchange.getOrderFillStateV11(exchange.hashOrder(buy)).BUsed, floor);
        assertEq(exchange.getOrderFillStateV11(exchange.hashOrder(makers[0])).BUsed, q - floor);
        assertEq(bobBefore - usdc.balanceOf(bob), floor);
        assertEq(carlaBefore - usdc.balanceOf(carla), q - floor);
        assertEq(bobBefore + carlaBefore - usdc.balanceOf(bob) - usdc.balanceOf(carla), q);
        assertEq(usdc.balanceOf(address(exchange)), 0);
    }

    function testMultiMakerComplementarySuccess() public {
        uint256 makerQ = Q / 2;
        uint256 makerN = N / 2;
        uint256 makerF = F / 2;
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, N, Q, R_BPS, Side.BUY);
        Order memory sellA = _createAndSignOrderWithFee(carlaPK, yes, makerQ, makerN, R_BPS, Side.SELL);
        Order memory sellB =
            _resignWithSalt(_createAndSignOrderWithFee(carlaPK, yes, makerQ, makerN, R_BPS, Side.SELL), carlaPK, 2);

        Order[] memory makers = new Order[](2);
        makers[0] = sellA;
        makers[1] = sellB;
        FeeFill[] memory makerFills = new FeeFill[](2);
        makerFills[0] = FeeFill({ q: makerQ, pi: PI, f: makerF });
        makerFills[1] = FeeFill({ q: makerQ, pi: PI, f: makerF });

        uint256 bobColBefore = usdc.balanceOf(bob);
        uint256 carlaColBefore = usdc.balanceOf(carla);
        uint256 operatorColBefore = usdc.balanceOf(admin);
        uint256 feeRecipientColBefore = usdc.balanceOf(feeRecipient);
        uint256 bobYesBefore = getCTFBalance(bob, yes);
        uint256 carlaYesBefore = getCTFBalance(carla, yes);

        vm.prank(admin);
        exchange.matchOrdersWithFees(buy, makers, FeeFill({ q: Q, pi: PI, f: F }), makerFills);

        assertEq(usdc.balanceOf(bob), bobColBefore - (N + F));
        assertEq(usdc.balanceOf(carla), carlaColBefore + N - F);
        assertEq(usdc.balanceOf(admin), operatorColBefore);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientColBefore + 2 * F);
        assertEq(getCTFBalance(bob, yes), bobYesBefore + Q);
        assertEq(getCTFBalance(carla, yes), carlaYesBefore - Q);
        assertEq(usdc.balanceOf(address(exchange)), 0);
        assertEq(getCTFBalance(address(exchange), yes), 0);

        assertTrue(exchange.getOrderFillStateV11(exchange.hashOrder(sellA)).isFilledOrCancelled);
        assertTrue(exchange.getOrderFillStateV11(exchange.hashOrder(sellB)).isFilledOrCancelled);
    }

    function testMultiMakerMintConservation() public {
        uint256 makerQ = Q / 2;
        uint256 makerN = (Q - N) / 2;
        uint256 makerF = F / 2;
        Order memory yesBuy = _createAndSignOrderWithFee(bobPK, yes, N, Q, R_BPS, Side.BUY);
        Order memory noBuyA = _createAndSignOrderWithFee(carlaPK, no, makerN, makerQ, R_BPS, Side.BUY);
        Order memory noBuyB = _resignWithSalt(
            _createAndSignOrderWithFee(carlaPK, no, makerN, makerQ, R_BPS, Side.BUY), carlaPK, 2
        );

        Order[] memory makers = new Order[](2);
        makers[0] = noBuyA;
        makers[1] = noBuyB;
        FeeFill[] memory makerFills = new FeeFill[](2);
        makerFills[0] = FeeFill({ q: makerQ, pi: PI, f: makerF });
        makerFills[1] = FeeFill({ q: makerQ, pi: PI, f: makerF });

        uint256 bobColBefore = usdc.balanceOf(bob);
        uint256 carlaColBefore = usdc.balanceOf(carla);
        uint256 operatorColBefore = usdc.balanceOf(admin);
        uint256 feeRecipientColBefore = usdc.balanceOf(feeRecipient);
        uint256 bobYesBefore = getCTFBalance(bob, yes);
        uint256 carlaNoBefore = getCTFBalance(carla, no);

        vm.prank(admin);
        exchange.matchOrdersWithFees(yesBuy, makers, FeeFill({ q: Q, pi: PI, f: F }), makerFills);

        assertEq(usdc.balanceOf(bob), bobColBefore - (N + F));
        assertEq(usdc.balanceOf(carla), carlaColBefore - ((Q - N) + F));
        assertEq(usdc.balanceOf(admin), operatorColBefore);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientColBefore + 2 * F);
        assertEq(getCTFBalance(bob, yes), bobYesBefore + Q);
        assertEq(getCTFBalance(carla, no), carlaNoBefore + Q);
        assertEq(usdc.balanceOf(address(exchange)), 0);
        assertEq(getCTFBalance(address(exchange), yes), 0);
        assertEq(getCTFBalance(address(exchange), no), 0);
    }

    function testMultiMakerMergeConservation() public {
        uint256 makerQ = Q / 2;
        uint256 makerP = (Q - N) / 2;
        uint256 makerF = F / 2;
        _mintTestTokens(bob, address(exchange), 2 * Q);

        Order memory yesSell = _createAndSignOrderWithFee(bobPK, yes, Q, N, R_BPS, Side.SELL);
        Order memory noSellA = _createAndSignOrderWithFee(carlaPK, no, makerQ, makerP, R_BPS, Side.SELL);
        Order memory noSellB =
            _resignWithSalt(_createAndSignOrderWithFee(carlaPK, no, makerQ, makerP, R_BPS, Side.SELL), carlaPK, 2);

        Order[] memory makers = new Order[](2);
        makers[0] = noSellA;
        makers[1] = noSellB;
        FeeFill[] memory makerFills = new FeeFill[](2);
        makerFills[0] = FeeFill({ q: makerQ, pi: PI, f: makerF });
        makerFills[1] = FeeFill({ q: makerQ, pi: PI, f: makerF });

        uint256 bobColBefore = usdc.balanceOf(bob);
        uint256 carlaColBefore = usdc.balanceOf(carla);
        uint256 operatorColBefore = usdc.balanceOf(admin);
        uint256 feeRecipientColBefore = usdc.balanceOf(feeRecipient);
        uint256 bobYesBefore = getCTFBalance(bob, yes);
        uint256 carlaNoBefore = getCTFBalance(carla, no);

        vm.prank(admin);
        exchange.matchOrdersWithFees(yesSell, makers, FeeFill({ q: Q, pi: PI, f: F }), makerFills);

        assertEq(usdc.balanceOf(bob), bobColBefore + N - F);
        assertEq(usdc.balanceOf(carla), carlaColBefore + (Q - N) - F);
        assertEq(usdc.balanceOf(admin), operatorColBefore);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientColBefore + 2 * F);
        assertEq(getCTFBalance(bob, yes), bobYesBefore - Q);
        assertEq(getCTFBalance(carla, no), carlaNoBefore - Q);
        assertEq(usdc.balanceOf(address(exchange)), 0);
        assertEq(getCTFBalance(address(exchange), yes), 0);
        assertEq(getCTFBalance(address(exchange), no), 0);
    }

    function testMakerLengthMismatchReverts() public {
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, N, Q, R_BPS, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, Q, N, R_BPS, Side.SELL);
        Order[] memory makers = new Order[](1);
        makers[0] = sell;
        FeeFill[] memory makerFills = new FeeFill[](0);

        vm.prank(admin);
        vm.expectRevert(LengthMismatch.selector);
        exchange.matchOrdersWithFees(buy, makers, FeeFill({ q: Q, pi: PI, f: F }), makerFills);
    }

    function testRepeatedMakerHashRevertsBeforeMovingFunds() public {
        uint256 makerQ = Q / 2;
        uint256 makerN = N / 2;
        uint256 makerF = F / 2;
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, N, Q, R_BPS, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, makerQ, makerN, R_BPS, Side.SELL);
        Order[] memory makers = new Order[](2);
        makers[0] = sell;
        makers[1] = sell;
        FeeFill[] memory makerFills = new FeeFill[](2);
        makerFills[0] = FeeFill({ q: makerQ, pi: PI, f: makerF });
        makerFills[1] = FeeFill({ q: makerQ, pi: PI, f: makerF });

        uint256 bobColBefore = usdc.balanceOf(bob);
        uint256 carlaColBefore = usdc.balanceOf(carla);
        vm.prank(admin);
        vm.expectRevert(RepeatedOrderHash.selector);
        exchange.matchOrdersWithFees(buy, makers, FeeFill({ q: Q, pi: PI, f: F }), makerFills);

        assertEq(usdc.balanceOf(bob), bobColBefore);
        assertEq(usdc.balanceOf(carla), carlaColBefore);
        assertEq(usdc.balanceOf(feeRecipient), 0);
    }

    function testV11OnlyDisablesLegacyMatchOrders() public {
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, N, Q, R_BPS, Side.BUY);
        Order[] memory makers = new Order[](0);
        uint256[] memory makerFills = new uint256[](0);

        vm.prank(admin);
        vm.expectRevert(LegacyTradingDisabled.selector);
        exchange.matchOrders(buy, makers, N, makerFills);
    }

    function testEmptyMakerBatchReverts() public {
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, N, Q, R_BPS, Side.BUY);
        Order[] memory makers = new Order[](0);
        FeeFill[] memory makerFills = new FeeFill[](0);

        vm.prank(admin);
        vm.expectRevert(LengthMismatch.selector);
        exchange.matchOrdersWithFees(buy, makers, FeeFill({ q: Q, pi: PI, f: F }), makerFills);
    }

    function testFeeAboveCapReverts() public {
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, 10 ** 18, Q, R_BPS, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, Q, N, R_BPS, Side.SELL);
        Order[] memory makers = new Order[](1);
        makers[0] = sell;
        FeeFill memory takerFill = FeeFill({ q: Q, pi: PI, f: F + 1 });
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: Q, pi: PI, f: 0 });

        uint256 bobColBefore = usdc.balanceOf(bob);
        vm.prank(admin);
        vm.expectRevert(bytes("FeeAboveCap"));
        exchange.matchOrdersWithFees(buy, makers, takerFill, makerFills);
        assertEq(usdc.balanceOf(bob), bobColBefore);
    }

    function testBudgetExceededReverts() public {
        // Crossing at 0.30; fill at 0.40 needs N=40e6 > BUY budget 30e6
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, 30_000_000, Q, 0, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, Q, 30_000_000, 0, Side.SELL);
        Order[] memory makers = new Order[](1);
        makers[0] = sell;
        FeeFill memory takerFill = FeeFill({ q: Q, pi: PI, f: 0 });
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: Q, pi: PI, f: 0 });

        vm.prank(admin);
        vm.expectRevert(bytes("BudgetExceeded"));
        exchange.matchOrdersWithFees(buy, makers, takerFill, makerFills);
    }

    function testMinOutFailedReverts() public {
        // Signed notional 0.40 both sides (crossing); operator supplies worse pi=0.50
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, 40_000_000, 100_000_000, 0, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, 100_000_000, 40_000_000, 0, Side.SELL);
        Order[] memory makers = new Order[](1);
        makers[0] = sell;
        FeeFill memory takerFill = FeeFill({ q: 50_000_000, pi: 5e17, f: 0 });
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: 50_000_000, pi: 5e17, f: 0 });

        vm.prank(admin);
        vm.expectRevert(bytes("MinOutFailed"));
        exchange.matchOrdersWithFees(buy, makers, takerFill, makerFills);
    }

    function testSellFeeAboveProceedsReverts() public {
        uint256 q = 2 * S + 1;
        uint256 pi = 1;
        uint256 P = (q * pi) / S;
        _mintTestTokens(carla, address(exchange), q * 2);
        _fundCollateral(bob, q);

        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, 10 ** 18, q, 10_000, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, q, P, 10_000, Side.SELL);
        Order[] memory makers = new Order[](1);
        makers[0] = sell;
        FeeFill memory takerFill = FeeFill({ q: q, pi: pi, f: 0 });
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: q, pi: pi, f: P + 1 });

        vm.prank(admin);
        vm.expectRevert();
        exchange.matchOrdersWithFees(buy, makers, takerFill, makerFills);
    }

    function testMintComplementConservation() public {
        Order memory yesBuy = _createAndSignOrderWithFee(bobPK, yes, N, Q, R_BPS, Side.BUY);
        Order memory noBuy = _createAndSignOrderWithFee(carlaPK, no, Q - N, Q, R_BPS, Side.BUY);

        Order[] memory makers = new Order[](1);
        makers[0] = noBuy;
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: Q, pi: PI, f: F });

        uint256 bobColBefore = usdc.balanceOf(bob);
        uint256 carlaColBefore = usdc.balanceOf(carla);
        uint256 carlaNoBefore = getCTFBalance(carla, no);

        vm.prank(admin);
        exchange.matchOrdersWithFees(yesBuy, makers, FeeFill({ q: Q, pi: PI, f: F }), makerFills);

        assertEq(usdc.balanceOf(bob), bobColBefore - (N + F));
        assertEq(usdc.balanceOf(carla), carlaColBefore - ((Q - N) + F));
        assertEq(getCTFBalance(bob, yes), Q);
        assertEq(getCTFBalance(carla, no), carlaNoBefore + Q);
        assertEq(usdc.balanceOf(address(exchange)), 0);
    }

    function testBuyFeeOnTopOfSignedNotional() public {
        deal(address(usdc), bob, N + F);
        vm.prank(bob);
        IERC20(address(usdc)).approve(address(exchange), type(uint256).max);

        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, N, Q, R_BPS, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, Q, N, R_BPS, Side.SELL);

        Order[] memory makers = new Order[](1);
        makers[0] = sell;
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: Q, pi: PI, f: F });

        uint256 bobColBefore = usdc.balanceOf(bob);
        uint256 bobYesBefore = getCTFBalance(bob, yes);
        uint256 feeRecipientColBefore = usdc.balanceOf(feeRecipient);

        vm.prank(admin);
        exchange.matchOrdersWithFees(buy, makers, FeeFill({ q: Q, pi: PI, f: F }), makerFills);

        assertEq(usdc.balanceOf(bob), bobColBefore - (N + F));
        assertEq(getCTFBalance(bob, yes), bobYesBefore + Q);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientColBefore + 2 * F);

        bytes32 buyHash = exchange.hashOrder(buy);
        assertEq(exchange.getOrderFillStateV11(buyHash).BUsed, N);
        assertEq(exchange.getOrderFillStateV11(buyHash).delivered, Q);
        assertTrue(exchange.getOrderFillStateV11(buyHash).isFilledOrCancelled);
        assertEq(exchange.getOrderStatus(buyHash).remaining, 0);
    }

    function testBuyCompletesWhenSharesDeliveredBelowLimit() public {
        uint256 limitN = 40_000_000;
        uint256 fillPi = 3e17;
        uint256 fillN = 30_000_000;
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, limitN, Q, 0, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, Q, fillN, 0, Side.SELL);

        Order[] memory makers = new Order[](1);
        makers[0] = sell;
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: Q, pi: fillPi, f: 0 });

        vm.prank(admin);
        exchange.matchOrdersWithFees(buy, makers, FeeFill({ q: Q, pi: fillPi, f: 0 }), makerFills);

        bytes32 buyHash = exchange.hashOrder(buy);
        assertEq(exchange.getOrderFillStateV11(buyHash).BUsed, fillN);
        assertLt(exchange.getOrderFillStateV11(buyHash).BUsed, limitN);
        assertEq(exchange.getOrderFillStateV11(buyHash).delivered, Q);
        assertTrue(exchange.getOrderFillStateV11(buyHash).isFilledOrCancelled);
        assertEq(exchange.getOrderStatus(buyHash).remaining, 0);
    }

    function testBuyShareOverfillReverts() public {
        Order memory buy = _createAndSignOrderWithFee(bobPK, yes, N, Q, 0, Side.BUY);
        Order memory sell = _createAndSignOrderWithFee(carlaPK, yes, Q + 1, N, 0, Side.SELL);
        Order[] memory makers = new Order[](1);
        makers[0] = sell;
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = FeeFill({ q: Q + 1, pi: PI, f: 0 });

        vm.prank(admin);
        vm.expectRevert(ShareOverfill.selector);
        exchange.matchOrdersWithFees(buy, makers, FeeFill({ q: Q + 1, pi: PI, f: 0 }), makerFills);
    }

    function _resignWithSalt(Order memory order, uint256 pk, uint256 salt) internal returns (Order memory) {
        order.salt = salt;
        order.signature = _signMessage(pk, exchange.hashOrder(order));
        return order;
    }
}

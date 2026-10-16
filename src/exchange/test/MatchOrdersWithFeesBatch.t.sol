// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

import { BaseExchangeTest } from "exchange/test/BaseExchangeTest.sol";
import { CTFExchange } from "exchange/CTFExchange.sol";
import { Order, Side, FeeFill, OrderFillStateV11, SignatureType } from "exchange/libraries/OrderStructs.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC1155 } from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";

contract MatchOrdersWithFeesBatchTest is BaseExchangeTest {
    uint256 internal constant Q_MINT = 5_747_126;
    uint256 internal constant TAKER_MINT_SLICE = 4_999_999;
    uint256 internal constant MAKER_MINT_SLICE = 747_127;
    uint256 internal constant Q_COMP = 10_000_001;
    uint256 internal constant COMP_SLICE = 4_000_001;
    uint256 internal constant COMP_LIMIT_COLLATERAL = 4_000_000;
    uint256 internal constant TAKER_LIMIT_COLLATERAL = 13_700_001;
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant PI_HALF = 5e17;
    uint256 internal constant FEE_Q = 300;
    uint256 internal constant FEE_TAKER_SHARES = 600;
    uint256 internal constant FEE_SLICE = 150;
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant PI_MINT = 87e16;
    uint256 internal constant PI_COMP = 4e17;
    uint256 internal constant TWO_MINT_COLLATERAL = 10_000_000;
    uint256 internal constant SELL_SHARES = 20_000_000;
    uint256 internal constant SELL_COLLATERAL = 8_000_000;
    uint256 internal constant LEG_SHARES = 10_000_000;
    uint256 internal constant LEG_BUY_COLLATERAL = 4_000_000;
    uint256 internal constant LEG_MERGE_COLLATERAL = 6_000_000;
    uint256 internal constant SELL_TOKEN_FUND = 40_000_000;
    uint256 internal constant ACCOUNT_FUND = 200_000_000;
    address internal feeRecipient = address(0xFEE);

    function setUp() public override {
        super.setUp();
        _fundCollateral(bob, ACCOUNT_FUND);
        _mintTestTokens(carla, address(exchange), ACCOUNT_FUND);
        _fundCollateral(carla, ACCOUNT_FUND);
        vm.startPrank(admin);
        exchange.setFeeRecipient(feeRecipient);
        exchange.enableV11Only();
        vm.stopPrank();
    }

    function test_batch_complementaryThenMint_matchesIsolatedCalls() public {
        (Order memory taker, Order[] memory compMakers, FeeFill memory compTaker, FeeFill[] memory compFills,
            Order[] memory mintMakers, FeeFill memory mintTaker, FeeFill[] memory mintFills) = _complementaryThenMint();
        _assertBatchMatchesIsolated(taker, compMakers, compTaker, compFills, mintMakers, mintTaker, mintFills);
    }

    function test_batch_twoSingletonMints_keepPhaseZero() public {
        (Order memory taker, Order[] memory firstMakers, FeeFill memory firstTaker, FeeFill[] memory firstFills,
            Order[] memory secondMakers, FeeFill memory secondTaker, FeeFill[] memory secondFills) = _twoMints();
        uint256 snap = vm.snapshot();
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carlaBefore = usdc.balanceOf(carla);
        _batch(taker, firstMakers, firstTaker, firstFills, secondMakers, secondTaker, secondFills);
        assertEq(bobBefore - usdc.balanceOf(bob), 2 * TAKER_MINT_SLICE);
        assertEq(carlaBefore - usdc.balanceOf(carla), 2 * MAKER_MINT_SLICE);
        assertEq(usdc.balanceOf(address(exchange)), 0);
        vm.revertTo(snap);
        _assertBatchMatchesIsolated(taker, firstMakers, firstTaker, firstFills, secondMakers, secondTaker, secondFills);
    }

    function test_batch_complementaryBeforeFractionalMint_doesNotLeakQuantityBefore() public {
        (Order memory taker, Order[] memory compMakers, FeeFill memory compTaker, FeeFill[] memory compFills,
            Order[] memory mintMakers, FeeFill memory mintTaker, FeeFill[] memory mintFills) = _complementaryThenMint();
        _batch(taker, compMakers, compTaker, compFills, mintMakers, mintTaker, mintFills);
        uint256 compH = Q_COMP * PI_COMP * (SCALE - PI_COMP);
        uint256 mintH = Q_MINT * PI_MINT * (SCALE - PI_MINT);
        _assertState(
            exchange.getOrderFillStateV11(exchange.hashOrder(taker)),
            OrderFillStateV11({
                initialized: true,
                isFilledOrCancelled: true,
                BUsed: COMP_SLICE + TAKER_MINT_SLICE,
                delivered: Q_COMP + Q_MINT,
                filledShares: 0,
                H: compH + mintH
            })
        );
        _assertState(
            exchange.getOrderFillStateV11(exchange.hashOrder(mintMakers[0])),
            OrderFillStateV11({
                initialized: true,
                isFilledOrCancelled: true,
                BUsed: MAKER_MINT_SLICE,
                delivered: Q_MINT,
                filledShares: 0,
                H: mintH
            })
        );
        _assertState(
            exchange.getOrderFillStateV11(exchange.hashOrder(compMakers[0])),
            OrderFillStateV11({
                initialized: true,
                isFilledOrCancelled: true,
                BUsed: COMP_SLICE,
                delivered: 0,
                filledShares: Q_COMP,
                H: compH
            })
        );
    }

    function test_batch_sellComplementaryThenMerge_matchesIsolatedCalls() public {
        _mintTestTokens(bob, address(exchange), SELL_TOKEN_FUND);
        (Order memory taker, Order[] memory compMakers, FeeFill memory compTaker, FeeFill[] memory compFills,
            Order[] memory mergeMakers, FeeFill memory mergeTaker, FeeFill[] memory mergeFills) = _sellThenMerge();
        _assertBatchMatchesIsolated(taker, compMakers, compTaker, compFills, mergeMakers, mergeTaker, mergeFills);
    }

    function test_batch_feeCapCarriesAcrossGroups() public {
        uint256 accepted = vm.snapshot();
        _feeCapGroups(0);
        _assertFeeCapFilled();

        vm.revertTo(accepted);
        _feeCapGroups(1);
        _assertFeeCapFilled();

        vm.revertTo(accepted);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carlaBefore = usdc.balanceOf(carla);
        (Order memory taker, Order[][] memory makers, FeeFill[] memory takerFills, FeeFill[][] memory makerFills) =
            _feeCapBatch(2);
        vm.prank(admin);
        vm.expectRevert(bytes("FeeAboveCap"));
        exchange.matchOrdersWithFeesBatch(taker, makers, takerFills, makerFills);
        assertEq(usdc.balanceOf(bob), bobBefore);
        assertEq(usdc.balanceOf(carla), carlaBefore);
        _assertZeroState(_feeCapTakerHash());
        _assertZeroState(_feeCapMakerHash(12));
        _assertZeroState(_feeCapMakerHash(13));
    }

    function test_batch_laterGroupRevert_rollsBackEarlierGroup() public {
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carlaBefore = usdc.balanceOf(carla);
        uint256 bobYesBefore = getCTFBalance(bob, yes);
        bytes32 takerHash = _revertLaterGroup();
        assertEq(usdc.balanceOf(bob), bobBefore);
        assertEq(usdc.balanceOf(carla), carlaBefore);
        assertEq(getCTFBalance(bob, yes), bobYesBefore);
        _assertZeroState(takerHash);
        assertEq(usdc.balanceOf(address(exchange)), 0);
    }

    function _revertLaterGroup() internal returns (bytes32 takerHash) {
        (Order memory taker, Order[] memory compMakers, FeeFill memory compTaker, FeeFill[] memory compFills,,
            FeeFill memory mintTaker,) = _complementaryThenMint();
        Order[] memory badMakers = new Order[](1);
        badMakers[0] = _signed(carlaPK, no, MAKER_MINT_SLICE, Q_MINT, 0, Side.BUY, 9);
        FeeFill[] memory badFills = new FeeFill[](1);
        badFills[0] = FeeFill({ q: Q_MINT, pi: PI_MINT + 1, f: 0 });
        vm.prank(admin);
        vm.expectRevert(MismatchedFillPrice.selector);
        exchange.matchOrdersWithFeesBatch(
            taker, _twoGroups(compMakers, badMakers), _twoFills(compTaker, mintTaker), _twoFillGroups(compFills, badFills)
        );
        takerHash = exchange.hashOrder(taker);
        _assertZeroState(takerHash);
        _assertZeroState(exchange.hashOrder(compMakers[0]));
        _assertZeroState(exchange.hashOrder(badMakers[0]));
    }

    function test_batch_rejectsEmptyOuterArray() public {
        Order memory taker;
        vm.prank(admin);
        vm.expectRevert(LengthMismatch.selector);
        exchange.matchOrdersWithFeesBatch(taker, new Order[][](0), new FeeFill[](0), new FeeFill[][](0));
    }

    function test_batch_revertsForNonOperator() public {
        _expectComplementaryThenMint(address(0x1234), NotOperator.selector);
    }

    function test_batch_revertsWhenPaused() public {
        vm.prank(admin);
        exchange.pauseTrading();
        _expectComplementaryThenMint(admin, Paused.selector);
    }

    function _expectComplementaryThenMint(address caller, bytes4 reason) internal {
        (Order memory taker, Order[] memory compMakers, FeeFill memory compTaker, FeeFill[] memory compFills,
            Order[] memory mintMakers, FeeFill memory mintTaker, FeeFill[] memory mintFills) = _complementaryThenMint();
        vm.prank(caller);
        vm.expectRevert(reason);
        exchange.matchOrdersWithFeesBatch(
            taker, _twoGroups(compMakers, mintMakers), _twoFills(compTaker, mintTaker), _twoFillGroups(compFills, mintFills)
        );
    }

    function test_batch_abiEncodeCall_locksFixture() public view {
        bytes memory encoded = _fixtureCalldata();
        bytes memory expected = vm.parseBytes(vm.readFile("testdata/matchOrdersWithFeesBatch.calldata.hex"));
        assertEq(encoded, expected);
    }

    function _assertBatchMatchesIsolated(
        Order memory taker,
        Order[] memory makers0,
        FeeFill memory taker0,
        FeeFill[] memory fills0,
        Order[] memory makers1,
        FeeFill memory taker1,
        FeeFill[] memory fills1
    ) internal {
        bytes32 takerHash = exchange.hashOrder(taker);
        bytes32 firstHash = exchange.hashOrder(makers0[0]);
        bytes32 secondHash = exchange.hashOrder(makers1[0]);
        uint256 snap = vm.snapshot();
        _batch(taker, makers0, taker0, fills0, makers1, taker1, fills1);
        uint256[8] memory balances = _captureBalances();
        OrderFillStateV11 memory takerState = exchange.getOrderFillStateV11(takerHash);
        OrderFillStateV11 memory firstState = exchange.getOrderFillStateV11(firstHash);
        OrderFillStateV11 memory secondState = exchange.getOrderFillStateV11(secondHash);
        vm.revertTo(snap);
        _runIsolated(taker, makers0, taker0, fills0, makers1, taker1, fills1);
        _assertBalances(balances);
        _assertState(exchange.getOrderFillStateV11(takerHash), takerState);
        _assertState(exchange.getOrderFillStateV11(firstHash), firstState);
        _assertState(exchange.getOrderFillStateV11(secondHash), secondState);
    }

    function _runIsolated(
        Order memory taker,
        Order[] memory makers0,
        FeeFill memory taker0,
        FeeFill[] memory fills0,
        Order[] memory makers1,
        FeeFill memory taker1,
        FeeFill[] memory fills1
    ) internal {
        vm.prank(admin);
        exchange.matchOrdersWithFees(taker, makers0, taker0, fills0);
        vm.prank(admin);
        exchange.matchOrdersWithFees(taker, makers1, taker1, fills1);
    }

    function _captureBalances() internal view returns (uint256[8] memory balances) {
        balances[0] = usdc.balanceOf(bob);
        balances[1] = usdc.balanceOf(carla);
        balances[2] = usdc.balanceOf(feeRecipient);
        balances[3] = usdc.balanceOf(address(exchange));
        balances[4] = getCTFBalance(bob, yes);
        balances[5] = getCTFBalance(bob, no);
        balances[6] = getCTFBalance(carla, yes);
        balances[7] = getCTFBalance(carla, no);
    }

    function _assertBalances(uint256[8] memory balances) internal view {
        assertEq(usdc.balanceOf(bob), balances[0]);
        assertEq(usdc.balanceOf(carla), balances[1]);
        assertEq(usdc.balanceOf(feeRecipient), balances[2]);
        assertEq(usdc.balanceOf(address(exchange)), balances[3]);
        assertEq(getCTFBalance(bob, yes), balances[4]);
        assertEq(getCTFBalance(bob, no), balances[5]);
        assertEq(getCTFBalance(carla, yes), balances[6]);
        assertEq(getCTFBalance(carla, no), balances[7]);
    }

    function _batch(
        Order memory taker,
        Order[] memory makers0,
        FeeFill memory taker0,
        FeeFill[] memory fills0,
        Order[] memory makers1,
        FeeFill memory taker1,
        FeeFill[] memory fills1
    ) internal {
        vm.prank(admin);
        exchange.matchOrdersWithFeesBatch(
            taker, _twoGroups(makers0, makers1), _twoFills(taker0, taker1), _twoFillGroups(fills0, fills1)
        );
    }

    function _complementaryThenMint()
        internal
        returns (
            Order memory taker,
            Order[] memory compMakers,
            FeeFill memory compTaker,
            FeeFill[] memory compFills,
            Order[] memory mintMakers,
            FeeFill memory mintTaker,
            FeeFill[] memory mintFills
        )
    {
        taker = _signed(bobPK, yes, TAKER_LIMIT_COLLATERAL, Q_COMP + Q_MINT, 0, Side.BUY, 1);
        compMakers = new Order[](1);
        compMakers[0] = _signed(carlaPK, yes, Q_COMP, COMP_LIMIT_COLLATERAL, 0, Side.SELL, 2);
        compTaker = FeeFill({ q: Q_COMP, pi: PI_COMP, f: 0 });
        compFills = new FeeFill[](1);
        compFills[0] = compTaker;
        mintMakers = new Order[](1);
        mintMakers[0] = _signed(carlaPK, no, MAKER_MINT_SLICE, Q_MINT, 0, Side.BUY, 3);
        mintTaker = FeeFill({ q: Q_MINT, pi: PI_MINT, f: 0 });
        mintFills = new FeeFill[](1);
        mintFills[0] = mintTaker;
    }

    function _twoMints()
        internal
        returns (
            Order memory taker,
            Order[] memory firstMakers,
            FeeFill memory firstTaker,
            FeeFill[] memory firstFills,
            Order[] memory secondMakers,
            FeeFill memory secondTaker,
            FeeFill[] memory secondFills
        )
    {
        taker = _signed(bobPK, yes, TWO_MINT_COLLATERAL, 2 * Q_MINT, 0, Side.BUY, 1);
        firstTaker = FeeFill({ q: Q_MINT, pi: PI_MINT, f: 0 });
        secondTaker = firstTaker;
        firstMakers = new Order[](1);
        firstMakers[0] = _signed(carlaPK, no, MAKER_MINT_SLICE, Q_MINT, 0, Side.BUY, 4);
        secondMakers = new Order[](1);
        secondMakers[0] = _signed(carlaPK, no, MAKER_MINT_SLICE, Q_MINT, 0, Side.BUY, 5);
        firstFills = new FeeFill[](1);
        firstFills[0] = firstTaker;
        secondFills = new FeeFill[](1);
        secondFills[0] = secondTaker;
    }

    function _sellThenMerge()
        internal
        returns (
            Order memory taker,
            Order[] memory compMakers,
            FeeFill memory compTaker,
            FeeFill[] memory compFills,
            Order[] memory mergeMakers,
            FeeFill memory mergeTaker,
            FeeFill[] memory mergeFills
        )
    {
        taker = _signed(bobPK, yes, SELL_SHARES, SELL_COLLATERAL, 0, Side.SELL, 1);
        compMakers = new Order[](1);
        compMakers[0] = _signed(carlaPK, yes, LEG_BUY_COLLATERAL, LEG_SHARES, 0, Side.BUY, 6);
        compTaker = FeeFill({ q: LEG_SHARES, pi: PI_COMP, f: 0 });
        compFills = new FeeFill[](1);
        compFills[0] = compTaker;
        mergeMakers = new Order[](1);
        mergeMakers[0] = _signed(carlaPK, no, LEG_SHARES, LEG_MERGE_COLLATERAL, 0, Side.SELL, 7);
        mergeTaker = FeeFill({ q: LEG_SHARES, pi: PI_COMP, f: 0 });
        mergeFills = new FeeFill[](1);
        mergeFills[0] = mergeTaker;
    }

    function _feeCapGroups(uint256 secondTakerFee) internal {
        (Order memory taker, Order[][] memory makers, FeeFill[] memory takerFills, FeeFill[][] memory makerFills) =
            _feeCapBatch(secondTakerFee);
        vm.prank(admin);
        exchange.matchOrdersWithFeesBatch(taker, makers, takerFills, makerFills);
    }

    function _feeCapBatch(uint256 secondTakerFee)
        internal
        returns (Order memory taker, Order[][] memory makers, FeeFill[] memory takerFills, FeeFill[][] memory makerFills)
    {
        taker = _signed(bobPK, yes, FEE_SLICE * 2, FEE_TAKER_SHARES, FEE_BPS, Side.BUY, 11);
        Order[] memory firstMakers = new Order[](1);
        firstMakers[0] = _signed(carlaPK, yes, FEE_Q, FEE_SLICE, FEE_BPS, Side.SELL, 12);
        Order[] memory secondMakers = new Order[](1);
        secondMakers[0] = _signed(carlaPK, yes, FEE_Q, FEE_SLICE, FEE_BPS, Side.SELL, 13);
        makers = _twoGroups(firstMakers, secondMakers);
        takerFills = _twoFills(
            FeeFill({ q: FEE_Q, pi: PI_HALF, f: 0 }), FeeFill({ q: FEE_Q, pi: PI_HALF, f: secondTakerFee })
        );
        FeeFill[] memory firstFills = new FeeFill[](1);
        firstFills[0] = FeeFill({ q: FEE_Q, pi: PI_HALF, f: 0 });
        FeeFill[] memory secondFills = new FeeFill[](1);
        secondFills[0] = FeeFill({ q: FEE_Q, pi: PI_HALF, f: 0 });
        makerFills = _twoFillGroups(firstFills, secondFills);
    }

    function _feeCapTakerHash() internal view returns (bytes32) {
        Order memory taker = _signedView(bob, yes, FEE_SLICE * 2, FEE_TAKER_SHARES, FEE_BPS, Side.BUY, 11);
        return exchange.hashOrder(taker);
    }

    function _feeCapMakerHash(uint256 salt) internal view returns (bytes32) {
        return exchange.hashOrder(_signedView(carla, yes, FEE_Q, FEE_SLICE, FEE_BPS, Side.SELL, salt));
    }

    function _assertFeeCapFilled() internal view {
        _assertState(
            exchange.getOrderFillStateV11(_feeCapTakerHash()),
            OrderFillStateV11({
                initialized: true,
                isFilledOrCancelled: true,
                BUsed: FEE_SLICE * 2,
                delivered: FEE_TAKER_SHARES,
                filledShares: 0,
                H: _twoGroupH()
            })
        );
        OrderFillStateV11 memory makerState = OrderFillStateV11({
            initialized: true,
            isFilledOrCancelled: true,
            BUsed: FEE_SLICE,
            delivered: 0,
            filledShares: FEE_Q,
            H: FEE_Q * PI_HALF * PI_HALF
        });
        _assertState(exchange.getOrderFillStateV11(_feeCapMakerHash(12)), makerState);
        _assertState(exchange.getOrderFillStateV11(_feeCapMakerHash(13)), makerState);
    }

    function _assertZeroState(bytes32 orderHash) internal view {
        _assertState(
            exchange.getOrderFillStateV11(orderHash),
            OrderFillStateV11({
                initialized: false,
                isFilledOrCancelled: false,
                BUsed: 0,
                delivered: 0,
                filledShares: 0,
                H: 0
            })
        );
    }

    function _twoGroupH() internal pure returns (uint256) {
        return 2 * (FEE_Q * PI_HALF * PI_HALF);
    }

    function _fixtureCalldata() internal pure returns (bytes memory) {
        Order memory taker = _rawOrder(1, address(0xA11CE), 11, 65);
        Order[][] memory makers = new Order[][](2);
        makers[0] = new Order[](2);
        makers[0][0] = _rawOrder(2, address(0xB0B), 22, 65);
        makers[0][1] = _rawOrder(3, address(0xCA414), 33, 66);
        makers[1] = new Order[](1);
        makers[1][0] = _rawOrder(4, address(0xD00D), 44, 130);
        FeeFill[] memory takerFills = new FeeFill[](2);
        takerFills[0] = FeeFill({ q: 100, pi: PI_COMP, f: 3 });
        takerFills[1] = FeeFill({ q: 200, pi: PI_MINT, f: 5 });
        FeeFill[][] memory makerFills = new FeeFill[][](2);
        makerFills[0] = new FeeFill[](2);
        makerFills[0][0] = FeeFill({ q: 40, pi: PI_COMP, f: 1 });
        makerFills[0][1] = FeeFill({ q: 60, pi: PI_COMP, f: 2 });
        makerFills[1] = new FeeFill[](1);
        makerFills[1][0] = FeeFill({ q: 200, pi: PI_MINT, f: 5 });
        return abi.encodeCall(CTFExchange.matchOrdersWithFeesBatch, (taker, makers, takerFills, makerFills));
    }

    function _rawOrder(uint256 salt, address maker, uint256 tokenId, uint256 sigLen)
        internal
        pure
        returns (Order memory order)
    {
        order.salt = salt;
        order.maker = maker;
        order.signer = maker;
        order.tokenId = tokenId;
        order.makerAmount = 1_000 + salt;
        order.takerAmount = 2_000 + salt;
        order.feeRateBps = salt;
        order.side = salt % 2 == 0 ? Side.SELL : Side.BUY;
        order.signature = new bytes(sigLen);
        for (uint256 i = 0; i < sigLen; i++) {
            order.signature[i] = bytes1(uint8(0x10 + (i % 200)));
        }
    }

    function _signed(
        uint256 pk,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 bps,
        Side side,
        uint256 salt
    ) internal returns (Order memory order) {
        order = _createAndSignOrderWithFee(pk, tokenId, makerAmount, takerAmount, bps, side);
        order.salt = salt;
        order.signature = _signMessage(pk, exchange.hashOrder(order));
    }

    function _signedView(
        address maker,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 bps,
        Side side,
        uint256 salt
    ) internal pure returns (Order memory order) {
        order = Order({
            salt: salt,
            signer: maker,
            maker: maker,
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: bps,
            signatureType: SignatureType.EOA,
            side: side,
            signature: new bytes(0)
        });
    }

    function _twoGroups(Order[] memory a, Order[] memory b) internal pure returns (Order[][] memory groups) {
        groups = new Order[][](2);
        groups[0] = a;
        groups[1] = b;
    }

    function _twoFills(FeeFill memory a, FeeFill memory b) internal pure returns (FeeFill[] memory fills) {
        fills = new FeeFill[](2);
        fills[0] = a;
        fills[1] = b;
    }

    function _twoFillGroups(FeeFill[] memory a, FeeFill[] memory b) internal pure returns (FeeFill[][] memory groups) {
        groups = new FeeFill[][](2);
        groups[0] = a;
        groups[1] = b;
    }

    function _assertState(OrderFillStateV11 memory actual, OrderFillStateV11 memory expected) internal pure {
        assertEq(actual.initialized, expected.initialized);
        assertEq(actual.isFilledOrCancelled, expected.isFilledOrCancelled);
        assertEq(actual.BUsed, expected.BUsed);
        assertEq(actual.delivered, expected.delivered);
        assertEq(actual.filledShares, expected.filledShares);
        assertEq(actual.H, expected.H);
    }

    function _fundCollateral(address who, uint256 amount) internal {
        deal(address(usdc), who, amount);
        vm.prank(who);
        IERC20(address(usdc)).approve(address(exchange), type(uint256).max);
        vm.prank(who);
        IERC1155(address(ctf)).setApprovalForAll(address(exchange), true);
    }
}

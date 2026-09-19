// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

import { IFees } from "../interfaces/IFees.sol";
import { IHashing } from "../interfaces/IHashing.sol";
import { ITrading } from "../interfaces/ITrading.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";
import { ISignatures } from "../interfaces/ISignatures.sol";
import { INonceManager } from "../interfaces/INonceManager.sol";
import { IAssetOperations } from "../interfaces/IAssetOperations.sol";

import { CalculatorHelper } from "../libraries/CalculatorHelper.sol";
import { GrossBudgetFeeMath } from "../libraries/GrossBudgetFeeMath.sol";
import { Order, Side, MatchType, OrderStatus, FeeFill, OrderFillStateV11 } from "../libraries/OrderStructs.sol";

/// @title Trading
/// @notice Implements logic for trading CTF assets
abstract contract Trading is IFees, ITrading, IHashing, IRegistry, ISignatures, INonceManager, IAssetOperations {
    /// @notice Mapping of orders to their current status
    mapping(bytes32 => OrderStatus) public orderStatus;

    /// @notice v1.1.0 fee-aware fill state (BUY BUsed is notional; transfer is N+f)
    mapping(bytes32 => OrderFillStateV11) public orderFillStateV11;

    /// @notice Gets the status of an order
    /// @param orderHash    - The hash of the order
    function getOrderStatus(bytes32 orderHash) public view returns (OrderStatus memory) {
        return orderStatus[orderHash];
    }

    /// @notice Gets v1.1.0 fill state for an order
    function getOrderFillStateV11(bytes32 orderHash) public view returns (OrderFillStateV11 memory) {
        return orderFillStateV11[orderHash];
    }

    /// @notice Validates an order
    /// @notice order - The order to be validated
    function validateOrder(Order memory order) public view {
        bytes32 orderHash = hashOrder(order);
        _validateOrder(orderHash, order);
    }

    /// @notice Cancels an order
    /// An order can only be cancelled by its maker, the address which holds funds for the order
    /// @notice order - The order to be cancelled
    function cancelOrder(Order memory order) external {
        _cancelOrder(order);
    }

    /// @notice Cancels a set of orders
    /// @notice orders - The set of orders to be cancelled
    function cancelOrders(Order[] memory orders) external {
        uint256 length = orders.length;
        uint256 i = 0;
        for (; i < length;) {
            _cancelOrder(orders[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _cancelOrder(Order memory order) internal {
        if (order.maker != msg.sender) revert NotOwner();

        bytes32 orderHash = hashOrder(order);
        OrderStatus storage status = orderStatus[orderHash];
        if (status.isFilledOrCancelled) revert OrderFilledOrCancelled();

        status.isFilledOrCancelled = true;
        orderFillStateV11[orderHash].isFilledOrCancelled = true;
        emit OrderCancelled(orderHash);
    }

    function _validateOrder(bytes32 orderHash, Order memory order) internal view {
        // Validate order expiration
        if (order.expiration > 0 && order.expiration < block.timestamp) revert OrderExpired();

        // Validate signature
        validateOrderSignature(orderHash, order);

        // Validate fee
        if (order.feeRateBps > getMaxFeeRate()) revert FeeTooHigh();

        // Validate the token to be traded
        validateTokenId(order.tokenId);

        // Validate that the order can be filled
        if (orderStatus[orderHash].isFilledOrCancelled || orderFillStateV11[orderHash].isFilledOrCancelled) {
            revert OrderFilledOrCancelled();
        }

        // Validate nonce
        if (!isValidNonce(order.maker, order.nonce)) revert InvalidNonce();
    }

    /// @notice Fills an order against the caller
    /// @param order        - The order to be filled
    /// @param fillAmount   - The amount to be filled, always in terms of the maker amount
    /// @param to           - The address to receive assets from filling the order
    function _fillOrder(Order memory order, uint256 fillAmount, address to) internal {
        uint256 making = fillAmount;
        (uint256 taking, bytes32 orderHash) = _performOrderChecks(order, making);

        uint256 fee = CalculatorHelper.calculateFee(
            order.feeRateBps, order.side == Side.BUY ? taking : making, order.makerAmount, order.takerAmount, order.side
        );

        (uint256 makerAssetId, uint256 takerAssetId) = _deriveAssetIds(order);

        // Transfer order proceeds minus fees from msg.sender to order maker
        _transfer(msg.sender, order.maker, takerAssetId, taking - fee);

        // Transfer makingAmount from order maker to `to`
        _transfer(order.maker, to, makerAssetId, making);

        // NOTE: Fees are "collected" by the Operator implicitly,
        // since the fee is deducted from the assets paid by the Operator

        emit OrderFilled(orderHash, order.maker, msg.sender, makerAssetId, takerAssetId, making, taking, fee);
    }

    /// @notice Fills a set of orders against the caller
    /// @param orders       - The order to be filled
    /// @param fillAmounts  - The amounts to be filled, always in terms of the maker amount
    /// @param to           - The address to receive assets from filling the order
    function _fillOrders(Order[] memory orders, uint256[] memory fillAmounts, address to) internal {
        uint256 length = orders.length;
        uint256 i = 0;
        for (; i < length;) {
            _fillOrder(orders[i], fillAmounts[i], to);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Matches orders against each other
    /// Matches a taker order against a list of maker orders
    /// @param takerOrder       - The active order to be matched
    /// @param makerOrders      - The array of passive orders to be matched against the active order
    /// @param takerFillAmount  - The amount to fill on the taker order, in terms of the maker amount
    /// @param makerFillAmounts - The array of amounts to fill on the maker orders, in terms of the maker amount
    function _matchOrders(
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) internal {
        uint256 making = takerFillAmount;

        (uint256 taking, bytes32 orderHash) = _performOrderChecks(takerOrder, making);
        (uint256 makerAssetId, uint256 takerAssetId) = _deriveAssetIds(takerOrder);

        // Transfer takerOrder making amount from taker order to the Exchange
        _transfer(takerOrder.maker, address(this), makerAssetId, making);

        // Fill the maker orders
        _fillMakerOrders(takerOrder, makerOrders, makerFillAmounts);

        taking = _updateTakingWithSurplus(taking, takerAssetId);
        uint256 fee = CalculatorHelper.calculateFee(
            takerOrder.feeRateBps, takerOrder.side == Side.BUY ? taking : making, making, taking, takerOrder.side
        );

        // Execute transfers

        // Transfer order proceeds post fees from the Exchange to the taker order maker
        _transfer(address(this), takerOrder.maker, takerAssetId, taking - fee);

        // Charge the fee to taker order maker, explicitly transferring the fee from the Exchange to the Operator
        _chargeFee(address(this), msg.sender, takerAssetId, fee);

        // Refund any leftover tokens pulled from the taker to the taker order
        uint256 refund = _getBalance(makerAssetId);
        if (refund > 0) _transfer(address(this), takerOrder.maker, makerAssetId, refund);

        emit OrderFilled(orderHash, takerOrder.maker, address(this), makerAssetId, takerAssetId, making, taking, fee);

        emit OrdersMatched(orderHash, takerOrder.maker, makerAssetId, takerAssetId, making, taking);
    }

    function _fillMakerOrders(Order memory takerOrder, Order[] memory makerOrders, uint256[] memory makerFillAmounts)
        internal
    {
        uint256 length = makerOrders.length;
        uint256 i = 0;
        for (; i < length;) {
            _fillMakerOrder(takerOrder, makerOrders[i], makerFillAmounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Fills a Maker order
    /// @param takerOrder   - The taker order
    /// @param makerOrder   - The maker order
    /// @param fillAmount   - The fill amount
    function _fillMakerOrder(Order memory takerOrder, Order memory makerOrder, uint256 fillAmount) internal {
        MatchType matchType = _deriveMatchType(takerOrder, makerOrder);

        // Ensure taker order and maker order match
        _validateTakerAndMaker(takerOrder, makerOrder, matchType);

        uint256 making = fillAmount;
        (uint256 taking, bytes32 orderHash) = _performOrderChecks(makerOrder, making);
        uint256 fee = CalculatorHelper.calculateFee(
            makerOrder.feeRateBps,
            makerOrder.side == Side.BUY ? taking : making,
            makerOrder.makerAmount,
            makerOrder.takerAmount,
            makerOrder.side
        );
        (uint256 makerAssetId, uint256 takerAssetId) = _deriveAssetIds(makerOrder);

        _fillFacingExchange(making, taking, makerOrder.maker, makerAssetId, takerAssetId, matchType, fee);

        emit OrderFilled(orderHash, makerOrder.maker, takerOrder.maker, makerAssetId, takerAssetId, making, taking, fee);
    }

    /// @notice Performs common order computations and validation
    /// 1) Validates the order taker
    /// 2) Computes the order hash
    /// 3) Validates the order
    /// 4) Computes taking amount
    /// 5) Updates the order status in storage
    /// @param order    - The order being prepared
    /// @param making   - The amount of the order being filled, in terms of maker amount
    function _performOrderChecks(Order memory order, uint256 making)
        internal
        returns (uint256 takingAmount, bytes32 orderHash)
    {
        _validateTaker(order.taker);

        orderHash = hashOrder(order);

        // Validate order
        _validateOrder(orderHash, order);

        // Calculate taking amount
        takingAmount = CalculatorHelper.calculateTakingAmount(making, order.makerAmount, order.takerAmount);

        // Update the order status in storage
        _updateOrderStatus(orderHash, order, making);
    }

    /// @notice Fills a maker order using the Exchange as the counterparty
    /// @param makingAmount - Amount to be filled in terms of maker amount
    /// @param takingAmount - Amount to be filled in terms of taker amount
    /// @param maker        - The order maker
    /// @param makerAssetId - The Token Id of the Asset to be sold
    /// @param takerAssetId - The Token Id of the Asset to be received
    /// @param matchType    - The match type
    /// @param fee          - The fee charged to the Order maker
    function _fillFacingExchange(
        uint256 makingAmount,
        uint256 takingAmount,
        address maker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        MatchType matchType,
        uint256 fee
    ) internal {
        // Transfer makingAmount tokens from order maker to Exchange
        _transfer(maker, address(this), makerAssetId, makingAmount);

        // Executes a match call based on match type
        _executeMatchCall(makingAmount, takingAmount, makerAssetId, takerAssetId, matchType);

        // Ensure match action generated enough tokens to fill the order
        if (_getBalance(takerAssetId) < takingAmount) revert TooLittleTokensReceived();

        // Transfer order proceeds minus fees from the Exchange to the order maker
        _transfer(address(this), maker, takerAssetId, takingAmount - fee);

        // Transfer fees from Exchange to the Operator
        _chargeFee(address(this), msg.sender, takerAssetId, fee);
    }

    function _deriveMatchType(Order memory takerOrder, Order memory makerOrder) internal pure returns (MatchType) {
        if (takerOrder.side == Side.BUY && makerOrder.side == Side.BUY) return MatchType.MINT;
        if (takerOrder.side == Side.SELL && makerOrder.side == Side.SELL) return MatchType.MERGE;
        return MatchType.COMPLEMENTARY;
    }

    function _deriveAssetIds(Order memory order) internal pure returns (uint256 makerAssetId, uint256 takerAssetId) {
        if (order.side == Side.BUY) return (0, order.tokenId);
        return (order.tokenId, 0);
    }

    /// @notice Executes a CTF call to match orders by minting new Outcome tokens
    /// or merging Outcome tokens into collateral.
    /// @param makingAmount - Amount to be filled in terms of maker amount
    /// @param takingAmount - Amount to be filled in terms of taker amount
    /// @param makerAssetId - The Token Id of the Asset to be sold
    /// @param takerAssetId - The Token Id of the Asset to be received
    /// @param matchType    - The match type
    function _executeMatchCall(
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 makerAssetId,
        uint256 takerAssetId,
        MatchType matchType
    ) internal {
        if (matchType == MatchType.COMPLEMENTARY) {
            // Indicates a buy vs sell order
            // no match action needed
            return;
        }
        if (matchType == MatchType.MINT) {
            // Indicates matching 2 buy orders
            // Mint new Outcome tokens using Exchange collateral balance and fill buys
            return _mint(getConditionId(takerAssetId), takingAmount);
        }
        if (matchType == MatchType.MERGE) {
            // Indicates matching 2 sell orders
            // Merge the Exchange Outcome token balance into collateral and fill sells
            return _merge(getConditionId(makerAssetId), makingAmount);
        }
    }

    /// @notice Ensures the taker and maker orders can be matched against each other
    /// @param takerOrder   - The taker order
    /// @param makerOrder   - The maker order
    function _validateTakerAndMaker(Order memory takerOrder, Order memory makerOrder, MatchType matchType)
        internal
        view
    {
        if (!CalculatorHelper.isCrossing(takerOrder, makerOrder)) revert NotCrossing();

        // Ensure orders match
        if (matchType == MatchType.COMPLEMENTARY) {
            if (takerOrder.tokenId != makerOrder.tokenId) revert MismatchedTokenIds();
        } else {
            // both bids or both asks
            validateComplement(takerOrder.tokenId, makerOrder.tokenId);
        }
    }

    function _validateTaker(address taker) internal view {
        if (taker != address(0) && taker != msg.sender) revert NotTaker();
    }

    function _chargeFee(address payer, address receiver, uint256 tokenId, uint256 fee) internal {
        // Charge fee to the payer if any
        if (fee > 0) {
            _transfer(payer, receiver, tokenId, fee);
            emit FeeCharged(receiver, tokenId, fee);
        }
    }

    function _updateOrderStatus(bytes32 orderHash, Order memory order, uint256 makingAmount)
        internal
        returns (uint256 remaining)
    {
        OrderStatus storage status = orderStatus[orderHash];
        // Fetch remaining amount from storage
        remaining = status.remaining;

        // Update remaining if the order is new/has not been filled
        remaining = remaining == 0 ? order.makerAmount : remaining;

        // Throw if the makingAmount(amount to be filled) is greater than the amount available
        if (makingAmount > remaining) revert MakingGtRemaining();

        // Update remaining using the makingAmount
        remaining = remaining - makingAmount;

        // If order is completely filled, update isFilledOrCancelled in storage
        if (remaining == 0) status.isFilledOrCancelled = true;

        // Update remaining in storage
        status.remaining = remaining;
    }

    function _updateTakingWithSurplus(uint256 minimumAmount, uint256 tokenId) internal returns (uint256) {
        uint256 actualAmount = _getBalance(tokenId);
        if (actualAmount < minimumAmount) revert TooLittleTokensReceived();
        return actualAmount;
    }

    /// @notice Matches orders with explicit (q, pi, f) actual-fee fills (v1.1.0)
    /// @dev BUY makerAmount is fee-exclusive notional; transfer is still N+f. SELL is P-f. Legacy matchOrders
    /// unchanged.
    function _matchOrdersWithFees(
        Order memory takerOrder,
        Order[] memory makerOrders,
        FeeFill memory takerFill,
        FeeFill[] memory makerFills
    ) internal {
        uint256 length = makerOrders.length;
        if (length == 0 || length != makerFills.length) revert LengthMismatch();

        _validateTaker(takerOrder.taker);
        bytes32 takerHash = hashOrder(takerOrder);
        _validateOrder(takerHash, takerOrder);

        uint256 takerNotional = _validateMakerOrdersWithFees(takerHash, takerOrder, takerFill, makerOrders, makerFills);

        address feeRecipient = getFeeRecipient();
        if (feeRecipient == address(0)) revert InvalidFeeRecipient();

        uint256 takerSettlement;
        if (takerOrder.side == Side.BUY) {
            (, takerSettlement) = _applyBuyFillV11(takerHash, takerOrder, takerFill, takerNotional);
            _transfer(takerOrder.maker, address(this), 0, takerSettlement);
        } else {
            (, takerSettlement) = _applySellFillV11(takerHash, takerOrder, takerFill, takerNotional);
            _transfer(takerOrder.maker, address(this), takerOrder.tokenId, takerFill.q);
        }

        uint256 makerFees = _fillMakerOrdersWithFees(takerOrder, takerFill, makerOrders, makerFills);

        if (takerOrder.side == Side.SELL) _transfer(address(this), takerOrder.maker, 0, takerSettlement);
        _chargeFee(address(this), feeRecipient, 0, takerFill.f + makerFees);
    }

    function _validateMakerOrdersWithFees(
        bytes32 takerHash,
        Order memory takerOrder,
        FeeFill memory takerFill,
        Order[] memory makerOrders,
        FeeFill[] memory makerFills
    ) internal view returns (uint256 takerNotional) {
        uint256 totalMakerQuantity;
        uint256 length = makerOrders.length;
        bytes32[] memory makerHashes = new bytes32[](length);
        for (uint256 i = 0; i < length;) {
            bytes32 makerHash = hashOrder(makerOrders[i]);
            if (makerHash == takerHash) revert RepeatedOrderHash();
            for (uint256 j = 0; j < i;) {
                if (makerHashes[j] == makerHash) revert RepeatedOrderHash();
                unchecked {
                    ++j;
                }
            }
            makerHashes[i] = makerHash;

            MatchType matchType = _deriveMatchType(takerOrder, makerOrders[i]);
            _validateTakerAndMaker(takerOrder, makerOrders[i], matchType);
            if (takerFill.pi != makerFills[i].pi) revert MismatchedFillPrice();

            takerNotional += _takerSliceNotional(matchType, makerFills[i], totalMakerQuantity);
            totalMakerQuantity += makerFills[i].q;
            _validateOrder(makerHash, makerOrders[i]);

            unchecked {
                ++i;
            }
        }
        if (takerFill.q != totalMakerQuantity) revert MismatchedFillQuantity();
    }

    function _fillMakerOrdersWithFees(
        Order memory takerOrder,
        FeeFill memory takerFill,
        Order[] memory makerOrders,
        FeeFill[] memory makerFills
    ) internal returns (uint256 makerFees) {
        uint256 quantityBefore;
        uint256 length = makerOrders.length;
        for (uint256 i = 0; i < length;) {
            uint256 takerSliceNotional =
                _takerSliceNotional(_deriveMatchType(takerOrder, makerOrders[i]), makerFills[i], quantityBefore);
            _fillMakerOrderWithFees(takerOrder, takerFill, makerOrders[i], makerFills[i], takerSliceNotional);

            makerFees += makerFills[i].f;
            quantityBefore += makerFills[i].q;
            unchecked {
                ++i;
            }
        }
    }

    function _takerSliceNotional(MatchType matchType, FeeFill memory fill, uint256 quantityBefore)
        internal
        pure
        returns (uint256)
    {
        // Each CLOB maker receives ceil proceeds; summing these slices also funds mixed batches exactly.
        if (matchType == MatchType.COMPLEMENTARY) {
            return GrossBudgetFeeMath.executionCollateralCeil(fill.q, fill.pi, 10 ** 18);
        }
        // Preserve the cumulative floor split for MINT/MERGE; the other leg receives the remainder.
        return GrossBudgetFeeMath.executionCollateral(quantityBefore + fill.q, fill.pi, 10 ** 18)
            - GrossBudgetFeeMath.executionCollateral(quantityBefore, fill.pi, 10 ** 18);
    }

    function _fillMakerOrderWithFees(
        Order memory takerOrder,
        FeeFill memory takerFill,
        Order memory makerOrder,
        FeeFill memory makerFill,
        uint256 takerSliceNotional
    ) internal {
        MatchType matchType = _deriveMatchType(takerOrder, makerOrder);
        bytes32 makerHash = hashOrder(makerOrder);
        FeeFill memory appliedMakerFill = makerFill;
        uint256 makerNotional = takerSliceNotional;

        if (matchType != MatchType.COMPLEMENTARY) {
            appliedMakerFill.pi = 10 ** 18 - takerFill.pi;
            makerNotional = makerFill.q - takerSliceNotional;
            require(takerSliceNotional + makerNotional == makerFill.q, "ComplementBreak");
        }

        uint256 makerSettlement;
        if (makerOrder.side == Side.BUY) {
            (, makerSettlement) = _applyBuyFillV11(makerHash, makerOrder, appliedMakerFill, makerNotional);
            _settleBuyMakerWithFees(takerOrder, makerOrder, makerFill.q, makerSettlement, matchType);
        } else {
            (, makerSettlement) = _applySellFillV11(makerHash, makerOrder, appliedMakerFill, makerNotional);
            _settleSellMakerWithFees(takerOrder, makerOrder, makerFill.q, makerSettlement, matchType);
        }

        _emitMakerMatchWithFees(takerOrder, takerFill, matchType, makerFill.q, takerSliceNotional, makerSettlement);
    }

    function _settleBuyMakerWithFees(
        Order memory takerOrder,
        Order memory makerOrder,
        uint256 quantity,
        uint256 makerSettlement,
        MatchType matchType
    ) internal {
        _transfer(makerOrder.maker, address(this), 0, makerSettlement);
        if (matchType == MatchType.COMPLEMENTARY) {
            _transfer(address(this), makerOrder.maker, takerOrder.tokenId, quantity);
            return;
        }
        if (matchType != MatchType.MINT) revert UnsupportedMatchType();

        _mint(getConditionId(takerOrder.tokenId), quantity);
        _transfer(address(this), takerOrder.maker, takerOrder.tokenId, quantity);
        _transfer(address(this), makerOrder.maker, makerOrder.tokenId, quantity);
    }

    function _settleSellMakerWithFees(
        Order memory takerOrder,
        Order memory makerOrder,
        uint256 quantity,
        uint256 makerSettlement,
        MatchType matchType
    ) internal {
        _transfer(makerOrder.maker, address(this), makerOrder.tokenId, quantity);
        if (matchType == MatchType.MERGE) {
            _merge(getConditionId(takerOrder.tokenId), quantity);
        } else if (matchType == MatchType.COMPLEMENTARY) {
            _transfer(address(this), takerOrder.maker, takerOrder.tokenId, quantity);
        } else {
            revert UnsupportedMatchType();
        }
        _transfer(address(this), makerOrder.maker, 0, makerSettlement);
    }

    function _emitMakerMatchWithFees(
        Order memory takerOrder,
        FeeFill memory takerFill,
        MatchType matchType,
        uint256 quantity,
        uint256 takerSliceNotional,
        uint256 makerSettlement
    ) internal {
        bytes32 takerHash = hashOrder(takerOrder);
        if (matchType == MatchType.COMPLEMENTARY) {
            emit OrdersMatched(takerHash, takerOrder.maker, 0, takerOrder.tokenId, 0, quantity);
        } else if (matchType == MatchType.MINT) {
            uint256 takerFee = takerFill.q == quantity ? takerFill.f : 0;
            emit OrdersMatched(
                takerHash,
                takerOrder.maker,
                0,
                takerOrder.tokenId,
                takerSliceNotional + makerSettlement + takerFee,
                quantity
            );
        } else if (matchType == MatchType.MERGE) {
            emit OrdersMatched(takerHash, takerOrder.maker, takerOrder.tokenId, 0, quantity, quantity);
        } else {
            revert UnsupportedMatchType();
        }
    }

    function _applyBuyFillV11(bytes32 orderHash, Order memory order, FeeFill memory fill, uint256 notional)
        internal
        returns (uint256 n, uint256 b)
    {
        if (order.side != Side.BUY) revert UnsupportedMatchType();
        OrderFillStateV11 storage st = orderFillStateV11[orderHash];
        if (st.isFilledOrCancelled) revert OrderFilledOrCancelled();
        if (fill.q > order.takerAmount - st.delivered) revert ShareOverfill();

        GrossBudgetFeeMath.FillResult memory res = GrossBudgetFeeMath.validateBuyFillWithNotional(
            GrossBudgetFeeMath.BuyFillInput({
                q: fill.q,
                pi: fill.pi,
                f: fill.f,
                feeRateBps: order.feeRateBps,
                S: 10 ** 18,
                M: order.makerAmount,
                T: order.takerAmount,
                BUsed: st.BUsed,
                delivered: st.delivered,
                HPrev: st.H
            }),
            notional
        );

        st.initialized = true;
        st.BUsed += res.notional;
        st.delivered += fill.q;
        st.H = res.HAfter;
        if (st.delivered == order.takerAmount) st.isFilledOrCancelled = true;

        // Keep legacy remaining as unused notional; zero it when the share budget is complete.
        OrderStatus storage legacy = orderStatus[orderHash];
        legacy.remaining = st.isFilledOrCancelled ? 0 : order.makerAmount - st.BUsed;
        if (st.isFilledOrCancelled) legacy.isFilledOrCancelled = true;

        emit OrderFilledWithFees(
            orderHash,
            order.maker,
            Side.BUY,
            fill.q,
            fill.pi,
            res.notional,
            fill.f,
            res.settlement,
            st.BUsed,
            st.delivered,
            st.H
        );
        return (res.notional, res.settlement);
    }

    function _applySellFillV11(bytes32 orderHash, Order memory order, FeeFill memory fill, uint256 notional)
        internal
        returns (uint256 P, uint256 R)
    {
        if (order.side != Side.SELL) revert UnsupportedMatchType();
        OrderFillStateV11 storage st = orderFillStateV11[orderHash];
        if (st.isFilledOrCancelled) revert OrderFilledOrCancelled();

        GrossBudgetFeeMath.FillResult memory res = GrossBudgetFeeMath.validateSellFillWithNotional(
            GrossBudgetFeeMath.SellFillInput({
                q: fill.q,
                pi: fill.pi,
                f: fill.f,
                feeRateBps: order.feeRateBps,
                S: 10 ** 18,
                M: order.makerAmount,
                T: order.takerAmount,
                filledShares: st.filledShares,
                PUsed: st.BUsed,
                HPrev: st.H
            }),
            notional
        );

        st.initialized = true;
        st.BUsed += res.notional; // cumulative gross proceeds
        st.filledShares += fill.q;
        st.H = res.HAfter;
        if (st.filledShares == order.makerAmount) st.isFilledOrCancelled = true;

        OrderStatus storage legacy = orderStatus[orderHash];
        legacy.remaining = order.makerAmount - st.filledShares;
        if (st.isFilledOrCancelled) legacy.isFilledOrCancelled = true;

        emit OrderFilledWithFees(
            orderHash,
            order.maker,
            Side.SELL,
            fill.q,
            fill.pi,
            res.notional,
            fill.f,
            res.settlement,
            st.BUsed,
            st.filledShares,
            st.H
        );
        return (res.notional, res.settlement);
    }
}

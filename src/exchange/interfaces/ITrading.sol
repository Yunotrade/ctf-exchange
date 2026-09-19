// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

import { OrderStatus, Order, FeeFill, OrderFillStateV11, Side } from "../libraries/OrderStructs.sol";

interface ITradingEE {
    error NotOwner();
    error NotTaker();
    error OrderFilledOrCancelled();
    error OrderExpired();
    error InvalidNonce();
    error MakingGtRemaining();
    error NotCrossing();
    error TooLittleTokensReceived();
    error MismatchedTokenIds();
    error LengthMismatch();
    error MismatchedFillQuantity();
    error MismatchedFillPrice();
    error UnsupportedMatchType();
    error RepeatedOrderHash();
    error LegacyTradingDisabled();
    error ShareOverfill();

    /// @notice Emitted when an order is cancelled
    event OrderCancelled(bytes32 indexed orderHash);

    /// @notice Emitted when an order is filled
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee
    );

    /// @notice Emitted when a set of orders is matched
    event OrdersMatched(
        bytes32 indexed takerOrderHash,
        address indexed takerOrderMaker,
        uint256 makerAssetId,
        uint256 takerAssetId,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled
    );

    /// @notice Emitted on a v1.1.0 fee fill (collateral fee only).
    /// @dev BUY `BUsed` is cumulative fee-exclusive notional. SELL `BUsed` is cumulative gross proceeds.
    event OrderFilledWithFees(
        bytes32 indexed orderHash,
        address indexed maker,
        Side side,
        uint256 q,
        uint256 pi,
        uint256 notional,
        uint256 fee,
        uint256 settlement,
        uint256 BUsed,
        uint256 deliveredOrFilled,
        uint256 H
    );

    event V11OnlyEnabled();
}

interface ITrading is ITradingEE {
    function getOrderFillStateV11(bytes32 orderHash) external view returns (OrderFillStateV11 memory);
}

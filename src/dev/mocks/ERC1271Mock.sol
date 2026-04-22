// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { ECDSA } from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";

/// @title ERC1271Mock
/// @notice Minimal smart-contract wallet used as the `POLY_1271` order maker in
///         tests and local e2e flows. Validates ECDSA signatures from a fixed
///         `signer` EOA and accepts ERC-1155 outcome-token transfers so it can
///         be used as the buyer side of a real `CTFExchange.matchOrders` settle
///         (settlement transfers YES/NO outcome tokens to the maker via
///         `safeTransferFrom`, which calls back into the recipient).
contract ERC1271Mock {
    address public signer;

    bytes4 internal constant MAGIC_VALUE_1271 = 0x1626ba7e;
    bytes4 internal constant ERC1155_RECEIVED = 0xf23a6e61;
    bytes4 internal constant ERC1155_BATCH_RECEIVED = 0xbc197c81;
    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant ERC1155_RECEIVER_INTERFACE_ID = 0x4e2312e0;

    constructor(address _signer) {
        signer = _signer;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) public view returns (bytes4) {
        return ECDSA.recover(hash, signature) == signer ? MAGIC_VALUE_1271 : bytes4(0);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return ERC1155_RECEIVED;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return ERC1155_BATCH_RECEIVED;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == ERC165_INTERFACE_ID || interfaceId == ERC1155_RECEIVER_INTERFACE_ID;
    }
}

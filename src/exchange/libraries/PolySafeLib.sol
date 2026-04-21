// SPDX-License-Identifier: MIT
pragma solidity <0.9.0;

interface ISafeProxyFactoryBytecode {
    function getContractBytecode() external view returns (bytes memory);
}

/// @title PolySafeLib
/// @notice Helper library to compute Polymarket gnosis safe addresses (CREATE2 via `SafeProxyFactory`).
library PolySafeLib {
    /// @notice Gets the Polymarket Gnosis safe address for a signer
    /// @param signer  - Address of the signer (salt input; must match factory `getSalt`)
    /// @param factory - `SafeProxyFactory` (deployer); bytecode comes from `getContractBytecode()`
    function getSafeAddress(address signer, address factory) internal view returns (address safe) {
        bytes memory bytecode = ISafeProxyFactoryBytecode(factory).getContractBytecode();
        bytes32 bytecodeHash = keccak256(bytecode);
        bytes32 salt = keccak256(abi.encode(signer));
        safe = _computeCreate2Address(factory, bytecodeHash, salt);
    }

    function _computeCreate2Address(address deployer, bytes32 bytecodeHash, bytes32 salt)
        internal
        pure
        returns (address)
    {
        bytes32 _data = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash));
        return address(uint160(uint256(_data)));
    }
}

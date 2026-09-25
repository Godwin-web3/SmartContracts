// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

/// @dev Shared fork pins. Override with ETH_RPC_URL / BASE_RPC_URL / ARB_RPC_URL.
abstract contract Forks is Test {
    uint256 internal constant ETH_BLOCK = 26_053_442;
    uint256 internal constant BASE_BLOCK = 51_768_627;
    uint256 internal constant ARB_BLOCK = 508_713_990;

    function _rpc(string memory key, string memory fallbackUrl) internal view returns (string memory) {
        try vm.envString(key) returns (string memory url) {
            if (bytes(url).length != 0) return url;
        } catch {}
        return fallbackUrl;
    }

    function _forkEth() internal {
        vm.createSelectFork(_rpc("ETH_RPC_URL", "https://ethereum.publicnode.com"), ETH_BLOCK);
    }

    function _forkBase() internal {
        vm.createSelectFork(_rpc("BASE_RPC_URL", "https://mainnet.base.org"), BASE_BLOCK);
    }

    function _forkArb() internal {
        vm.createSelectFork(_rpc("ARB_RPC_URL", "https://arb1.arbitrum.io/rpc"), ARB_BLOCK);
    }

    function _to18(uint256 amount, uint256 decimals_) internal pure returns (uint256) {
        if (decimals_ == 18) return amount;
        if (decimals_ < 18) return amount * (10 ** (18 - decimals_));
        return amount / (10 ** (decimals_ - 18));
    }

    function _ethSigned(bytes32 inner) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    function _sign(uint256 pk, bytes memory payload) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _ethSigned(keccak256(payload)));
        return abi.encodePacked(r, s, v);
    }
}

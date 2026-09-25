// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {Forks} from "./Forks.sol";

interface IL2MessageReceiver {
    function lzReceive(uint16 senderChainId, bytes calldata src, uint64 nonce, bytes calldata payload) external;
    function nonblockingLzReceive(uint16 senderChainId, bytes calldata src, bytes calldata payload) external;
    function retryMessage(uint16 senderChainId, bytes calldata src, uint64 nonce, bytes calldata payload) external;
    function rewardToken() external view returns (address);
    function config() external view returns (address gateway, address sender, uint16 senderChainId);
    function owner() external view returns (address);
}

interface IL2TokenReceiver {
    function withdrawToken(address recipient, address token, uint256 amount) external;
    function withdrawTokenId(address recipient, address token, uint256 tokenId) external;
    function swap(uint256 amountIn, uint256 amountOutMin, uint256 deadline, bool first) external returns (uint256);
    function collectFees(uint256 tokenId) external returns (uint256, uint256);
    function owner() external view returns (address);
}

interface IERC20Min {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Hypothesis C: forge/replay an L1->L2 mint, or pull wstETH from the L2 receiver.
contract CrossChainTest is Forks {
    address internal constant L2_RECEIVER = 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427;
    address internal constant L2_TOKEN_RECEIVER = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address internal constant L1_SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
    address internal constant LZ_ENDPOINT = 0x3c2269811836af69497E5F486A85D7316753cf62;
    address internal constant MOR = 0x092bAaDB7DEf4C3981454dD9c0A0D7FF07bCFc86;
    address internal constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;

    function setUp() public {
        _forkArb();
    }

    function test_unprivileged_cannot_mint_or_replay() public {
        address attacker = makeAddr("l2-attacker");
        uint256 supplyBefore = IERC20Min(MOR).totalSupply();

        (address gateway, address sender, uint16 chainId) = IL2MessageReceiver(L2_RECEIVER).config();
        assertEq(gateway, LZ_ENDPOINT, "gateway is not the LZ endpoint");
        assertEq(sender, L1_SENDER, "configured sender is not L1Sender");
        assertEq(chainId, 101, "unexpected source chain");
        console2.log("L2 MOR supply", supplyBefore);

        bytes memory src = abi.encodePacked(attacker, L2_RECEIVER);
        bytes memory payload = abi.encode(attacker, uint256(1_000_000 ether));

        vm.startPrank(attacker);
        vm.expectRevert();
        IL2MessageReceiver(L2_RECEIVER).lzReceive(101, src, 1, payload);

        vm.expectRevert();
        IL2MessageReceiver(L2_RECEIVER).nonblockingLzReceive(101, src, payload);

        vm.expectRevert();
        IL2MessageReceiver(L2_RECEIVER).retryMessage(101, src, 1, payload);

        // Endpoint entrypoint is not callable by an EOA; a forged source must not mint.
        (bool ok,) = LZ_ENDPOINT.call(
            abi.encodeWithSignature(
                "receivePayload(uint16,bytes,address,uint64,uint256,bytes)",
                uint16(101),
                abi.encodePacked(L1_SENDER, L2_RECEIVER),
                L2_RECEIVER,
                uint64(9_999_999),
                uint256(500_000),
                payload
            )
        );
        assertFalse(ok, "endpoint.receivePayload succeeded for attacker");
        vm.stopPrank();

        assertEq(IERC20Min(MOR).totalSupply(), supplyBefore, "MOR minted");
    }

    function test_unprivileged_cannot_drain_l2_token_receiver() public {
        address attacker = makeAddr("l2tr-attacker");
        uint256 wstBefore = IERC20Min(WSTETH).balanceOf(attacker);
        uint256 morBefore = IERC20Min(MOR).balanceOf(attacker);
        uint256 boxBefore = IERC20Min(WSTETH).balanceOf(L2_TOKEN_RECEIVER);

        vm.startPrank(attacker);
        vm.expectRevert();
        IL2TokenReceiver(L2_TOKEN_RECEIVER).withdrawToken(attacker, WSTETH, 1 ether);
        vm.expectRevert();
        IL2TokenReceiver(L2_TOKEN_RECEIVER).swap(1 ether, 0, block.timestamp + 1, false);
        vm.expectRevert();
        IUUPS(L2_TOKEN_RECEIVER).upgradeTo(attacker);
        // collectFees pays the receiver contract, never the caller. A bad tokenId reverts.
        try IL2TokenReceiver(L2_TOKEN_RECEIVER).collectFees(1) {} catch {}
        vm.stopPrank();

        assertEq(IERC20Min(WSTETH).balanceOf(attacker), wstBefore, "attacker received wstETH");
        assertEq(IERC20Min(MOR).balanceOf(attacker), morBefore, "attacker received MOR");
        assertEq(IERC20Min(WSTETH).balanceOf(L2_TOKEN_RECEIVER), boxBefore, "receiver wstETH moved");
        console2.log("L2TR wstETH", boxBefore);
    }
}

interface IUUPS {
    function upgradeTo(address) external;
}

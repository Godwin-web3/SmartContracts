// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "../src/Interfaces.sol";
import {Forks} from "./Forks.sol";

interface IDiamondSession {
    function providerRegister(address provider, uint256 amount, string calldata endpoint) external;
    function modelRegister(
        address modelOwner,
        bytes32 baseModelId,
        bytes32 ipfsCID,
        uint256 fee,
        uint256 amount,
        string calldata name,
        string[] calldata tags
    ) external;
    function getModelId(address account, bytes32 baseModelId) external pure returns (bytes32);
    function postModelBid(address provider, bytes32 modelId, uint256 pricePerSecond) external returns (bytes32);
    function openSession(
        address user,
        uint256 amount,
        bool isDirectPaymentFromUser,
        bytes calldata approvalEncoded,
        bytes calldata signature
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded, bytes calldata signature) external;
    function withdrawUserStakes(address user, uint8 iterations) external;
    function stakeToStipend(uint256 amount, uint128 timestamp) external view returns (uint256);
    function stipendToStake(uint256 stipend, uint128 timestamp) external view returns (uint256);
    function getSessionEnd(uint256 amount, uint256 pricePerSecond, uint128 openedAt) external view returns (uint128);
    function getMaxSessionDuration() external view returns (uint128);
    function getProviderMinimumStake() external view returns (uint256);
    function getModelMinimumStake() external view returns (uint256);
    function getMinMaxBidPricePerSecond() external view returns (uint256, uint256);
    function getBidFee() external view returns (uint256);
    function getFundingAccount() external view returns (address);
    function getTodaysBudget(uint128 timestamp) external view returns (uint256);
    function getComputeBalance(uint128 timestamp) external view returns (uint256);
    function totalMORSupply(uint128 timestamp) external view returns (uint256);
    function getProvidersTotalClaimed() external view returns (uint256);
    function startOfTheDay(uint128 timestamp) external pure returns (uint128);
    struct Session {
        address user;
        bytes32 bidId;
        uint256 stake;
        bytes closeoutReceipt;
        uint256 closeoutType;
        uint256 providerWithdrawnAmount;
        uint128 openedAt;
        uint128 endsAt;
        uint128 closedAt;
        bool isActive;
        bool isDirectPaymentFromUser;
    }

    function getSession(bytes32 sessionId) external view returns (Session memory);
    function setMaxSessionDuration(uint128) external;
    function withdrawFee(address recipient, uint256 amount) external;
}

/// @notice Hypothesis E value-extraction: self-dealt session pays more than the stipend
/// or spends MOR the diamond is holding for other users.
contract SessionRouterTest is Forks {
    address internal constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address internal constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 internal constant PK = 0xA11CE;

    function setUp() public {
        _forkBase();
    }

    function test_unprivileged_cannot_reconfigure_or_pull_fees() public {
        address attacker = makeAddr("session-attacker");
        vm.startPrank(attacker);
        vm.expectRevert();
        IDiamondSession(DIAMOND).setMaxSessionDuration(30 days);
        vm.expectRevert();
        IDiamondSession(DIAMOND).withdrawFee(attacker, 1);
        vm.stopPrank();
    }

    function test_cannot_open_session_with_victim_tokens() public {
        uint256 pk = PK;
        address attacker = vm.addr(pk);
        address victim = makeAddr("session-victim");
        uint256 victimStake = 1_000 ether;
        deal(MOR, victim, victimStake);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);

        // Victim approved nobody. Attacker is not the victim and not a delegate.
        vm.prank(attacker);
        vm.expectRevert();
        IDiamondSession(DIAMOND).openSession(victim, victimStake, false, hex"00", hex"00");
        assertEq(IERC20(MOR).balanceOf(victim), victimStake, "victim MOR moved");
    }

    function test_self_deal_cannot_take_more_than_stipend_or_other_users_mor() public {
        _runSelfDeal(false);
    }

    function test_direct_self_deal_conserves_diamond_mor() public {
        _runSelfDeal(true);
    }

    function test_budget_numbers_and_full_supply_stipend() public view {
        uint128 nowTs = uint128(block.timestamp);
        uint256 virtualSupply = IDiamondSession(DIAMOND).totalMORSupply(nowTs);
        uint256 tokenSupply = IERC20(MOR).totalSupply();
        uint256 budget = IDiamondSession(DIAMOND).getTodaysBudget(nowTs);
        uint256 computeBal = IDiamondSession(DIAMOND).getComputeBalance(nowTs);
        address funding = IDiamondSession(DIAMOND).getFundingAccount();
        uint256 fundingBal = IERC20(MOR).balanceOf(funding);
        uint256 claimed = IDiamondSession(DIAMOND).getProvidersTotalClaimed();
        uint256 stipendIfAllTokens = IDiamondSession(DIAMOND).stakeToStipend(tokenSupply, nowTs);

        console2.log("virtual MOR supply", virtualSupply);
        console2.log("token MOR supply", tokenSupply);
        console2.log("todays budget", budget);
        console2.log("compute balance", computeBal);
        console2.log("funding balance", fundingBal);
        console2.log("providers claimed", claimed);
        console2.log("stipend if staking full token supply", stipendIfAllTokens);

        // A single session's stipend is stake * budget / virtualSupply.
        // Existing tokens cannot buy a stipend above the funding account unless
        // tokenSupply * budget / virtualSupply > funding. That comparison is the
        // drain bound; the self-deal test checks an actual transfer.
        if (tokenSupply > virtualSupply) {
            assertLe(stipendIfAllTokens, fundingBal + budget, "full supply stipend exceeds funding+budget");
        }
    }

    function _runSelfDeal(bool direct) internal {
        uint256 pk = PK + (direct ? 1 : 0);
        address attacker = vm.addr(pk);
        IDiamondSession diamond = IDiamondSession(DIAMOND);

        uint128 nowTs = uint128(block.timestamp);
        uint256 providerMin = diamond.getProviderMinimumStake();
        uint256 modelMin = diamond.getModelMinimumStake();
        uint256 bidFee = diamond.getBidFee();
        (uint256 minPrice, uint256 maxPrice) = diamond.getMinMaxBidPricePerSecond();
        uint128 maxDur = diamond.getMaxSessionDuration();
        address funding = diamond.getFundingAccount();

        // Stake enough that the session lasts at least 5 minutes at the floor price.
        uint256 userStake = diamond.stipendToStake(minPrice * 301, nowTs);
        if (userStake < 1_000 ether) userStake = 1_000 ether;
        uint256 stipend = diamond.stakeToStipend(userStake, nowTs);
        uint256 price = stipend / uint256(maxDur);
        if (price < minPrice) price = minPrice;
        if (price > maxPrice) price = maxPrice;
        uint256 duration = stipend / price;
        if (duration > maxDur) duration = maxDur;
        require(duration >= 5 minutes, "session would be too short");

        uint256 providerStake = providerMin;
        uint256 expectedPay = duration * price;
        if (providerStake < expectedPay) providerStake = expectedPay;

        uint256 need = providerStake + modelMin + userStake + bidFee;
        deal(MOR, attacker, need);
        vm.startPrank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        diamond.providerRegister(attacker, providerStake, "https://hunt.invalid");
        diamond.modelRegister(attacker, bytes32("base"), bytes32("ipfs"), 0, modelMin, "m", new string[](0));
        bytes32 modelId = diamond.getModelId(attacker, bytes32("base"));
        bytes32 bidId = diamond.postModelBid(attacker, modelId, price);

        bytes memory approval = abi.encode(bidId, block.chainid, attacker, uint128(block.timestamp));
        bytes32 sessionId = diamond.openSession(attacker, userStake, direct, approval, _sign(pk, approval));
        vm.stopPrank();

        IDiamondSession.Session memory opened = diamond.getSession(sessionId);
        uint128 openedAt = opened.openedAt;
        uint128 endsAt = opened.endsAt;
        uint256 stipendAtOpen = diamond.stakeToStipend(userStake, openedAt);
        console2.log(direct ? "direct stipend" : "routed stipend", stipendAtOpen);
        console2.log("price per second", price);
        console2.log("endsAt-openedAt", endsAt - openedAt);

        uint256 diamondBefore = IERC20(MOR).balanceOf(DIAMOND);
        uint256 fundingBefore = IERC20(MOR).balanceOf(funding);
        uint256 attackerBeforeClose = IERC20(MOR).balanceOf(attacker);

        vm.warp(endsAt);
        bytes memory receipt = abi.encode(sessionId, block.chainid, uint128(block.timestamp), uint32(0), uint32(0));
        vm.prank(attacker);
        diamond.closeSession(receipt, _sign(pk, receipt));

        uint256 paid = diamond.getSession(sessionId).providerWithdrawnAmount;
        console2.log("provider paid", paid);

        uint128 releaseAt = diamond.startOfTheDay(endsAt) + 1 days;
        vm.warp(releaseAt);
        vm.prank(attacker);
        try diamond.withdrawUserStakes(attacker, 1) {} catch {}

        uint256 diamondAfter = IERC20(MOR).balanceOf(DIAMOND);
        uint256 fundingAfter = IERC20(MOR).balanceOf(funding);
        uint256 attackerAfter = IERC20(MOR).balanceOf(attacker);

        console2.log("diamond delta", diamondAfter > diamondBefore ? diamondAfter - diamondBefore : diamondBefore - diamondAfter);
        console2.log("funding decrease", fundingBefore - fundingAfter);
        console2.log("attacker delta", attackerAfter > attackerBeforeClose ? attackerAfter - attackerBeforeClose : attackerBeforeClose - attackerAfter);

        assertGt(paid, 0, "provider was not paid");
        assertLe(paid, stipendAtOpen + 1_000, "paid more than stipend");

        // Stakes and the bid fee were already inside the diamond before close.
        // The session stake must come back out (direct pay included: the attacker
        // is also the provider) and nothing else may leave.
        uint256 retained = providerStake + modelMin + bidFee;
        assertEq(diamondAfter + userStake, diamondBefore, "diamond MOR was not conserved");

        if (direct) {
            assertEq(fundingAfter, fundingBefore, "direct payment touched the funding account");
        } else {
            assertEq(fundingBefore - fundingAfter, paid, "funding decrease is not the provider payment");
        }

        // Attacker cannot finish richer than the stipend they were allocated.
        // Capital left inside the diamond (stakes + fee) is not profit.
        uint256 attackerEnd = IERC20(MOR).balanceOf(attacker);
        uint256 profit = attackerEnd + retained > need ? attackerEnd + retained - need : 0;
        console2.log("attacker profit vs capital in", profit);
        assertLe(profit, stipendAtOpen + 1_000, "profit exceeds stipend");
    }
}

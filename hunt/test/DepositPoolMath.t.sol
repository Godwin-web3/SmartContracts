// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20, IDistributor, IDepositPool, IChainlinkConsumer} from "../src/Interfaces.sol";
import {Forks} from "./Forks.sol";

/// @notice Hypothesis A: decimals confusion, donation inflation, self-referral amplification.
contract DepositPoolMathTest is Forks {
    address internal constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address internal constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        _forkEth();
    }

    function test_distribution_matches_usd_yield_scores() public {
        IDistributor dist = IDistributor(DISTRIBUTOR);
        address consumer = dist.chainLinkDataConsumer();

        address[] memory pools = _pools(dist);
        uint256 n = pools.length;
        uint256[] memory beforeRewards = new uint256[](n);
        uint256[] memory scores = new uint256[](n);
        uint256 totalScore;

        for (uint256 i; i < n; ++i) {
            beforeRewards[i] = dist.getDistributedRewards(0, pools[i]);
            scores[i] = _yieldScore(dist, consumer, pools[i]);
            totalScore += scores[i];
            console2.log("pool", pools[i]);
            console2.log("  score", scores[i]);
        }

        uint256 undistributedBefore = dist.undistributedRewards();
        dist.distributeRewards(0);

        uint256 distributed;
        for (uint256 i; i < n; ++i) {
            uint256 delta = dist.getDistributedRewards(0, pools[i]) - beforeRewards[i];
            distributed += delta;
            console2.log("delta", delta);
            if (totalScore == 0 || scores[i] == 0) {
                assertEq(delta, 0, "pool with zero yield received rewards");
            } else {
                uint256 expected = (scores[i] * _sumDeltas(dist, pools, beforeRewards)) / totalScore;
                // Recompute after we know the actual total. Placeholder replaced below.
                expected = 0;
                delta = delta;
            }
        }

        uint256 totalDelta = _sumDeltas(dist, pools, beforeRewards);
        console2.log("total distributed", totalDelta);
        console2.log("undistributed delta", dist.undistributedRewards() - undistributedBefore);

        if (totalScore == 0) {
            assertEq(totalDelta, 0, "rewards distributed with zero yield");
            return;
        }

        for (uint256 i; i < n; ++i) {
            uint256 delta = dist.getDistributedRewards(0, pools[i]) - beforeRewards[i];
            uint256 expected = (scores[i] * totalDelta) / totalScore;
            // 0.5% relative, and at least the per-pool floor dust (n wei).
            if (expected == 0) {
                assertEq(delta, 0, "unexpected reward");
            } else {
                assertApproxEqRel(delta, expected, 0.005e18, "yield score mismatch");
            }
            console2.log("expected", expected);
        }
    }

    function test_weth_round_trip_does_not_mint_principal() public {
        IDepositPool pool = IDepositPool(WETH_POOL);
        (uint128 withdrawLock,,, uint256 minimalStake,) = pool.rewardPoolsProtocolDetails(0);
        uint256 amount = minimalStake > 0.1 ether ? minimalStake : 0.1 ether;

        address attacker = makeAddr("weth-attacker");
        deal(WETH, attacker, amount);
        vm.startPrank(attacker);
        IERC20(WETH).approve(DISTRIBUTOR, type(uint256).max);
        pool.stake(0, amount, 0, address(0));
        vm.stopPrank();

        uint256 deposited = _userDeposited(pool, attacker);
        console2.log("weth deposited", deposited);

        uint256[] memory prices = _snapshotPrices();
        vm.warp(block.timestamp + withdrawLock + 1);
        _mockPrices(prices);

        uint256 beforeBal = IERC20(WETH).balanceOf(attacker);
        vm.prank(attacker);
        pool.withdraw(0, deposited);
        uint256 received = IERC20(WETH).balanceOf(attacker) - beforeBal;
        console2.log("weth received", received);

        assertLe(received, amount + 10, "withdrew more principal than deposited");
        assertGe(received + 10, amount, "lost more than dust on round trip");
    }

    function test_self_referral_is_only_one_percent_and_referrer_reward_is_zero() public {
        IDepositPool pool = IDepositPool(WETH_POOL);
        (,,, uint256 minimalStake,) = pool.rewardPoolsProtocolDetails(0);
        uint256 amount = minimalStake > 0.1 ether ? minimalStake : 0.1 ether;

        uint256 pkSelf = 0xB0B;
        address self = vm.addr(pkSelf);
        address plain = makeAddr("plain-staker");

        deal(WETH, self, amount);
        deal(WETH, plain, amount);

        vm.startPrank(plain);
        IERC20(WETH).approve(DISTRIBUTOR, type(uint256).max);
        pool.stake(0, amount, 0, address(0));
        vm.stopPrank();

        vm.startPrank(self);
        IERC20(WETH).approve(DISTRIBUTOR, type(uint256).max);
        pool.stake(0, amount, 0, self);
        vm.stopPrank();

        uint256[] memory prices = _snapshotPrices();
        // `<= last + minPeriod` returns early, so step one second past the window.
        vm.warp(block.timestamp + 1 days + 1);
        _mockPrices(prices);
        IDistributor(DISTRIBUTOR).distributeRewards(0);

        uint256 selfReward = pool.getLatestUserReward(0, self);
        uint256 plainReward = pool.getLatestUserReward(0, plain);
        uint256 referrerReward = pool.getLatestReferrerReward(0, self);
        console2.log("self reward", selfReward);
        console2.log("plain reward", plainReward);
        console2.log("referrer reward", referrerReward);

        assertGt(selfReward, 0, "self reward is zero");
        assertGt(plainReward, 0, "plain reward is zero");
        // Coded bonus is exactly 1.01x. 1% relative slack absorbs one-day rounding.
        assertApproxEqRel(selfReward, (plainReward * 101) / 100, 0.01e18, "self-referral is not 1.01x");
        assertEq(referrerReward, 0, "self-referral paid a referrer tier");
    }

    function test_solvency_shortfall_is_dust() public {
        IDistributor dist = IDistributor(DISTRIBUTOR);
        address consumer = dist.chainLinkDataConsumer();
        address[] memory pools = _pools(dist);
        for (uint256 i; i < pools.length; ++i) {
            (
                address token,
                string memory path,
                ,
                uint256 deposited,
                ,
                uint8 strategy,
                address aToken,
                bool exists
            ) = dist.depositPools(0, pools[i]);
            if (!exists) continue;
            address yieldToken = strategy == 2 ? aToken : token;
            uint256 bal = IERC20(yieldToken).balanceOf(DISTRIBUTOR);
            if (deposited > bal) {
                uint256 shortfall = deposited - bal;
                uint256 price = IChainlinkConsumer(consumer).getChainLinkDataFeedLatestAnswer(
                    IChainlinkConsumer(consumer).getPathId(path)
                );
                uint256 usd18 = (_to18(shortfall, IERC20(yieldToken).decimals()) * price) / 1e18;
                console2.log("shortfall usd18", usd18);
                assertLt(usd18, 1 ether, "pool is insolvent by more than $1");
            }
        }
    }

    function _pools(IDistributor dist) internal view returns (address[] memory pools) {
        address[] memory tmp = new address[](8);
        uint256 n;
        for (uint256 i; i < 8; ++i) {
            try dist.depositPoolAddresses(0, i) returns (address pool) {
                tmp[n++] = pool;
            } catch {
                break;
            }
        }
        pools = new address[](n);
        for (uint256 i; i < n; ++i) pools[i] = tmp[i];
    }

    function _yieldScore(IDistributor dist, address consumer, address pool) internal view returns (uint256) {
        (
            ,
            string memory path,
            ,
            ,
            uint256 lastUnderlying,
            uint8 strategy,
            address aToken,
            bool exists
        ) = dist.depositPools(0, pool);
        if (!exists || strategy == 1) return 0;
        address yieldToken = _yieldToken(dist, pool, strategy, aToken);
        uint256 bal = IERC20(yieldToken).balanceOf(DISTRIBUTOR);
        if (bal <= lastUnderlying) return 0;
        uint256 price = IChainlinkConsumer(consumer).getChainLinkDataFeedLatestAnswer(
            IChainlinkConsumer(consumer).getPathId(path)
        );
        return _to18(bal - lastUnderlying, IERC20(yieldToken).decimals()) * price;
    }

    function _yieldToken(IDistributor dist, address pool, uint8 strategy, address aToken) internal view returns (address) {
        if (strategy == 2) return aToken;
        (address token,,,,,,,) = dist.depositPools(0, pool);
        return token;
    }

    function _sumDeltas(IDistributor dist, address[] memory pools, uint256[] memory beforeRewards)
        internal
        view
        returns (uint256 total)
    {
        for (uint256 i; i < pools.length; ++i) {
            total += dist.getDistributedRewards(0, pools[i]) - beforeRewards[i];
        }
    }

    function _userDeposited(IDepositPool pool, address user) internal view returns (uint256 deposited) {
        (, deposited,,,,,,,) = pool.usersData(user, 0);
    }

    function _snapshotPrices() internal view returns (uint256[] memory prices) {
        IDistributor dist = IDistributor(DISTRIBUTOR);
        address consumer = dist.chainLinkDataConsumer();
        address[] memory pools = _pools(dist);
        prices = new uint256[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            (, string memory path,,,,,,) = dist.depositPools(0, pools[i]);
            prices[i] = IChainlinkConsumer(consumer).getChainLinkDataFeedLatestAnswer(
                IChainlinkConsumer(consumer).getPathId(path)
            );
            require(prices[i] > 0, "live price is zero");
        }
    }

    function _mockPrices(uint256[] memory prices) internal {
        IDistributor dist = IDistributor(DISTRIBUTOR);
        address consumer = dist.chainLinkDataConsumer();
        address[] memory pools = _pools(dist);
        for (uint256 i; i < pools.length; ++i) {
            (, string memory path,,,,,,) = dist.depositPools(0, pools[i]);
            bytes32 pathId = IChainlinkConsumer(consumer).getPathId(path);
            vm.mockCall(
                consumer,
                abi.encodeWithSelector(IChainlinkConsumer.getChainLinkDataFeedLatestAnswer.selector, pathId),
                abi.encode(prices[i])
            );
        }
    }
}

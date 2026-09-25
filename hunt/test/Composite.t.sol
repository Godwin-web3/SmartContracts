// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20, IDistributor, IChainlinkConsumer, IAavePool, IPoolAddressesProvider} from "../src/Interfaces.sol";
import {Forks} from "./Forks.sol";

/// @notice Hypothesis F: a 1-wei aToken donation, or a stale Chainlink answer,
/// moves MOR rewards away from the USD yield score.
contract CompositeTest is Forks {
    address internal constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant AUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;

    function setUp() public {
        _forkEth();
    }

    function test_one_wei_ausdc_donation_does_not_skew_rewards() public {
        IDistributor dist = IDistributor(DISTRIBUTOR);
        // Checkpoint so the donation is the new yield, on top of whatever real yield accrues.
        dist.distributeRewards(0);

        address attacker = makeAddr("donor");
        address aave = IPoolAddressesProvider(dist.aavePoolAddressesProvider()).getPool();
        deal(USDC, attacker, 1_000_000);
        vm.startPrank(attacker);
        IERC20(USDC).approve(aave, type(uint256).max);
        IAavePool(aave).supply(USDC, 1_000_000, attacker, 0);
        uint256 aBal = IERC20(AUSDC).balanceOf(attacker);
        require(aBal > 1, "no aUSDC");
        IERC20(AUSDC).transfer(DISTRIBUTOR, 1);
        vm.stopPrank();

        uint256[] memory prices = _snapshotPrices();
        vm.warp(block.timestamp + 1 days + 1);
        _mockPrices(prices);

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
        }
        require(totalScore > 0, "no yield to split");

        dist.distributeRewards(0);

        uint256 totalDelta;
        for (uint256 i; i < n; ++i) {
            totalDelta += dist.getDistributedRewards(0, pools[i]) - beforeRewards[i];
        }
        console2.log("donation epoch distributed", totalDelta);

        for (uint256 i; i < n; ++i) {
            uint256 delta = dist.getDistributedRewards(0, pools[i]) - beforeRewards[i];
            uint256 expected = (scores[i] * totalDelta) / totalScore;
            if (expected == 0) {
                assertLe(delta, n, "zero-score pool received a share");
            } else {
                assertApproxEqRel(delta, expected, 0.01e18, "donation skewed a pool");
            }
        }

        uint256 usdcDelta = dist.getDistributedRewards(0, USDC_POOL) - _before(beforeRewards, pools, USDC_POOL);
        uint256 usdcScore = _scoreOf(scores, pools, USDC_POOL);
        console2.log("usdc delta", usdcDelta);
        console2.log("usdc score", usdcScore);
        // Removing the donated wei cannot move the USDC share by more than 1%.
        uint256 donatedScore = _to18(1, IERC20(AUSDC).decimals()) * _price(consumer, USDC_POOL);
        if (usdcScore > donatedScore) {
            uint256 scoreWithout = usdcScore - donatedScore;
            uint256 expectedWithout = totalScore == scoreWithout
                ? totalDelta
                : (scoreWithout * totalDelta) / (totalScore - (usdcScore - scoreWithout));
            if (expectedWithout > 0 && usdcDelta > 0) {
                assertApproxEqRel(usdcDelta, expectedWithout, 0.01e18, "1 wei captured a material share");
            }
        }
    }

    function test_stale_oracle_reverts_distribute_until_heartbeat() public {
        vm.warp(block.timestamp + 4_000);
        vm.expectRevert(bytes("DR: price for pair is zero"));
        IDistributor(DISTRIBUTOR).distributeRewards(0);
    }

    function _before(uint256[] memory beforeRewards, address[] memory pools, address target) internal pure returns (uint256) {
        for (uint256 i; i < pools.length; ++i) if (pools[i] == target) return beforeRewards[i];
        return 0;
    }

    function _scoreOf(uint256[] memory scores, address[] memory pools, address target) internal pure returns (uint256) {
        for (uint256 i; i < pools.length; ++i) if (pools[i] == target) return scores[i];
        return 0;
    }

    function _price(address consumer, address pool) internal view returns (uint256) {
        (, string memory path,,,,,,) = IDistributor(DISTRIBUTOR).depositPools(0, pool);
        return IChainlinkConsumer(consumer).getChainLinkDataFeedLatestAnswer(IChainlinkConsumer(consumer).getPathId(path));
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
        (, string memory path,, , uint256 lastUnderlying, uint8 strategy, address aToken, bool exists) =
            dist.depositPools(0, pool);
        if (!exists || strategy == 1) return 0;
        address yieldToken = strategy == 2 ? aToken : _token(dist, pool);
        uint256 bal = IERC20(yieldToken).balanceOf(DISTRIBUTOR);
        if (bal <= lastUnderlying) return 0;
        uint256 price = IChainlinkConsumer(consumer).getChainLinkDataFeedLatestAnswer(
            IChainlinkConsumer(consumer).getPathId(path)
        );
        return _to18(bal - lastUnderlying, IERC20(yieldToken).decimals()) * price;
    }

    function _token(IDistributor dist, address pool) internal view returns (address token) {
        (token,,,,,,,) = dist.depositPools(0, pool);
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

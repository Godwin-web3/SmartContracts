// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {IRewardPool} from "../src/Interfaces.sol";
import {Forks} from "./Forks.sol";

/// @notice Hypothesis B: LinearDistributionIntervalDecrease over-counts when a
/// period is split across interval boundaries or across many epochs.
contract DistributorEmissionsTest is Forks {
    address internal constant ETH_REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address internal constant BASE_REWARD_POOL = 0xDC99a8596e395E52aba2BD08C623E1e428Dc3980;

    function test_eth_period_rewards_are_additive() public {
        _forkEth();
        _assertAdditive(ETH_REWARD_POOL, "eth");
    }

    function test_base_period_rewards_are_additive() public {
        _forkBase();
        _assertAdditive(BASE_REWARD_POOL, "base");
    }

    function _assertAdditive(address pool, string memory tag) internal {
        IRewardPool rp = IRewardPool(pool);
        for (uint256 i; i < 8; ++i) {
            try rp.rewardPools(i) returns (uint128 payoutStart, uint128 interval, uint256 initialReward, uint256 decrease, bool) {
                if (payoutStart == 0 || interval == 0 || initialReward == 0) {
                    console2.log(tag, i);
                    console2.log("  skip empty");
                    continue;
                }
                console2.log(tag, i);
                console2.log("  initial", initialReward);
                console2.log("  decrease", decrease);
                _checkSplits(rp, i, payoutStart, interval, initialReward, decrease);
            } catch {
                break;
            }
        }
    }

    function _checkSplits(
        IRewardPool rp,
        uint256 index,
        uint128 payoutStart,
        uint128 interval,
        uint256 initialReward,
        uint256 decrease
    ) internal view {
        uint128 horizon = payoutStart + 200 * interval;
        uint128 maxEnd = _maxEnd(payoutStart, interval, initialReward, decrease);
        if (horizon > maxEnd) horizon = maxEnd;

        uint256 whole = rp.getPeriodRewards(index, payoutStart, horizon);
        uint256 stepped;
        uint128 cursor = payoutStart;
        uint256 steps;
        while (cursor < horizon) {
            uint128 next = cursor + interval;
            if (next > horizon) next = horizon;
            stepped += rp.getPeriodRewards(index, cursor, next);
            cursor = next;
            steps++;
        }
        console2.log("  200d whole", whole);
        console2.log("  200d stepped", stepped);
        console2.log("  steps", steps);
        assertApproxEqAbs(stepped, whole, steps, "daily steps over-count");

        for (uint256 k; k < 24; ++k) {
            uint256 seed = uint256(keccak256(abi.encode(index, k, payoutStart)));
            uint128 span = uint128(30 * interval + (seed % (60 * interval)));
            uint128 start = payoutStart + uint128(seed % (150 * interval));
            if (start >= maxEnd) continue;
            uint128 end = start + span;
            if (end > maxEnd) end = maxEnd;
            if (end <= start + 2) continue;
            uint128 mid = start + uint128((uint256(end - start) * (1 + (seed % 9))) / 10);
            if (mid == start || mid == end) continue;

            uint256 one = rp.getPeriodRewards(index, start, end);
            uint256 two = rp.getPeriodRewards(index, start, mid) + rp.getPeriodRewards(index, mid, end);
            if (two != one) {
                console2.log("  mismatch start", start);
                console2.log("  mismatch mid", mid);
                console2.log("  mismatch end", end);
                console2.log("  one", one);
                console2.log("  two", two);
            }
            assertApproxEqAbs(two, one, 2, "split over-counts");
        }

        // Boundary: one second before an interval tick, and exactly on it.
        uint128 tick = payoutStart + 40 * interval;
        if (tick > payoutStart + 1 && tick < maxEnd) {
            uint256 across = rp.getPeriodRewards(index, tick - 1, tick + interval - 1);
            uint256 parts = rp.getPeriodRewards(index, tick - 1, tick) + rp.getPeriodRewards(index, tick, tick + interval - 1);
            assertApproxEqAbs(parts, across, 2, "boundary split over-counts");
        }
    }

    function _maxEnd(uint128 payoutStart, uint128 interval, uint256 initialReward, uint256 decrease)
        internal
        pure
        returns (uint128)
    {
        if (decrease == 0) return payoutStart + 400 * interval;
        uint256 maxIntervals = (initialReward + decrease - 1) / decrease;
        return uint128(uint256(payoutStart) + maxIntervals * uint256(interval));
    }
}

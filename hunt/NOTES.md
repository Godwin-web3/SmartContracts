# Hunt notes

Pins: ETH `26053442`, Base `51768627`, Arbitrum `508713990`.
RPCs: `https://ethereum.publicnode.com`, `https://mainnet.base.org`, `https://arb1.arbitrum.io/rpc`.

Second-epoch tests mock `ChainLinkDataConsumer.getChainLinkDataFeedLatestAnswer` with the price read before `vm.warp`. That keeps the feed fresh. It does not invent a price. `distributeRewards` returns early while `block.timestamp <= lastCalculated + minRewardsDistributePeriod` (86,400s), so warps used for a second epoch are `1 days + 1`.

## E1 Diamond admin surface — KILLED

Path: `LumerinDiamond` facets on Base. Initializers are `initializer(slot)` and the admin functions are `onlyOwner`.
PoC: `test/Diamond.t.sol`.
Result: 73 unique selectors. Unprivileged init, cut, ownership transfer, and upgrade revert. Owner and funding account unchanged.

## E2 SessionRouter value extraction — KILLED

Path: `openSession` pulls MOR from `user_`. `closeSession` pays `duration * pricePerSecond`, capped by how `getSessionEnd` clamps duration to `min(stipend / price, maxSessionDuration)`. Non-direct pay pulls the funding account. Direct pay pulls the user’s own stake. Provider claim is also capped by `provider.stake`.
PoC: `test/SessionRouter.t.sol`.
Result: 1,000 MOR stake, 7-day session, paid `2.923151195335392000` MOR against a stipend of `2.923151195335686224`. Diamond balance changed only by the returning session stake. Direct-payment profit was 0. Full token supply (`6.383e6` MOR) buys an `18,661` MOR stipend, under `getTodaysBudget` (`28,684`) and under the funding balance (`95,107`).

## D BuildersV4 — KILLED

Path: `BuildersV4._updatePoolData` computes pending rewards on the pre-update deposit, so a new subnet with `deposited == 0` stores 0 pending and then snaps its rate to the current rate. `claim` pays the treasury via `sendRewards` and does not touch `totalDeposited`.
PoC: `test/BuildersV4.t.sol`.
Result: historical reward 0. 1,000 vs 3,000 MOR over 14 days paid `12.030` and `36.090` MOR. Claim paid exactly that. Withdraw returned the deposit. Builders MOR balance stayed equal to `totalDeposited` (`2,663,861.71` MOR). Stranger claim and treasury withdraw revert.

## C Cross-chain mint — KILLED

Path: `L2MessageReceiver.lzReceive` requires `msg.sender == config.gateway`. `_nonblockingLzReceive` requires chain id and `sender == config.sender` (first 20 bytes of the path) before `MOR.mint`. `L2TokenReceiverV2` withdraw/swap/upgrade are `onlyOwner`.
PoC: `test/CrossChain.t.sol`.
Result: EOA calls revert. Supply stays `3,187,964.152` MOR. Receiver wstETH stays 0.
Not finished: pranking the endpoint to confirm a spoofed path is only stored in `failedMessages`. The public Arb RPC is missing that account’s trie node. Not an unprivileged path anyway.

## A Deposit math — KILLED

Path: `DistributorV2.distributeRewards` scores `to18(balance - lastUnderlying) * tokenPrice`. `DepositPool` stakes 1:1 token amounts, not ERC4626 shares. Referral multiplier is `1.01 * 1e25` when `referrer != 0`. Empty tiers make the referrer’s virtual stake 0.
PoC: `test/DepositPoolMath.t.sol`, `test/Composite.t.sol`.
Result: live split of `3,263.693` MOR matched scores within 2 wei. 0.1 WETH round-tripped exactly. Self-referral paid 1.0100x and 0 referrer rewards. 1 wei of aUSDC did not move a pool off its score (1% tolerance) on a `2,887.250` MOR epoch.

## B Emission additivity — KILLED

Path: `RewardPool.getPeriodRewards` → `LinearDistributionIntervalDecrease.getPeriodReward` on the deployed pools, including partial intervals and the `intervalPart == interval` branch that returns 0.
PoC: `test/DistributorEmissions.t.sol`.
Result: 200 daily steps matched the single span exactly on ETH and Base pools 0–4. Random splits were off by at most 1 wei.

## F Oracle composite — KILLED as a bounty bug, still the live lead

Path: `ChainLinkDataConsumer` returns 0 when `block.timestamp - updatedAt > allowedPriceUpdateDelay`. `updateDepositTokensPrices` then reverts `DR: price for pair is zero`, and `DepositPool` withdraw/stake/claim call `distributeRewards` first.
PoC: `test_stale_oracle_reverts_distribute_until_heartbeat`.
Result: `+4,000s` reverts. Not attacker-triggered. Unfreezes on the next heartbeat. Do not submit unless a later PoC shows an unprivileged user can force the zero price or keep it zero.

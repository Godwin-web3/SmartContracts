# Killed hypotheses

Fork pins: Ethereum block `26053442`, Base block `51768627`, Arbitrum block `508713990`. Run `forge test --root hunt`.

## E. LumerinDiamond initializer / selector / storage takeover

`DiamondTest` on Base `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`.

- 5 facets, 73 selectors, no duplicate, no `delegatecall`/`execute`/`execTransaction` selector installed.
- The eight named diamond storage slots hash to distinct values.
- An EOA calling `__LumerinDiamond_init`, `__Marketplace_init`, `__ProviderRegistry_init`, `__ModelRegistry_init`, `__Delegation_init`, `__SessionRouter_init`, `transferOwnership`, `diamondCut`, or `upgradeTo` reverts. Owner, funding account, and `providersTotalClaimed` are unchanged.
- `setMaxSessionDuration` and `withdrawFee` revert for an EOA.
- `openSession` for a victim who did not delegate reverts and the victim’s MOR stays put.

## E. Session self-deal drains the diamond or the funding account

`SessionRouterTest`. Attacker is provider, model owner, and user. Stake 1,000 MOR. Session length 604,800s (the max). Price `4,833,252,637,790` wei per second.

- Stipend `2.923151195335686224` MOR. Provider paid `2.923151195335392000` MOR (below the stipend by 294,224 wei).
- Non-direct: funding account decreased by exactly the payment. Attacker profit versus capital posted was that same payment.
- Direct: funding account unchanged. Attacker profit was 0 (the payment came out of the attacker’s own session stake).
- In both modes `diamondAfter + sessionStake == diamondBefore` exactly. Other users’ MOR on the diamond did not move.

Budget ceiling, same block, view only:

- Virtual MOR supply `9,812,975.218` MOR. Token supply `6,383,893.241` MOR (less than virtual supply).
- `getTodaysBudget` `28,684.810` MOR. Funding account `95,107.712` MOR. `providersTotalClaimed` `175,068.474` MOR.
- Stipend if every existing MOR token were staked in one session: `18,661.085` MOR. That is under the budget and under the funding balance, so the funding account cannot be emptied with tokens that exist.

## D. BuildersV4 historical rewards, claim inflation, treasury pull

`BuildersV4Test` on Base `0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9`, version 4.

- `MOR.balanceOf(builders) == allSubnetsData.totalDeposited` at the pin: `2,663,861.709788513813282554` MOR.
- `setNetworkShare`, treasury `withdraw`, treasury `sendRewards`, and `upgradeTo` on the builders proxy and the treasury revert for an EOA.
- After a 30-day warp, a brand-new subnet’s `getCurrentSubnetRewards` is 0 at the deposit block (no historical skim).
- 14 days later, 1,000 MOR earned `12.030089601774474439` MOR and 3,000 MOR earned `36.090268805323423317` MOR (3.000x within 0.1%).
- A stranger `claim` reverts and does not change the owed amount. The admin claim paid exactly the owed amount; fee was 0. `totalDeposited` and the builders MOR balance did not change on claim.
- Withdraw after the lock returned the full 1,000 MOR. Balance still equaled `totalDeposited`.

## C. L1 to Arbitrum mint or L2 receiver drain

`CrossChainTest` on Arbitrum. L2 MOR supply at the pin: `3,187,964.152341041748623945` MOR. L2 token receiver wstETH balance: 0.

- Config is gateway = LZ endpoint `0x3c2269811836af69497E5F486A85D7316753cf62`, sender = L1Sender `0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84`, chain id 101.
- An EOA `lzReceive`, `nonblockingLzReceive`, and `retryMessage` all revert. `endpoint.receivePayload` from that EOA returns false. Supply is unchanged.
- `withdrawToken`, `swap`, and `upgradeTo` on L2TokenReceiverV2 revert. `collectFees` does not move wstETH or MOR to the caller.

An endpoint-pranked spoof was not left in the suite. The public Arbitrum RPC does not serve historical state for the endpoint account (`missing trie node` on `0xE5fFa41BE6D13f623B2E9D2950d9a9b62cD488C8`), so that prank is not reproducible here. It would also be privileged. The source path still requires `sender == config.sender` inside `_nonblockingLzReceive` before `mint`.

## A. DepositPool decimals, donation, self-referral, principal mint

`DepositPoolMathTest` and `CompositeTest` on Ethereum. One real `distributeRewards(0)` at the pin (no oracle mock) paid `3,263.693079173689980553` MOR.

Per-pool actual versus USD yield score (`to18(aToken surplus) * 18-decimal price`):

| Pool | Score share paid (wei) | Expected (wei) |
| --- | --- | --- |
| stETH | 3021314689214808857049 | 3021314689214808857047 |
| wBTC | 1783518035313335 | 1783518035313335 |
| wETH | 2748757570760983738 | 2748757570760983738 |
| USDC | 224398333916525874500 | 224398333916525874500 |
| USDT | 15229514953558951931 | 15229514953558951931 |

Largest gap is 2 wei on stETH. A 6-versus-18 decimals bug would have moved USDC/USDT by ~1e12. It did not. Undistributed rewards delta was 0. No pool was short by $1 of underlying.

WETH round trip of `0.1` WETH returned `0.1` WETH exactly (withdraw lock plus a price mock that replays the pre-warp Chainlink answers, not a fake authorization).

Self-referral versus an equal plain stake, one day later: self `0.042011755817037829` MOR, plain `0.041595797838651316` MOR, ratio 1.0100. Referrer-tier reward was 0.

A 1-wei aUSDC donation plus one day of real yield distributed `2,887.250043705375513886` MOR. The USDC pool’s share matched its post-donation yield score within 1%. The donated wei did not capture a disproportionate epoch.

## B. LinearDistributionIntervalDecrease double count

`DistributorEmissionsTest` against the deployed reward pools (Ethereum `0xb7994dE339AEe515C9b2792831CD83f3C9D8df87`, Base `0xDC99a8596e395E52aba2BD08C623E1e428Dc3980`), pools 0–4.

- 200 consecutive daily slices summed exactly to one `getPeriodRewards` call over the same window (for example Base pool 0: `679,408.081308024` MOR both ways).
- 24 keccak-seeded mid-point splits per pool differed by exactly 1 wei where they differed. Tolerance in the test is 2 wei.
- An on-boundary split (one second before a tick, then the rest of the interval) stayed within 2 wei.

One wei per split across the remaining curve is dust, not an over-mint.

## F. Composite: oracle freeze

`CompositeTest.test_stale_oracle_reverts_distribute_until_heartbeat`: warp `+4,000s` with no mock. `distributeRewards(0)` reverts `DR: price for pair is zero`. ETH/USD at the pin was already ~2,448s into a 3,600s delay, so this is the live heartbeat, not a crafted answer. Nobody can force the stale answer, and a later heartbeat unfreezes it. Not a permanent freeze and not an attacker profit.

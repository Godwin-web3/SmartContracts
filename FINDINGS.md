# Findings

Nothing submittable.

Every hypothesis below was run as a Foundry mainnet-fork test under `hunt/`. Pins: Ethereum `26053442`, Base `51768627`, Arbitrum `508713990`. Passing tests assert either “no profit / no loss” or a revert. No test shows an unprivileged attacker gaining value or a user/protocol losing funds.

| Tier | Issue | PoC | At risk |
| --- | --- | --- | --- |
| — | none confirmed | — | $0 |

Strongest lead still worth pushing, and why it is not a finding yet: a Chainlink heartbeat gap freezes `DistributorV2.distributeRewards` (`DR: price for pair is zero` after a 4,000s warp in `CompositeTest.test_stale_oracle_reverts_distribute_until_heartbeat`). `DepositPool` stake, withdraw, and claim all call `distributeRewards` first, so those entrypoints freeze with the oracle. It is not attacker-triggered and it clears on the next fresh round. The bounty bar is an unprivileged drain, freeze of funds the attacker can force, or unauthorized mint. This is a liveness dependency, not that.

The same suite rules out the nearby money bugs (decimals-weighted reward split, 1-wei aUSDC donation, self-referral amplification, session self-deal against the diamond’s MOR, L2 mint without an L1 lock). Details and numbers are in `KILLED.md`.

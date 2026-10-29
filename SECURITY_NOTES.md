# Security remediation notes

Baseline: `main` at `06132936cfd4087dc54fbfc445bb993343ef8970`.
Remediation branch: `codex/essentials-security-fixes`.

The unchanged baseline compiled with Foundry v1.3.5 and Solidity 0.8.26
(Cancun, via IR, optimizer 200). All 71 existing tests passed. The audit's
additional defensive tests exposed four accounting or settlement defects;
the private Codex Security report retains their evidence and limitations.

## Remediation behavior

- Settlement uses only its own recorded inputs and actual pool deltas.
  Other pools' queued funds, deferred claims, and unsolicited transfers do
  not fund its LP donations or participant bonuses.
- Unspent residual input is returned proportionally to the originating
  side. If the residual leaves no active liquidity, remaining batch
  allocations are returned to that currency's input owners, or its output
  owners when there was no corresponding input side. No LP donation is
  attempted without active liquidity. This fallback can return surcharge
  amounts to participants; it does not promise a complete fill.
- Compatible recipients still receive payments in explicit `settleBatch`.
  Deliveries run after the PoolManager unlock has closed. Automatic expired
  settlement inside a router's unlock records claims for all currencies;
  those payees call `claim` independently. Payment-delivery callbacks run
  after the batch accounting window closes. Each automatic delivery
  attempt has a 50,000-gas allowance. A failed or more expensive delivery
  becomes a claim for the original queued recipient, without blocking the
  batch. Outputs, refunds, and bonuses use the same delivery path.
- `claimable(currency, payee)` reports a deferred payment. The payee calls
  `claim(currency, recipient)` to retry, including to a different nonzero
  destination. Only the caller's own claim is debited. A failed retry
  preserves that claim. `totalClaimable(currency)` exposes aggregate
  deferred liabilities. Claims have no administrator or expiry.
- Native currency is receivable from the immutable PoolManager. Ordinary
  direct native sends are rejected. Native recipient code never runs while
  batch settlement has the PoolManager unlocked. Native settlement resets the
  manager's synced currency. PoolManager callbacks cannot queue new orders
  during settlement, post-unlock delivery, or a claim.
- Each batch's aggregate input on either side is capped at positive
  `int128.max`, matching the signed accounting domain used by v4. Rejected
  orders do not take custody of input.
- `MAX_BATCH_SIZE` is reduced from 75 to 64. The additional payment-safety
  accounting caused the old 75-order case to exceed the existing
  8,000,000-gas test budget. The test budget is unchanged; routers should
  read the exposed cap instead of assuming the previous capacity.
- `BatchSettled` reports actual residual input and actual LP donation
  amounts. Its event signature is unchanged. Cumulative bonus allocation
  assigns rounding remainders within the current batch.

## Integration obligations and remaining risks

Routers must supply the intended payee in `hookData`; the manager-visible
sender can be a router rather than an end user. A router that is itself
the payee needs a way to exercise its own deferred claims.

`minAmountOut` remains decoded and stored but unenforced, as documented by
the original project. There is no per-order deadline or cancellation.
Settlement timing, public queue visibility, spot-dependent execution,
and address-based toxic-flow Sybil limitations remain. The source flags
exactly 50% of same-side volume as toxic, despite older greater-than-50%
wording. These changes do not establish a general MEV or fair-price proof.

Fee-on-transfer, rebasing, dishonest token balances, and tokens that cannot
pay the PoolManager are not made safe by delivery isolation. Recipient
claims provide delivery recovery, not a guarantee of solvency for arbitrary
token behavior. The funding helper currently uses a boolean-returning ERC20
interface; non-returning tokens need separate compatibility work. Extreme
prices and adversarial token implementations need
additional specialist testing. Unsolicited transfers have no rescue path
and should not be sent to the hook.

The hook has no upgrade mechanism. Updating this repository does not repair
an existing deployment. A replacement hook requires a newly mined address
with the same required permission bits; an existing v4 pool cannot have
its hook replaced. Deployment, verification, migration and recovery of old
queued funds are separate work. No merge, deployment, or live transaction
is part of this remediation.

## Verification

`test/AuditSecurityRegression.t.sol` covers batch escrow isolation, deferred
claim collateral, partial/no fills, native inputs/outputs, recipient
failure, claim authorization/redirection/retry, rollback on false token
returns, helper access control and aggregate admission limits.
`test/NativeSettlementIsolation.t.sol` covers native callback isolation in
explicit and expired settlement and native sync reset. Existing
unit, integration, fuzz, invariant and gas-limit tests remain the baseline
compatibility checks. Final pass/fail results and reviewer disposition are
recorded below.

## Verified results

Source and regression-test commit:
`597ceae790931ff3df2ca997b5d6fbbd9c01df63`.

| Check | Result |
| --- | --- |
| Unchanged baseline | 71 passed, 0 failed, 0 skipped |
| Complete remediation suite | 93 passed, 0 failed, 0 skipped |
| Focused regressions and existing batch-gas tests | 25 passed, 0 failed, 0 skipped |
| Hook and deployment/interaction script compilation | Passed with existing warnings |
| Solidity formatting and staged diff checks | Passed |
| Full 64-order batch settlement | 6,615,370 gas; unchanged budget 8,000,000 |
| Hook runtime / initcode | 17,759 / 18,611 bytes; within EVM limits |

Verification used the pinned toolchain and dependency revisions. Tests ran
locally, including 256 configured fuzz runs and the stateful invariant
campaigns. The compiler checks retained existing unused-variable and ERC20
return-value warnings; this is not a claim of warning-free static analysis.
Windows checkout line endings were normalized to LF for the formatting
check without adding unrelated source changes to the commits.

An independent patch review identified an accounting-window callback gap
in the first candidate. Its defensive regression tests failed before the
correction and passed afterward. The correction separates settlement from
recipient delivery for both native and ERC20 outputs. The revised patch
was regression-tested; there was no second independent review cycle.

The initial scan and these checks do not establish live deployment
correspondence, unrestricted token compatibility, or a complete economic
security proof. The four recorded findings have local source/test fixes;
existing deployed contracts are unchanged.

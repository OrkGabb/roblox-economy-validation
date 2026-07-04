# AC/ STATUS — Economy Validation Layer: Unification & Hardening

**State: complete.** The two extracted reference implementations
(`AC/ClickGame/`, `AC/PSU/`, `AC/Shared/`) have been unified into one
canonical, config-injected module set under `AC/Core/` and the reference
copies deleted (provenance stays in `AC/EXTRACTION_LOG.md` + git history; the
untouched originals still live in `ClickGame/` and `PSU/` at repo root).

All 8 modules pass `luau-lsp analyze` under `--!strict` with Roblox type
definitions and a Rojo sourcemap (zero diagnostics). Wiring guide for buyers:
`AC/Core/README.md`.

## The canonical set

| Concern | Module | Won | Merged in / discarded |
|---|---|---|---|
| Rate limiting | `RateLimiter.luau` | PSU token bucket | + sigma macro detection (PSU AntiExploit); ClickGame fixed window discarded |
| Currency choke point | `CurrencyLedger.luau` | ClickGame Add/Deduct shape | + PSU NaN/Inf hardening, generalized to named currencies |
| Click pipeline | `ClickEconomy.luau` | Merge of both | ClickGame single-entry-point rule + PSU bucket/partial grants + PSU accumulator shape |
| Passive income | `PassiveAccrual.luau` | Either (near-identical) | Generalized to injected multi-currency rates |
| Upgrade purchase | `PurchaseValidator.luau` | Merge of both | PSU caps/NaN-reject/sanitize + ClickGame ledger-only mutation |
| Receipt processing | `ReceiptProcessor.luau` | Merge of both | PSU unknown-product policy; new in-flight guard (see below) |
| Gamepass ownership | `GamepassCache.luau` | ClickGame fail-safe core | + PSU persisted-history fallback |
| Anti-duplication | `GuidClaimTicket.luau` | Already canonical | Moved verbatim (header updated to convention) |

Every module is dependency-injected (`Init(config)` with callbacks into the
buyer's profile/registry code) — no `require`s into game-specific config, per
the "drop into any game in under an hour" goal. The extracted copies all had
dangling requires (`UpgradeRegistry`, `FeatureResolver`, `ShopConfig`, ...);
that coupling is now entirely the integrator's side of the boundary.

## Judgment calls, per the brief

### 1. RateLimiter: ClickGame's module vs. PSU's inline token bucket

**Kept PSU's algorithm, in ClickGame's packaging.** The token bucket wins on
math: a fixed calls-per-window counter (ClickGame) permits a 2× burst
straddling every window boundary and can only accept-or-drop a whole call,
while the bucket bounds burst *and* sustained rate and grants partially (a
legit over-sized batch after a network hiccup earns what the budget allows
instead of being zeroed). Reusable-module packaging (ClickGame) wins
structurally, as the brief predicted — every consumer imports one
`RateLimiter.new{...}` instead of reimplementing bucket math (which is exactly
how PSU ended up with *two* divergent inline buckets, ClickService's and
AntiExploitService's).

Refill is lazy (computed from elapsed time on each `Consume`), taken from
PSU's ClickService rather than AntiExploitService's heartbeat-driven
`RefillTokens()` — the latter silently freezes every bucket if the integrator
forgets the Heartbeat wiring, which is a footgun in a sellable product.

### 2. Accumulator math: did PSU reintroduce the CPK double-credit bug?

**No — verified before choosing.** The bug ClickGame fixed was
*delta-tracking*: comparing a `cupcakesAwarded` counter against a separately
updated `totalClicks` and crediting the difference, which double-credits when
the two fields are read/written out of step. Both extracted versions use the
replacement shape: one running accumulator field, mint `accumulator //
clicksPerMint`, carry `accumulator % clicksPerMint`. PSU avoided the bug
because its ClickService is a *descendant* of the ClickGame fix (written
after, to the fixed pattern), not an independent re-derivation. The canonical
`ClickEconomy` keeps PSU's local-variable shape (cleaner, `//` operator) plus
ClickGame's mint multiplier — applied to the **minted amount**, never the
click ratio, so mints stay whole integers and the accumulator math is
untouched by gamepass effects. The bug class is documented at the code site.

### 3. Sigma macro detector: straightforward merge, with one real design constraint

**Mechanically straightforward** — it now lives inside `RateLimiter.Consume`
as an optional `macroDetection` config, sharing the bucket's per-player state,
so any consumer gets rate + regularity gating from one call. This also closes
EXTRACTION_LOG item 4: `ClickEconomy.ProcessClicks` runs through both signals
by construction, so the "built but never wired into the crediting path" gap
cannot recur.

**The constraint discovered while merging (why it's opt-in, default off):**
the sigma signal assumes one call per physical input. ClickGame's legit client
*batches* clicks on a 0.5s timer — its remote cadence is machine-perfect **by
design** and would self-flag; likewise server-side auto-clicker loops. So:
`macroDetection` must only be enabled where one remote call = one human
action (PSU's client model), and `ClickEconomy` exposes a separate trusted
`CreditServerClicks` path that shares the payout/accumulator route but skips
the limiter and detector entirely. This is documented prominently in both
modules — a buyer who enables sigma on a batched remote would ship a false-
positive machine. Flag/kick policy (the original auto-kicked at a fixed score)
is delegated to an `onFlagged` callback: threshold-to-kick is game policy,
not detection.

### 4. The choke-point refactor (EXTRACTION_LOG item 3)

`CurrencyLedger` is ClickGame's `AddCurrency`/`DeductCurrency` generalized to
named currency keys, and it is now the **only** write path: `ClickEconomy`,
`PassiveAccrual`, and `PurchaseValidator` never touch a wallet field —
PSU-style direct `profile.Data.Currencies.*` writes (ClickService,
UpgradeService, MonetizationService all did this) do not exist anywhere in
`AC/Core/`. Hardening moved *into* the choke point so no caller can bypass it:

- **NaN/Infinity/negative rejection** on every Add/Deduct — generalized from
  PSU UpgradeService's cost check. One NaN reaching a balance poisons every
  later `>=` comparison (NaN compares false to everything), silently breaking
  all subsequent validation; negative Adds are spends that skipped the balance
  check.
- **Atomic Deduct** — check-then-write in one non-yielding function (the
  ClickGame property, kept).
- **`onMutation` audit hook** with a `reason` tag on every mutation — the
  "audit one function" payoff the refactor exists for.

### 5. PurchaseValidator: PSU's gates + ClickGame's mutation discipline

Kept from PSU: MaxLevel cap, explicit finite-cost rejection (redundant with
the ledger, kept for a clearer reject-before-milestone-math flow), and
`SanitizeOwned` (clamp tampered/legacy saved levels before any cost/payout
math reads them). Kept from ClickGame: all money moves via
`CurrencyLedger.Deduct`. Both balances are pre-checked before either deduct;
a defensive refund path covers the (currently unreachable) case of the second
deduct failing, commented as such. PSU's `SanitizeUpgrades` poll-loop wait for
profile load was **not** carried over — when to call sanitize is the
integrator's lifecycle, not the validator's.

### 6. ReceiptProcessor: one policy divergence resolved + one new guard

- **Unknown/misconfigured product → `NotProcessedYet` (PSU policy, kept).**
  ClickGame acknowledged unknown dev products as `PurchaseGranted`, which
  permanently eats the player's Robux; PSU's answer lets Roblox retry until
  the product table is fixed and the player is made whole. Discarded the
  ClickGame behavior.
- **New: per-PurchaseId in-flight guard.** If the buyer's `grant` callback
  yields, Roblox can re-deliver the same receipt mid-grant; the persisted
  ledger isn't written yet (mark-after-grant, which is itself correct —
  mark-first eats purchases when the grant errors), so the reward would land
  twice. Same double-credit class as the CPK bug, at the receipt layer.
  Neither source had this; both sources' `grant` paths happened not to yield.
- Kept: persisted PurchaseId ledger (`tostring` key), `NotProcessedYet` when
  player/profile absent, grant wrapped in pcall.
- Discarded from PSU's MonetizationService: leaderstats syncing, purchase
  notification remotes, VIP-day bookkeeping — game/UI glue, not validation.
  Its `BuyInGameItem` (flat-price soft-currency catalog purchase) was not made
  a module: it is the degenerate case of the pattern ("recompute price from
  your registry → `CurrencyLedger.Deduct` → grant only on true") and is
  documented as two lines in `PurchaseValidator`'s header and the README.

### 7. GamepassCache: the fail-safe, preserved exactly

The pcall-error-never-grants pattern is kept verbatim in behavior: ownership
is written only on a **successful** `UserOwnsGamePassAsync` call (`result ==
true`); an errored lookup leaves the entry untouched, which `Owns` reads as
false. The code comment explains *why* the failure direction matters (an
outage degrades everyone to baseline — recoverable — instead of granting paid
multipliers to everyone — unrecoverable inflation). Merged from PSU: the
persisted `"GP_<id>"` history fallback (Studio test purchases, outage-window
purchases) and purchase-time persistence; from ClickGame: the
`PromptGamePassPurchaseFinished` refresh-without-rejoin and the stacked-
multiplier helper (generalized to a caller-supplied `{passKey = multiplier}`
map instead of hardcoded Cookie/Cupcake fields). ClickGame ShopService's
separate `GrantGamepass`/`ownedPasses` persistence was discarded as redundant
with the history fallback.

### 8. Passive accrual

Both implementations were near-identical descendants of the same design; the
canonical module preserves the two load-bearing details with comments naming
the bug each prevents: **in-memory-only `lastAccrual`** (persisting it is the
offline-earnings double-credit bug; rejoin must reset it) and
**always-advance-the-clock** (otherwise the first tick after a slow profile
load credits the whole load time as a startup burst). Rates come from one
injected `getRates(player) → {currency = perSecond}` — PSU's auto-clicker
gamepass income folds in there (or via `CreditServerClicks` if it should feed
the click accumulator, per ClickGame's model; README notes both).

### 9. Discarded entirely

- `EconomyMath.luau` (ClickGame) as a module — it is upgrade-config math
  coupled to `UpgradeConfig`/`EffectRegistry`/`CupcakeConfig`. The *pattern*
  it carried ("recompute server-side, never trust the client's number")
  survives as the injected `getClickPower`/`getRates`/`getCost` callbacks;
  the formulas themselves are the buyer's game design.
- ClickGame `ValidationSystem`'s accept-only-clamp of oversized batches
  (superseded by bucket partial grants), and both codebases' inline
  quest/achievement/level hooks (out of scope; `onMutation`/`onPurchased`
  callbacks are the integration points).

## Testing / verification posture

- `luau-lsp analyze` (latest, with `globalTypes.d.luau` + Rojo sourcemap):
  **0 errors, 0 warnings** across `AC/Core/*.luau` under `--!strict`.
- No runtime harness exists in this repo for these modules (they are
  Roblox-server-bound); behavioral fidelity was preserved by deriving each
  function from the battle-tested source lines rather than rewriting from
  theory, per the brief.
- Every historical-bug guard carries a code comment naming the bug class it
  prevents (CPK delta-tracking double-credit, ownership-defaults-on-error,
  NaN balance poisoning, receipt re-delivery double-grant, offline-time
  double-credit, startup-burst crediting, window-boundary burst straddle,
  frozen-bucket refill footgun) — the credibility requirement.

## Scope discipline

Nothing outside currency/inventory integrity was added: no movement/combat
checks, no UI, no genre content. The sigma detector was taken only as an
action-timing validator; teleport/fly/rig enforcement stayed out. Suspicion
*policy* (kick thresholds) is explicitly delegated out of the layer.

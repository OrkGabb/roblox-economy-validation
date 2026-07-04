# Roblox Economy Validation Layer

Server-authoritative currency validation layer for Roblox games. Unified from two
independently battle-tested implementations.

Eight `--!strict`, dependency-injected Luau modules covering the full surface of
economy integrity: rate limiting, a single currency-mutation choke point, the
click-to-currency pipeline, passive income accrual, upgrade purchase validation,
idempotent receipt processing, gamepass ownership caching, and one-shot
anti-duplication claim tickets. None of them `require` a specific game's config or
registries — everything game-specific is injected through `Init(config)`, so the
folder drops into `ServerScriptService` of any Roblox game in under an hour.

**Provenance:** this is not a from-scratch design exercise. Both source codebases
(a live idle-clicker and a separate PSU-based project) independently converged on —
or diverged on, forcing a real engineering decision — the same handful of currency
bug classes. `STATUS.md` in this repo is the actual decision record from that
unification: which implementation won each concern, why, and what bug class each
merged guard prevents. It's included verbatim as the primary technical artifact here,
not summarized away.

## Modules

| Module | Concern |
|---|---|
| `CurrencyLedger` | The choke point. Every credit is `Add`, every spend is `Deduct` (atomic check-then-write, non-yielding). NaN/Infinity/negative amounts are rejected here, unbypassable by any caller. |
| `RateLimiter` | Per-player token bucket (burst + sustained rate) with optional sigma-based macro detection — flags machine-*regular* click timing, not just fast timing. |
| `ClickEconomy` | One untrusted (remote) and one trusted (server-simulated) entry point into a single payout path, so an auto-clicker gamepass can never earn on a different formula than a real click. |
| `PassiveAccrual` | Passive income with an in-memory-only accrual clock — rejoin can never double-credit offline time, and a slow profile load never pays out a startup burst. |
| `PurchaseValidator` | Server-to-client upgrade purchases: cost/cap/milestone recomputed server-side from your registry, tampered saved-level sanitization, ledger-only mutation. |
| `ReceiptProcessor` | The single idempotent `ProcessReceipt` owner: persisted PurchaseId ledger, mark-after-grant, and an in-flight guard against re-delivery mid-grant. |
| `GamepassCache` | O(1) ownership checks with fail-safe-to-false semantics — a MarketplaceService error can never grant a paid effect. Optional persisted-history fallback for outage windows. |
| `GuidClaimTicket` | One-shot GUID claim tickets: consumed on first sight, so double-claims and replays are structurally impossible, not just rate-limited. |

`src/Server/ServerEntry.server.luau` in this repo wires all eight modules together
against an in-memory fake profile and runs a full smoke test on player join (rate
limiter exhaustion, overdraft rejection, click-to-mint accumulator math, purchase
gating, gamepass fail-safe, GUID replay rejection, receipt idempotency) — useful both
as a live demo and as the wiring reference for integrating into a real game.

## Bug classes prevented

Each guard below exists because a concrete, previously-shipped bug forced it. One
sentence each on why it matters; full reasoning and the source lineage for each is in
`STATUS.md`.

- **CPK-style double-credit (delta-tracking vs. accumulator).** Comparing a
  "rewarded so far" counter against a separately-updated "total" counter double-credits
  the instant the two fields are read/written out of step (e.g. across a batched
  network call). `ClickEconomy` uses one running accumulator with no second value to
  drift against — the balance is always a concrete integer, structurally immune to
  this class.
- **NaN/Infinity balance poisoning.** A NaN reaching a currency balance silently
  breaks every later `>=` comparison against it (NaN compares `false` to everything),
  which means every subsequent purchase/spend check involving that balance
  mis-validates without ever throwing an error. `CurrencyLedger` rejects non-finite
  and negative amounts at the one choke point every mutation must pass through.
- **Gamepass fail-safe direction.** An ownership check that defaults to `true` on
  error turns a `MarketplaceService` outage into an economy-wide inflation event
  (every player gets the paid multiplier, permanently, with no clawback). `GamepassCache`
  writes ownership only on a *successful* lookup; an error leaves the entry untouched,
  which reads as "not owned" — an outage degrades everyone to baseline instead.
- **Receipt double-grant on re-delivery.** Roblox can call `ProcessReceipt` again for
  the same purchase while a slow grant callback is still yielding, because the
  persisted "processed" flag isn't written until after the grant succeeds (writing it
  first would eat the purchase if the grant errors). Without a guard, the re-delivery
  credits the reward twice. `ReceiptProcessor` tracks in-flight PurchaseIds in memory
  and returns `NotProcessedYet` for a receipt currently mid-grant, closing the window
  the persisted ledger alone can't cover.
- **Unknown/misconfigured product eating a real purchase.** Acknowledging an unknown
  dev product as granted permanently keeps the player's Robux with nothing delivered.
  `ReceiptProcessor` returns `NotProcessedYet` instead, so Roblox retries once the
  product table is fixed and the player is made whole.
- **Rate-limiter window-boundary burst.** A fixed calls-per-window counter permits a
  2× burst by timing a second full batch to straddle the window boundary, and can
  only accept-or-drop a whole call. `RateLimiter`'s token bucket bounds burst and
  sustained rate simultaneously and grants partially, so a legitimate oversized batch
  (network hiccup) earns what the budget allows instead of being zeroed outright.
- **Frozen-bucket refill footgun.** A heartbeat-driven refill silently freezes every
  player's bucket forever if the integrator forgets to wire the per-frame call — an
  easy mistake in a sellable, drop-in module. `RateLimiter` refills lazily from
  elapsed wall-clock on every `Consume`, so there is no separate wiring step that can
  be skipped.
- **Macro detection that never gets wired into the crediting path.** A sigma-based
  timing-regularity detector existed in one source codebase but was never actually
  called from anywhere that credits currency — built, self-tested, and inert.
  `RateLimiter.Consume` runs the macro check inline with the token-bucket check, so
  any consumer gets both signals by construction; there is no second integration step
  to forget.
- **Offline-earnings double-credit / startup burst.** Persisting the "last accrual"
  timestamp lets a rejoin re-credit time that already elapsed while offline; *never*
  advancing the clock during a slow profile load instead credits the entire load time
  as one startup burst the moment the profile becomes available. `PassiveAccrual`
  keeps the timestamp in-memory-only (reset on join) and always advances it every
  tick regardless of profile state, closing both failure modes with one invariant.
- **Tampered/legacy saved levels feeding cost math.** An out-of-range upgrade level
  from a tampered or stale save silently propagates into every subsequent cost and
  payout computation for that upgrade. `PurchaseValidator.SanitizeOwned` clamps saved
  levels to the registry cap once per join, before any purchase math reads them.
- **Claim-then-reward race on limited-time pickups.** Validating a claim and then
  destroying its record leaves a window where a second concurrent claim on the same
  token can also pass validation before the first write lands. `GuidClaimTicket`
  deletes the GUID from the pending set the instant it's seen — before the expiry
  check even runs — so a replay fails structurally rather than probabilistically.

## Wiring

```luau
local Core = ServerScriptService.Server -- this folder
local CurrencyLedger = require(Core.CurrencyLedger)
local ClickEconomy = require(Core.ClickEconomy)
local PassiveAccrual = require(Core.PassiveAccrual)
local PurchaseValidator = require(Core.PurchaseValidator)
local ReceiptProcessor = require(Core.ReceiptProcessor)
local GamepassCache = require(Core.GamepassCache)

-- 1) The choke point. getWallet returns your profile's currency table.
CurrencyLedger.Init({
	getWallet = function(player)
		local profile = MyData.Profiles[player]
		return profile and profile.Data.Currencies
	end,
	onMutation = function(player, currency, delta, newBalance, reason)
		-- optional: analytics / audit log
	end,
})

-- 2) Gamepasses (fail-safe cache).
GamepassCache.Init({
	passes = { VIP = 12345678, Golden = 87654321 },
	getPersistedHistory = function(player)
		local profile = MyData.Profiles[player]
		return profile and profile.Data.PurchaseHistory
	end,
})

-- 3) Clicks. Recompute payout from YOUR registry — never the client.
ClickEconomy.Init({
	getClickPower = function(player)
		return 1 + MyUpgrades.ComputeStat(player, "PerClick")
	end,
	getIncomeMultiplier = function(player)
		return GamepassCache.GetStackedMultiplier(player, { VIP = 2 })
	end,
	maxClickBurst = 30,
	clickRefillRate = 20,
	-- macroDetection = { onFlagged = ... }, -- ONLY if one remote call = one physical click
})
clickRemote.OnServerEvent:Connect(function(player, batch)
	ClickEconomy.ProcessClicks(player, batch)
end)

-- 4) Passive income (server truth; client tickers are prediction only).
PassiveAccrual.Init({
	getRates = function(player)
		return { Primary = MyUpgrades.ComputeStat(player, "Passive") }
	end,
})

-- 5) Upgrade purchases (client sends an id, nothing else).
PurchaseValidator.Init({
	getMaxLevel = function(id) return MyUpgrades.Defs[id] and MyUpgrades.Defs[id].MaxLevel end,
	getCost = function(id, level) return MyUpgrades.GetCost(id, level) end,
	getUpgrades = function(player)
		local profile = MyData.Profiles[player]
		return profile and profile.Data.Upgrades
	end,
})
upgradeRemote.OnServerEvent:Connect(function(player, id)
	PurchaseValidator.TryPurchase(player, id)
end)
-- After each profile loads: PurchaseValidator.SanitizeOwned(player)

-- 6) Dev products (this is the game's ONLY ProcessReceipt assignment).
ReceiptProcessor.Init({
	getReceiptLedger = function(player)
		local profile = MyData.Profiles[player]
		return profile and profile.Data.PurchaseHistory
	end,
	grant = function(player, productId)
		local product = MyProducts[productId]
		if not product then return false end -- Roblox retries until configured
		return CurrencyLedger.Add(player, product.currency, product.amount, "receipt")
	end,
})
```

## The one rule

**No service ever writes a currency field directly.** Clicks, passive income,
receipts, refunds, and admin grants all go through `CurrencyLedger.Add`/`Deduct`. Any
new system that touches money takes the ledger as its only write path.

## Verification

`luau-lsp analyze` reports 0 errors / 0 warnings across all 8 modules under
`--!strict` with Roblox type definitions and a Rojo sourcemap. `src/Server/ServerEntry.server.luau`
is a runnable smoke test (see above) rather than a substitute for a full unit-test
harness — these modules are Roblox-server-bound, so behavioral fidelity was validated
by deriving each function from the two proven source implementations rather than
rewriting from theory. Every guard carries a code comment naming the specific bug
class it prevents, cross-referenced in `STATUS.md`.

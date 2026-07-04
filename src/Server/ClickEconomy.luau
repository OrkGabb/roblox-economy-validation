--!strict
-- @Author @OrkGabb
-- AC/Core/ClickEconomy.luau
--
-- Authoritative click -> currency pipeline. ONE entry point for every earning
-- path: the untrusted client remote goes through ProcessClicks (rate limiter
-- + optional macro detector), and server-side simulated clicks (auto-clicker
-- gamepass and the like) go through CreditServerClicks. Both funnel into the
-- same internal credit path, so simulated clicks inherit the exact same
-- payout math and accumulator accrual — there is no parallel earning path to
-- keep in sync (the ClickGame ValidationSystem insight, preserved).
--
-- Unified from ClickGame ValidationSystem + PSU ClickService. Everything the
-- client sends is treated as a HINT, never a value: the click count is
-- sanitized and clamped, the payout is recomputed server-side via the
-- injected getClickPower, and all credits go through CurrencyLedger.
--
-- Integration fix carried in from the extraction review: the sigma-based
-- macro detector existed in PSU but was never called from the crediting path.
-- Here it rides inside RateLimiter.Consume, so enabling `macroDetection` in
-- the config gates every remote-driven click with BOTH signals (rate + timing
-- regularity). Enable it only if your client fires one remote per physical
-- click — see the warning in RateLimiter.luau about fixed-cadence batchers.

local CurrencyLedger = require(script.Parent.CurrencyLedger)
local RateLimiter = require(script.Parent.RateLimiter)

local ClickEconomy = {}

export type SecondaryMintConfig = {
	currency: string, -- ledger key the minted currency is credited to
	clicksPerMint: number, -- manual clicks per 1 minted unit
	-- Persisted per-player table where the carry-forward remainder lives
	-- (field `ClickAccumulator`), e.g. a genre sub-table of the profile.
	-- Must be persisted with the profile, or remainders vanish on rejoin.
	getState: (player: Player) -> { [string]: any }?,
	-- Multiplies the MINTED amount (e.g. x2 gamepass), never the click ratio —
	-- so the mint stays a whole integer and the accumulator math is untouched.
	getMintMultiplier: ((player: Player) -> number)?,
}

export type Config = {
	primaryCurrency: string?, -- ledger key for click income (default "Primary")
	-- Server-side recompute of the per-click payout from the player's owned
	-- upgrades/state. NEVER derived from anything the client sends.
	getClickPower: (player: Player) -> number,
	getIncomeMultiplier: ((player: Player) -> number)?, -- gamepass/rebirth stacking (default 1)
	maxClickBurst: number?, -- token bucket capacity (default 30)
	clickRefillRate: number?, -- sustained clicks/sec cap (default 20)
	macroDetection: RateLimiter.MacroDetectionConfig?,
	secondaryMint: SecondaryMintConfig?,
}

local _config: Config? = nil
local _limiter: RateLimiter.RateLimiter? = nil

local function getConfig(): (Config, RateLimiter.RateLimiter)
	local config, limiter = _config, _limiter
	if not config or not limiter then
		error("[ClickEconomy] Init() must be called before use", 3)
	end
	return config, limiter
end

function ClickEconomy.Init(config: Config): ()
	_config = config
	_limiter = RateLimiter.new({
		maxBurst = config.maxClickBurst or 30,
		refillRate = config.clickRefillRate or 20,
		macroDetection = config.macroDetection,
	})
end

-- The single payout path. `clickCount` is already validated by the caller.
local function credit(config: Config, player: Player, clickCount: number): ()
	local incomeMultiplier = if config.getIncomeMultiplier then config.getIncomeMultiplier(player) else 1
	-- Floor the per-click value (not the total) so payout scales exactly
	-- linearly with click count; a NaN/Infinity from a bad multiplier is then
	-- rejected by the ledger, never written.
	local gain = math.floor(config.getClickPower(player) * incomeMultiplier) * clickCount
	if gain > 0 then
		CurrencyLedger.Add(player, config.primaryCurrency or "Primary", gain, "click")
	end

	local mint = config.secondaryMint
	if mint and mint.clicksPerMint > 0 then
		local state = mint.getState(player)
		if state then
			-- Accumulator carry-forward (the CPK double-credit fix, preserved
			-- from ClickGame and PSU): keep a plain running click tally, mint
			-- one unit per full clicksPerMint, carry the remainder. The old
			-- delta-tracking design (compare a mints-awarded counter against a
			-- separately-updated totalClicks) double-credited whenever the two
			-- fields were read/written out of step; a single accumulator field
			-- has no second value to drift against — the balance is always a
			-- concrete integer with no prediction or stale-read surface.
			local accumulator = ((state.ClickAccumulator :: number?) or 0) + clickCount
			local minted = accumulator // mint.clicksPerMint
			state.ClickAccumulator = accumulator % mint.clicksPerMint
			if minted > 0 then
				local mintMultiplier = if mint.getMintMultiplier then mint.getMintMultiplier(player) else 1
				CurrencyLedger.Add(player, mint.currency, minted * mintMultiplier, "click-mint")
			end
		end
	end
end

-- UNTRUSTED entry point: wire your click remote's OnServerEvent here.
-- `requested` is the raw remote argument. Returns the number of clicks
-- actually credited (0 = rejected/empty bucket/macro flag), which is also all
-- the caller needs for optional feedback to the client.
function ClickEconomy.ProcessClicks(player: Player, requested: unknown): number
	local config, limiter = getConfig()

	local count: number
	if requested == nil then
		count = 1 -- bare Fire() = one click
	elseif typeof(requested) == "number" and requested == requested and requested < math.huge then
		count = math.clamp(math.floor(requested), 1, config.maxClickBurst or 30)
	else
		-- Exotic payloads (tables, strings, NaN, Infinity) are rejected
		-- outright rather than coerced — only an exploiter sends them, and a
		-- NaN allowed further in would poison the bucket/balance arithmetic.
		return 0
	end

	local granted = limiter:Consume(player, count)
	if granted <= 0 then
		return 0
	end

	credit(config, player, granted)
	return granted
end

-- TRUSTED entry point for server-initiated clicks (auto-clicker gamepass
-- loops etc.). Shares the exact payout/accumulator path with ProcessClicks
-- but skips the limiter and macro detector: a server timer's machine-perfect
-- cadence is legitimate by construction and would self-flag the sigma check.
-- Never expose this to a remote.
function ClickEconomy.CreditServerClicks(player: Player, count: number): number
	local config = getConfig()
	if typeof(count) ~= "number" or count ~= count or count >= math.huge or count < 1 then
		return 0
	end
	local clickCount = math.floor(count)
	credit(config, player, clickCount)
	return clickCount
end

return ClickEconomy

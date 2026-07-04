--!strict
-- @Author @OrkGabb
-- AC/Core/RateLimiter.luau
--
-- Canonical per-player rate limiter for currency-earning actions: a lazily
-- refilled token bucket (burst + sustained-rate control) with optional
-- machine-timing ("macro") detection layered on top of the same Consume call.
--
-- Unified from two proven implementations:
--   * PSU ClickService's inline token bucket — kept as the core algorithm. A
--     token bucket bounds BOTH burst size and sustained rate and degrades
--     gracefully (partial grants) under network jitter. The fixed
--     calls-per-window counter it replaces (ClickGame RateLimiter) permits a
--     2x burst straddling every window boundary and can only accept-or-drop
--     a whole batch.
--   * PSU AntiExploitService's rolling-window standard-deviation ("sigma")
--     analysis. A human's inter-action intervals have natural jitter; a macro
--     produces near-identical intervals. Low sigma flags suspiciously REGULAR
--     timing, which a rate limiter alone can never see — a well-built macro
--     stays comfortably under any rate cap. In the source codebase this
--     detector was built and self-tested but never wired into any crediting
--     path; here it gates the same Consume() call as the bucket, so every
--     consumer gets both signals with no extra integration step.
--
-- Refill is computed lazily from elapsed wall-clock on each Consume() — no
-- Heartbeat wiring. (The source AntiExploitService required the integrator to
-- drive RefillTokens() every frame; forgetting that silently froze every
-- bucket at its starting token count.)
--
-- WHERE MACRO DETECTION BELONGS: enable `macroDetection` only for actions
-- fired directly by human input (one call per click/tap). Do NOT enable it on
-- fixed-cadence batch remotes — a legit client that batches clicks on a 0.5s
-- timer has machine-perfect send timing BY DESIGN — nor on server-internal
-- callers (auto-clicker gamepass loops). Both would self-flag instantly.

local Players = game:GetService("Players")

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type MacroDetectionConfig = {
	windowSize: number?, -- intervals per analysis window (default 20)
	sigmaThreshold: number?, -- flag when the stddev of intervals drops below this, seconds (default 0.002)
	maxInterval: number?, -- intervals >= this are idle gaps, not part of one action train (default 1.0)
	-- Called on every macro flag. Kick/ban policy is deliberately the
	-- caller's: the source auto-kicked at a fixed score, but that threshold is
	-- game policy, not detection.
	onFlagged: ((player: Player, sigma: number, suspicionScore: number) -> ())?,
}

export type Config = {
	maxBurst: number, -- bucket capacity: most actions grantable at once
	refillRate: number, -- tokens regained per second (sustained actions/sec cap)
	macroDetection: MacroDetectionConfig?,
}

type PlayerState = {
	tokens: number,
	lastRefill: number,
	lastAction: number,
	intervals: { number },
	suspicionScore: number,
}

export type RateLimiter = typeof(setmetatable(
	{} :: {
		_maxBurst: number,
		_refillRate: number,
		_macro: MacroDetectionConfig?,
		_states: { [Player]: PlayerState },
	},
	RateLimiter
))

-- Population standard deviation of the interval window. n < 2 returns 1.0
-- (i.e. "plenty of jitter"), so a short window can never trip the threshold.
local function standardDeviation(values: { number }): number
	local n = #values
	if n < 2 then
		return 1.0
	end
	local sum = 0
	for _, v in ipairs(values) do
		sum += v
	end
	local mean = sum / n
	local varianceSum = 0
	for _, v in ipairs(values) do
		varianceSum += (v - mean) ^ 2
	end
	return math.sqrt(varianceSum / n)
end

function RateLimiter.new(config: Config): RateLimiter
	local self = setmetatable({
		_maxBurst = config.maxBurst,
		_refillRate = config.refillRate,
		_macro = config.macroDetection,
		_states = {} :: { [Player]: PlayerState },
	}, RateLimiter)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._states[player] = nil
	end)

	return self
end

local function getState(self: RateLimiter, player: Player, now: number): PlayerState
	local state = self._states[player]
	if not state then
		state = {
			tokens = self._maxBurst, -- bucket starts full: first join gets full burst headroom
			lastRefill = now,
			lastAction = 0,
			intervals = {},
			suspicionScore = 0,
		}
		self._states[player] = state
	end
	return state
end

-- Requests `requested` action tokens (default 1) for the player. Returns how
-- many were granted: min(requested, whole tokens available), or 0 when the
-- bucket is empty or the macro detector flags the call. Partial grants let a
-- legitimate over-sized batch (network hiccup delivering two batches at once)
-- earn what the budget allows instead of being dropped wholesale.
function RateLimiter.Consume(self: RateLimiter, player: Player, requested: number?): number
	-- Sanitize even here (callers should have already): a NaN/Infinity request
	-- must never reach the bucket arithmetic, where it would poison `tokens`
	-- and every later comparison against it.
	local count = 1
	if typeof(requested) == "number" and requested == requested and requested < math.huge then
		count = math.clamp(math.floor(requested), 1, self._maxBurst)
	end

	local now = os.clock()
	local state = getState(self, player, now)

	-- Lazy refill from elapsed wall-clock.
	local elapsed = now - state.lastRefill
	state.tokens = math.min(self._maxBurst, state.tokens + elapsed * self._refillRate)
	state.lastRefill = now

	if state.tokens < 1 then
		return 0
	end

	local granted = math.min(count, math.floor(state.tokens))
	state.tokens -= granted

	-- Macro (regularity) analysis on the inter-call intervals. Runs AFTER the
	-- bucket so a flagged call still spends its tokens — flagging must never
	-- be cheaper than being rate-limited.
	local macro = self._macro
	if macro then
		local delta = now - state.lastAction
		state.lastAction = now

		local maxInterval = macro.maxInterval or 1.0
		if delta < maxInterval then
			local windowSize = macro.windowSize or 20
			table.insert(state.intervals, delta)
			if #state.intervals > windowSize then
				table.remove(state.intervals, 1)
			end

			if #state.intervals == windowSize then
				local sigma = standardDeviation(state.intervals)
				if sigma < (macro.sigmaThreshold or 0.002) then
					state.suspicionScore += 1
					warn(string.format(
						"[RateLimiter] %s flagged: machine-perfect timing (sigma %.5f, score %d)",
						player.Name,
						sigma,
						state.suspicionScore
					))
					if macro.onFlagged then
						macro.onFlagged(player, sigma, state.suspicionScore)
					end
					return 0
				end
			end
		end
	end

	return granted
end

-- Boolean convenience for single-action gates (one remote call = one action).
function RateLimiter.Check(self: RateLimiter, player: Player): boolean
	return self:Consume(player, 1) > 0
end

-- Accumulated macro-flag count for the player (0 if never seen). Read this
-- when deciding kick/ban policy outside of the onFlagged callback.
function RateLimiter.GetSuspicion(self: RateLimiter, player: Player): number
	local state = self._states[player]
	return if state then state.suspicionScore else 0
end

return RateLimiter

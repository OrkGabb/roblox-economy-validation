--!strict
-- @Author @OrkGabb
-- AC/Core/GamepassCache.luau
--
-- O(1) gamepass-ownership cache: the single source of truth economy code
-- asks about pass ownership, so no service ever calls MarketplaceService
-- directly (web call, can yield/throw) inside a crediting or purchase path.
--
-- Unified from ClickGame PlayerEffectsService + PSU MonetizationService.
--
-- THE FAIL-SAFE, preserved exactly (this is the correctness-critical detail
-- both sources converged on after getting it wrong is expensive in the
-- paid-benefit direction): every UserOwnsGamePassAsync call is wrapped in
-- pcall, and ownership is only ever written on a SUCCESSFUL call — an errored
-- lookup leaves the entry untouched, which reads as "does not own". A
-- MarketplaceService outage therefore degrades every player to baseline
-- (annoying, recoverable via Refresh) instead of granting paid multipliers to
-- everyone (an economy-wide inflation event you cannot claw back). Ownership
-- NEVER defaults to true on error.
--
-- From PSU: the optional persisted-history fallback ("GP_<id>" keys), which
-- keeps Studio test purchases and passes bought during an outage honored via
-- the profile even when the live lookup fails.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local GamepassCache = {}

export type Config = {
	-- Your pass table: { [passKey] = gamepassId }, e.g. { VIP = 12345678 }.
	passes: { [string]: number },
	-- Optional PERSISTED per-player table (e.g. profile.Data.PurchaseHistory)
	-- used as a fallback ownership record and written on in-game purchase.
	getPersistedHistory: ((player: Player) -> { [string]: boolean }?)?,
	-- Fired when a pass is bought in-game, so effects go live without rejoin.
	onOwnershipChanged: ((player: Player, passKey: string) -> ())?,
}

local _config: Config? = nil

-- { [Player] = { [passKey] = true/false } }. A missing key means "not
-- resolved yet", which Owns treats as not owned (fail-safe direction).
local owned: { [Player]: { [string]: boolean } } = {}

local function getConfig(): Config
	local config = _config
	if not config then
		error("[GamepassCache] Init() must be called before use", 3)
	end
	return config
end

-- Resolves and caches ownership of every configured pass for one player.
-- YIELDS (web calls) — call from task.spawn. Safe to call again to refresh.
function GamepassCache.Refresh(player: Player): ()
	local config = getConfig()
	local set = owned[player] or {}
	owned[player] = set

	for passKey, passId in pairs(config.passes) do
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if ok then
			set[passKey] = result == true
		else
			-- Entry left untouched on error: it never becomes true this way.
			-- See THE FAIL-SAFE in the header.
			warn(string.format("[GamepassCache] failed to verify %s for %s", passKey, player.Name))
		end
	end
end

-- O(1), never yields, never errors — safe inside any crediting/purchase path.
function GamepassCache.Owns(player: Player, passKey: string): boolean
	local set = owned[player]
	if set and set[passKey] == true then
		return true
	end

	-- Persisted fallback (Studio test purchases; passes bought while the live
	-- lookup was down).
	local config = getConfig()
	if config.getPersistedHistory then
		local passId = config.passes[passKey]
		local history = config.getPersistedHistory(player)
		if passId and history and history["GP_" .. tostring(passId)] == true then
			return true
		end
	end

	return false
end

-- Stacked multiplier over the passes the player owns: pass { [passKey] =
-- multiplier } and owned entries multiply together (VIP x2 * Golden x2 = x4).
-- Unowned/unresolved passes contribute nothing, so the result for a player
-- who owns nothing — or whose lookups all failed — is exactly 1.0.
function GamepassCache.GetStackedMultiplier(player: Player, multipliers: { [string]: number }): number
	local result = 1.0
	for passKey, multiplier in pairs(multipliers) do
		if GamepassCache.Owns(player, passKey) then
			result *= multiplier
		end
	end
	return result
end

function GamepassCache.Init(config: Config): ()
	_config = config

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(GamepassCache.Refresh, player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		owned[player] = nil
	end)
	-- Players already present when the server boots (Studio Play solo, late require).
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(GamepassCache.Refresh, player)
	end

	-- In-game purchase: cache + persist immediately so the effect is live
	-- without a rejoin. This signal comes from the Roblox engine server-side,
	-- not from a client remote — it is trusted.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, wasPurchased: boolean)
			if not wasPurchased then
				return
			end
			for passKey, configId in pairs(config.passes) do
				if configId == passId then
					local set = owned[player] or {}
					owned[player] = set
					set[passKey] = true

					if config.getPersistedHistory then
						local history = config.getPersistedHistory(player)
						if history then
							history["GP_" .. tostring(passId)] = true
						end
					end
					if config.onOwnershipChanged then
						config.onOwnershipChanged(player, passKey)
					end
					break
				end
			end
		end
	)
end

return GamepassCache

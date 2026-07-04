--!strict
-- @Author @OrkGabb
-- AC/Core/PurchaseValidator.luau
--
-- Server-to-client upgrade-purchase validation. The invariant, from both
-- source implementations: the client sends ONLY an upgrade id; cost, currency,
-- level cap, and milestone gates are all recomputed server-side from your
-- registry, and money moves only through CurrencyLedger.
--
-- Unified from ClickGame PurchaseSystem + PSU UpgradeService, keeping the
-- best of each:
--   * PSU's MaxLevel cap enforcement, its explicit NaN/Infinity/negative
--     rejection on computed costs (also enforced again by the ledger — a cost
--     formula fed a huge saved level can overflow to inf/NaN, and that must
--     fail the purchase, not corrupt a balance), and its SanitizeOwned pass
--     that clamps out-of-range saved levels before any purchase math runs.
--   * ClickGame's rule that ALL mutations go through the ledger's atomic
--     Deduct — PSU wrote profile.Data.Currencies fields directly, which is
--     the choke-point violation this module set exists to close.
--
-- For flat-price catalog purchases (buy item X for N coins) you don't need
-- this module's level machinery: recompute the price from your registry,
-- CurrencyLedger.Deduct, and grant only on true — same invariant, two lines.

local CurrencyLedger = require(script.Parent.CurrencyLedger)

local PurchaseValidator = {}

export type Config = {
	-- Level cap for an upgrade id; nil means the id is unknown (purchase
	-- rejected). Return math.huge for genuinely uncapped upgrades.
	getMaxLevel: (upgradeId: string) -> number?,
	-- Cost to go from currentLevel to currentLevel + 1, plus the ledger
	-- currency key it is paid in (nil currency defaults to "Primary").
	-- Return nil cost to make a level unpurchasable.
	getCost: (upgradeId: string, currentLevel: number) -> (number?, string?),
	-- Optional extra gate: cost in a second currency for the purchase that
	-- lands on newLevel (0 = not a milestone). E.g. every 5th level costs
	-- cupcakes on top of the base price.
	getMilestoneCost: ((upgradeId: string, newLevel: number) -> (number, string))?,
	-- The player's mutable persisted { [upgradeId] = ownedLevel } table, or
	-- nil while the profile is unavailable.
	getUpgrades: (player: Player) -> { [string]: number }?,
	-- Fired after a successful purchase (sync to client, quests, analytics).
	onPurchased: ((player: Player, upgradeId: string, newLevel: number) -> ())?,
}

local _config: Config? = nil

local function getConfig(): Config
	local config = _config
	if not config then
		error("[PurchaseValidator] Init() must be called before use", 3)
	end
	return config
end

local function isFiniteNonNegative(n: number): boolean
	return n == n and n < math.huge and n >= 0
end

function PurchaseValidator.Init(config: Config): ()
	_config = config
end

-- Clamps saved upgrade levels to their registry cap. Call once per player
-- after their profile loads, BEFORE any purchase or payout math reads the
-- levels — a tampered/legacy save with an absurd level would otherwise feed
-- every cost and click-power computation. (PSU's SanitizeUpgrades, preserved.)
function PurchaseValidator.SanitizeOwned(player: Player): ()
	local config = getConfig()
	local owned = config.getUpgrades(player)
	if not owned then
		return
	end

	for upgradeId, level in pairs(owned) do
		local maxLevel = config.getMaxLevel(upgradeId)
		if maxLevel == nil then
			-- Unknown id in the save (removed upgrade / tampered data): leave
			-- the field for the game to decide about, but say so.
			warn(string.format("[PurchaseValidator] %s owns unknown upgrade %q", player.Name, upgradeId))
		elseif level > maxLevel then
			warn(string.format(
				"[PurchaseValidator] %s.%s=%d > MaxLevel=%d — clamped",
				player.Name,
				upgradeId,
				level,
				maxLevel
			))
			owned[upgradeId] = maxLevel
		end
	end
end

-- Attempts to buy the next level of `upgradeId` (raw remote argument).
-- Returns true only if every gate passed and the currency actually moved.
function PurchaseValidator.TryPurchase(player: Player, upgradeId: unknown): boolean
	local config = getConfig()

	if typeof(upgradeId) ~= "string" then
		return false
	end

	local owned = config.getUpgrades(player)
	if not owned then
		return false
	end

	local maxLevel = config.getMaxLevel(upgradeId)
	if maxLevel == nil then
		return false -- unknown upgrade id
	end

	local currentLevel = owned[upgradeId] or 0
	if currentLevel >= maxLevel then
		return false
	end

	local cost, costCurrency = config.getCost(upgradeId, currentLevel)
	if cost == nil or not isFiniteNonNegative(cost) then
		return false
	end
	local baseCurrency = costCurrency or "Primary"

	local newLevel = currentLevel + 1
	local milestoneCost, milestoneCurrency = 0, ""
	if config.getMilestoneCost then
		milestoneCost, milestoneCurrency = config.getMilestoneCost(upgradeId, newLevel)
		if not isFiniteNonNegative(milestoneCost) then
			return false
		end
	end

	-- Pre-check both balances so a player who can afford the base cost but
	-- not the milestone is rejected before anything is deducted.
	if CurrencyLedger.Get(player, baseCurrency) < cost then
		return false
	end
	if milestoneCost > 0 and CurrencyLedger.Get(player, milestoneCurrency) < milestoneCost then
		return false
	end

	local reason = "upgrade:" .. upgradeId
	if not CurrencyLedger.Deduct(player, baseCurrency, cost, reason) then
		return false
	end
	if milestoneCost > 0 and not CurrencyLedger.Deduct(player, milestoneCurrency, milestoneCost, reason) then
		-- Unreachable today (nothing yields between the pre-checks and here),
		-- but if a future edit introduces a yield, the base cost must not be
		-- silently eaten.
		CurrencyLedger.Add(player, baseCurrency, cost, reason .. ":refund")
		return false
	end

	owned[upgradeId] = newLevel

	if config.onPurchased then
		config.onPurchased(player, upgradeId, newLevel)
	end
	return true
end

return PurchaseValidator

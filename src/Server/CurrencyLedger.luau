--!strict
-- @Author @OrkGabb
-- AC/Core/CurrencyLedger.luau
--
-- THE single choke point for every currency mutation. No service may write a
-- currency field directly — all credits go through Add and all spends through
-- Deduct, so auditing the economy means auditing this one file (plus grepping
-- that nothing else touches the wallet table).
--
-- This generalizes ClickGame DataService's AddCurrency/DeductCurrency shape
-- (single audit point, atomic check-then-write) to named currencies. The PSU
-- codebase had no equivalent — ClickService, UpgradeService, and
-- MonetizationService each mutated profile.Data.Currencies.* directly and
-- independently, which is exactly the structural gap this module closes.
--
-- Guards that live HERE, not in callers:
--   * NaN / Infinity / negative-amount rejection. Generalized from PSU
--     UpgradeService's overflow hardening ("cost ~= cost or cost == math.huge
--     or cost < 0"). One NaN reaching a balance poisons every later `>=`
--     comparison against it (NaN compares false to everything), silently
--     breaking all subsequent purchase validation — so the rejection belongs
--     at the choke point where no caller can bypass it.
--   * Atomic spend: Deduct checks and writes in one non-yielding function.
--     There is no separate read-balance-then-write window for another request
--     to interleave into (Luau tasks only switch at yields).

print("CurrencyLedger loaded")

local CurrencyLedger = {}

export type MutationHook = (player: Player, currency: string, delta: number, newBalance: number, reason: string) -> ()

export type Config = {
	-- Returns the player's mutable currency table (e.g. profile.Data.Currencies),
	-- or nil while the profile is not loaded. Missing keys are treated as 0.
	getWallet: (player: Player) -> { [string]: number }?,
	-- Optional audit hook, called after every successful mutation. Wire your
	-- analytics / anti-cheat logging here and every credit and spend in the
	-- game flows through it.
	onMutation: MutationHook?,
}

local _config: Config? = nil

local function getConfig(): Config
	local config = _config
	if not config then
		error("[CurrencyLedger] Init() must be called before use", 3)
	end
	return config
end

-- Amounts must be finite and non-negative. Callers express direction by
-- choosing Add vs Deduct, never by sign — a negative Add is a spend that
-- skipped the balance check, so it is rejected.
local function isValidAmount(amount: number): boolean
	return typeof(amount) == "number" and amount == amount and amount < math.huge and amount >= 0
end

function CurrencyLedger.Init(config: Config): ()
	_config = config
end

function CurrencyLedger.Get(player: Player, currency: string): number
	local wallet = getConfig().getWallet(player)
	if not wallet then
		return 0
	end
	return wallet[currency] or 0
end

-- Credits `amount` of `currency`. Returns false (and mutates nothing) if the
-- profile is unavailable or the amount is invalid. `reason` is a short audit
-- tag ("click", "passive", "receipt:12345", ...) passed to onMutation.
function CurrencyLedger.Add(player: Player, currency: string, amount: number, reason: string?): boolean
	local config = getConfig()
	if not isValidAmount(amount) then
		warn(string.format(
			"[CurrencyLedger] Rejected Add of %s %s for %s (%s)",
			tostring(amount),
			currency,
			player.Name,
			reason or "?"
		))
		return false
	end

	local wallet = config.getWallet(player)
	if not wallet then
		return false
	end

	local newBalance = (wallet[currency] or 0) + amount
	wallet[currency] = newBalance
	if config.onMutation then
		config.onMutation(player, currency, amount, newBalance, reason or "add")
	end
	return true
end

-- Spends `amount` of `currency` if — and only if — the balance covers it.
-- Check and write happen in this single non-yielding call: no caller-side
-- balance check can race against the deduction.
function CurrencyLedger.Deduct(player: Player, currency: string, amount: number, reason: string?): boolean
	local config = getConfig()
	if not isValidAmount(amount) then
		warn(string.format(
			"[CurrencyLedger] Rejected Deduct of %s %s for %s (%s)",
			tostring(amount),
			currency,
			player.Name,
			reason or "?"
		))
		return false
	end

	local wallet = config.getWallet(player)
	if not wallet then
		return false
	end

	local balance = wallet[currency] or 0
	if balance < amount then
		return false
	end

	local newBalance = balance - amount
	wallet[currency] = newBalance
	if config.onMutation then
		config.onMutation(player, currency, -amount, newBalance, reason or "deduct")
	end
	return true
end

return CurrencyLedger

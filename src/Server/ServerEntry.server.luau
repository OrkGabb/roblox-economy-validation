--!strict
local Players = game:GetService("Players")

local CurrencyLedger = require(script.Parent.CurrencyLedger)
local RateLimiter = require(script.Parent.RateLimiter)
local ClickEconomy = require(script.Parent.ClickEconomy)
local PassiveAccrual = require(script.Parent.PassiveAccrual)
local PurchaseValidator = require(script.Parent.PurchaseValidator)
local ReceiptProcessor = require(script.Parent.ReceiptProcessor)
local GamepassCache = require(script.Parent.GamepassCache)
local GuidClaimTicket = require(script.Parent.GuidClaimTicket)

print("Booting AC modules...")

-- ============================================================
-- In-memory fake "profile" per player, since there's no real
-- DataService/ProfileService wired in this smoke test.
-- ============================================================
type FakeProfile = {
	Currencies: { [string]: number },
	Upgrades: { [string]: number },
	PurchaseHistory: { [string]: boolean },
	GenreData: { ClickAccumulator: number },
}

local profiles: { [Player]: FakeProfile } = {}

local function newProfile(): FakeProfile
	return {
		Currencies = { Primary = 0, Secondary = 0 },
		Upgrades = {},
		PurchaseHistory = {},
		GenreData = { ClickAccumulator = 0 },
	}
end

Players.PlayerAdded:Connect(function(player: Player)
	profiles[player] = newProfile()
end)
Players.PlayerRemoving:Connect(function(player: Player)
	profiles[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
	profiles[player] = newProfile()
end

-- ============================================================
-- 1. CurrencyLedger
-- ============================================================
CurrencyLedger.Init({
	getWallet = function(player: Player)
		local p = profiles[player]
		return if p then p.Currencies else nil
	end,
	onMutation = function(player, currency, delta, newBalance, reason)
		print(string.format("[Ledger] %s %s %+d -> %d (%s)", player.Name, currency, delta, newBalance, reason))
	end,
})

-- ============================================================
-- 2. RateLimiter (standalone instance for manual testing)
-- ============================================================
local testLimiter = RateLimiter.new({
	maxBurst = 5,
	refillRate = 5,
})

-- ============================================================
-- 3. ClickEconomy
-- ============================================================
ClickEconomy.Init({
	primaryCurrency = "Primary",
	getClickPower = function(player: Player)
		return 1 -- fixed 1 per click for test purposes
	end,
	getIncomeMultiplier = function(player: Player)
		return GamepassCache.GetStackedMultiplier(player, { DoubleCoins = 2 })
	end,
	maxClickBurst = 30,
	clickRefillRate = 20,
	secondaryMint = {
		currency = "Secondary",
		clicksPerMint = 50,
		getState = function(player: Player)
			local p = profiles[player]
			return if p then p.GenreData else nil
		end,
	},
})

-- ============================================================
-- 4. PassiveAccrual
-- ============================================================
PassiveAccrual.Init({
	tickInterval = 1,
	getRates = function(player: Player)
		local p = profiles[player]
		if not p then
			return nil
		end
		return { Primary = 2 } -- 2/sec test rate
	end,
})

-- ============================================================
-- 5. PurchaseValidator
-- ============================================================
local UPGRADE_MAX_LEVEL = 10
local UPGRADE_BASE_COST = 10

PurchaseValidator.Init({
	getMaxLevel = function(upgradeId: string)
		if upgradeId == "TestUpgrade" then
			return UPGRADE_MAX_LEVEL
		end
		return nil
	end,
	getCost = function(upgradeId: string, currentLevel: number)
		return UPGRADE_BASE_COST * (currentLevel + 1), "Primary"
	end,
	getUpgrades = function(player: Player)
		local p = profiles[player]
		return if p then p.Upgrades else nil
	end,
	onPurchased = function(player, upgradeId, newLevel)
		print(string.format("[Purchase] %s bought %s -> level %d", player.Name, upgradeId, newLevel))
	end,
})

-- ============================================================
-- 6. ReceiptProcessor
-- ============================================================
ReceiptProcessor.Init({
	getReceiptLedger = function(player: Player)
		local p = profiles[player]
		return if p then p.PurchaseHistory else nil
	end,
	grant = function(player: Player, productId: number)
		print(string.format("[Receipt] granting product %d to %s", productId, player.Name))
		CurrencyLedger.Add(player, "Primary", 500, "receipt:" .. productId)
		return true
	end,
})

-- ============================================================
-- 7. GamepassCache
-- ============================================================
GamepassCache.Init({
	passes = { DoubleCoins = 000000000 }, -- fake id, will fail lookup safely (fail-safe test)
	getPersistedHistory = function(player: Player)
		local p = profiles[player]
		return if p then p.PurchaseHistory else nil
	end,
	onOwnershipChanged = function(player, passKey)
		print(string.format("[Gamepass] %s ownership changed: %s", player.Name, passKey))
	end,
})

-- ============================================================
-- 8. GuidClaimTicket
-- ============================================================
local claimTicket = GuidClaimTicket.new(30) -- 30s life

print("AC modules booted successfully.")

-- ============================================================
-- SMOKE TESTS
-- ============================================================
Players.PlayerAdded:Connect(function(player: Player)
	task.wait(1) -- let profile + gamepass refresh settle

	claimTicket:PlayerAdded(player)

	print("=== RateLimiter test ===")
	for i = 1, 7 do
		print(i, "granted:", testLimiter:Consume(player, 1))
	end

	print("=== CurrencyLedger test ===")
	CurrencyLedger.Add(player, "Primary", 100, "test_add")
	print("Balance:", CurrencyLedger.Get(player, "Primary"))
	local dedOk = CurrencyLedger.Deduct(player, "Primary", 30, "test_deduct")
	print("Deduct ok:", dedOk, "Balance:", CurrencyLedger.Get(player, "Primary"))
	local dedFail = CurrencyLedger.Deduct(player, "Primary", 999999, "test_overdraft")
	print("Overdraft correctly rejected:", dedFail == false)

	print("=== ClickEconomy test (51 clicks, expect 1 Secondary minted, 1 remainder) ===")
	local granted = ClickEconomy.ProcessClicks(player, 51)
	print("Clicks granted (capped by burst):", granted)
	print("Primary after clicks:", CurrencyLedger.Get(player, "Primary"))
	print("Secondary after clicks:", CurrencyLedger.Get(player, "Secondary"))

	print("=== ClickEconomy trusted path test ===")
	local serverGranted = ClickEconomy.CreditServerClicks(player, 10)
	print("Server-credited clicks:", serverGranted)

	print("=== PurchaseValidator test ===")
	PurchaseValidator.SanitizeOwned(player)
	local bought = PurchaseValidator.TryPurchase(player, "TestUpgrade")
	print("Purchase success:", bought, "Balance after:", CurrencyLedger.Get(player, "Primary"))
	local boughtUnknown = PurchaseValidator.TryPurchase(player, "NotARealUpgrade")
	print("Unknown upgrade correctly rejected:", boughtUnknown == false)

	print("=== GamepassCache fail-safe test (fake id, lookup should fail safely) ===")
	print("Owns DoubleCoins (should be false, fail-safe):", GamepassCache.Owns(player, "DoubleCoins"))
	print("Stacked multiplier (should be 1.0):", GamepassCache.GetStackedMultiplier(player, { DoubleCoins = 2 }))

	print("=== GuidClaimTicket test ===")
	local guid = claimTicket:Issue(player)
	print("Issued GUID:", guid)
	local claimedAt = claimTicket:Claim(player, guid)
	print("First claim succeeded:", claimedAt ~= nil)
	local secondClaim = claimTicket:Claim(player, guid)
	print("Second claim correctly rejected (replay):", secondClaim == nil)
	local fakeClaim = claimTicket:Claim(player, "not-a-real-guid")
	print("Unknown GUID correctly rejected:", fakeClaim == nil)

	print("=== ReceiptProcessor test (simulated, not via real MarketplaceService) ===")
	local fakeReceipt = {
		PlayerId = player.UserId,
		PurchaseId = "test-purchase-123",
		ProductId = 999,
	}
	local decision1 = ReceiptProcessor.Process(fakeReceipt)
	print("First process decision:", decision1)
	local decision2 = ReceiptProcessor.Process(fakeReceipt)
	print("Replay decision (should still be Granted, idempotent):", decision2)

	print("=== ALL SMOKE TESTS COMPLETE ===")
end)

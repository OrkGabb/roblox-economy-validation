--!strict
-- @Author @OrkGabb
-- AC/Core/ReceiptProcessor.luau
--
-- Idempotent MarketplaceService.ProcessReceipt for developer products. Owns
-- the single ProcessReceipt callback (Roblox only honors one — a second
-- assignment silently replaces the first, so exactly one module in the game
-- may set it).
--
-- Unified from ClickGame ShopService + PSU MonetizationService. Both proved
-- the same core: Roblox may deliver the same receipt more than once until we
-- return PurchaseGranted, so processed PurchaseIds are persisted in the
-- profile and checked before granting, and a receipt is marked processed only
-- AFTER its reward actually landed (mark-first would eat the purchase if the
-- grant errors).
--
-- Deliberate policy choices where the sources disagreed:
--   * Unknown/misconfigured product => NotProcessedYet (PSU's policy). Roblox
--     keeps retrying, and the player is made whole as soon as the product
--     table is fixed. ClickGame acknowledged unknown products as granted,
--     which permanently eats the player's Robux — rejected.
--   * Added here: an in-flight guard per PurchaseId. If the grant callback
--     yields (DataStore award, item roll), Roblox can deliver the SAME
--     receipt again mid-grant — the persisted ledger isn't written yet, so
--     without the guard the reward is credited twice. This is the same
--     double-credit class the accumulator fix addresses, at the receipt layer.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local ReceiptProcessor = {}

export type Config = {
	-- The PERSISTED per-player table of processed PurchaseIds (e.g.
	-- profile.Data.PurchaseHistory), or nil while the profile is unavailable.
	-- Must save with the profile — an in-memory table re-grants on rejoin.
	getReceiptLedger: (player: Player) -> { [string]: boolean }?,
	-- Delivers the reward for productId (look it up in your product registry;
	-- credit currency via CurrencyLedger.Add). Return true only when the
	-- reward has fully landed; false/error => Roblox retries later.
	grant: (player: Player, productId: number) -> boolean,
}

local _config: Config? = nil

-- PurchaseIds currently being granted (in-memory; see header).
local inFlight: { [string]: boolean } = {}

function ReceiptProcessor.Process(receiptInfo: any): Enum.ProductPurchaseDecision
	local config = _config
	if not config then
		error("[ReceiptProcessor] Init() must be called before use", 2)
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Purchased and left instantly; Roblox retries when they return.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local ledger = config.getReceiptLedger(player)
	if not ledger then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = tostring(receiptInfo.PurchaseId)

	-- Already credited (idempotency): acknowledge without re-granting.
	if ledger[purchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- A grant for this exact receipt is still running (see header).
	if inFlight[purchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	inFlight[purchaseId] = true
	local ok, granted = pcall(config.grant, player, receiptInfo.ProductId)
	inFlight[purchaseId] = nil

	if not ok then
		warn(string.format(
			"[ReceiptProcessor] grant errored for product %s / %s: %s",
			tostring(receiptInfo.ProductId),
			player.Name,
			tostring(granted)
		))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if granted ~= true then
		warn(string.format(
			"[ReceiptProcessor] product %s not granted (unknown/misconfigured?) — will retry",
			tostring(receiptInfo.ProductId)
		))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Mark processed only AFTER a successful grant (see header).
	ledger[purchaseId] = true
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function ReceiptProcessor.Init(config: Config): ()
	_config = config
	MarketplaceService.ProcessReceipt = ReceiptProcessor.Process
end

return ReceiptProcessor

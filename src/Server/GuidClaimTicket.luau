--!strict
-- @Author @OrkGabb
-- AC/Core/GuidClaimTicket.luau
--
-- One-shot GUID claim-validation ticket (anti-duplication).
--
-- Server issues a GUID per player; the client echoes it back to claim. The
-- GUID is deleted from the pending-set the instant a claim is validated —
-- before the expiry check even runs — so double-claims and replays are
-- structurally impossible, not just rate-limited. Unknown, expired, or
-- already-claimed (reused) GUIDs are rejected.
--
-- Factored out of the identical inline pattern proven in both source
-- codebases (ClickGame GoldenCookieService: "destroy cache to prevent
-- double-claiming"; PSU GoldenDropService: "consume immediately:
-- double-claims impossible"). Scope is deliberately narrow: this module owns
-- only "is this the GUID I issued, still alive, and not yet consumed" —
-- spawn cadence, reward rolling, and all other event content stay with the
-- caller, which credits the reward via CurrencyLedger on a non-nil Claim.

local HttpService = game:GetService("HttpService")

local GuidClaimTicket = {}
GuidClaimTicket.__index = GuidClaimTicket

export type GuidClaimTicket = typeof(setmetatable(
	{} :: {
		_maxLife: number,
		_pending: { [Player]: { [string]: number } },
	},
	GuidClaimTicket
))

-- maxLife: seconds a GUID stays claimable after issue (e.g. DescentDuration + DescentTolerance).
function GuidClaimTicket.new(maxLife: number): GuidClaimTicket
	local self = setmetatable({
		_maxLife = maxLife,
		_pending = {},
	}, GuidClaimTicket)
	return self
end

-- Call from Players.PlayerAdded.
function GuidClaimTicket.PlayerAdded(self: GuidClaimTicket, player: Player): ()
	self._pending[player] = {}
end

-- Call from Players.PlayerRemoving.
function GuidClaimTicket.PlayerRemoving(self: GuidClaimTicket, player: Player): ()
	self._pending[player] = nil
end

-- Drop stale, unclaimed GUIDs for a player. Call from a periodic tick loop
-- (e.g. once per second) so missed tickets don't linger in memory.
function GuidClaimTicket.Expire(self: GuidClaimTicket, player: Player): ()
	local pending = self._pending[player]
	if not pending then
		return
	end
	local now = os.time()
	for guid, issuedAt in pairs(pending) do
		if now - issuedAt > self._maxLife then
			pending[guid] = nil
		end
	end
end

-- Issue a new GUID for player, replacing any prior pending GUID — single
-- active ticket per player, bounded memory, only the newest is claimable.
-- Returns nil if the player has no tracked pending-set (not yet added /
-- already removed).
function GuidClaimTicket.Issue(self: GuidClaimTicket, player: Player): string?
	local pending = self._pending[player]
	if not pending then
		return nil
	end
	table.clear(pending)
	local guid = HttpService:GenerateGUID(false)
	pending[guid] = os.time()
	return guid
end

-- Validate and consume a claim. Returns the GUID's issue time (os.time()) on
-- success, or nil on malformed/unknown/expired/reused input. The GUID is
-- removed from the pending-set unconditionally on first sight, so a second
-- call with the same GUID always fails even if the first call is still being
-- processed.
function GuidClaimTicket.Claim(self: GuidClaimTicket, player: Player, guid: unknown): number?
	if typeof(guid) ~= "string" then
		return nil
	end

	local pending = self._pending[player]
	if not pending or not pending[guid] then
		return nil
	end

	local issuedAt = pending[guid]
	pending[guid] = nil -- consume immediately: double-claims and replays impossible

	if os.time() - issuedAt > self._maxLife then
		return nil
	end

	return issuedAt
end

return GuidClaimTicket

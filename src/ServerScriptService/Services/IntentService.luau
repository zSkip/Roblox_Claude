--!strict
-- Client → server traffic: rate-limited intents into CombatService and rate-limited hit claims into
-- HitService (one token bucket per player for each). Attack / Dodge intents a status effect blocks are dropped here (no state
-- change, no ack); defend intents always pass so a held block resumes after a stun.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Combat = ReplicatedStorage.Shared.Combat
local CombatEnums = require(Combat.CombatEnums)
local Config = require(Combat.CombatConfig)
local CombatNet = require(Combat.CombatNet)

local IntentService = { Priority = 40 }

local CombatService : any = nil
local HitService : any = nil

function IntentService.Init(_self : any, Get : (string) -> any)
	CombatService = Get("CombatService")
	HitService = Get("HitService")
end

local IS_STUDIO = RunService:IsStudio()

-- Studio-only debug mirror: counts dropped client traffic per reason as Reject_<Reason> attributes on
-- the Player, so tests can see why forged input went nowhere. Never read by gameplay.
function IntentService.Reject(Player : Player, Reason : string)
	if IS_STUDIO then
		local Key = `Reject_{Reason}`
		Player:SetAttribute(Key, ((Player:GetAttribute(Key) :: number?) or 0) + 1)
	end
end
local Reject = IntentService.Reject

type Buckets = { [Player]: { Tokens : number, Last : number } }
local IntentBuckets : Buckets = {}
local ClaimBuckets : Buckets = {}

local function Allow(Buckets : Buckets, Rate : number, Player : Player) : boolean
	local Now = os.clock()
	local B = Buckets[Player]
	if not B then
		B = { Tokens = Rate, Last = Now }
		Buckets[Player] = B
	end
	B.Tokens = math.min(Rate, B.Tokens + (Now - B.Last) * Rate)
	B.Last = Now
	if B.Tokens < 1 then
		return false
	end
	B.Tokens -= 1
	return true
end

local Actions = CombatEnums.Actions

-- intent id → the StatusController action it needs
local Gated = {
	[Actions.Attack] = "Attack",
	[Actions.Dodge] = "Dodge",
}

function IntentService.Start(_self : any)
	Players.PlayerRemoving:Connect(function(Player)
		IntentBuckets[Player] = nil
		ClaimBuckets[Player] = nil
	end)

	CombatNet.Intent:OnServer(function(Player : Player, ActionId : number, DirectionId : number)
		if not Allow(IntentBuckets, Config.IntentRate, Player) then
			Reject(Player, "RateLimited")
			return
		end
		local Character = Player.Character
		local C = Character and CombatService.Combatants[Character]
		if not C then
			Reject(Player, "NoCombatant")
			return
		end
		local Gate = Gated[ActionId]
		if Gate and not C.Status:Can(Gate) then
			Reject(Player, "EffectBlocked")
			return
		end
		if not CombatEnums.ActionNames[ActionId] then
			Reject(Player, "UnknownAction")
			return
		end
		local Direction = CombatEnums.DirectionName(DirectionId) -- 0 / unknown → nil
		if ActionId == Actions.Attack then
			CombatService.StartAttack(C, Direction)
		elseif ActionId == Actions.DefendStart then
			CombatService.DefendStart(C, Direction)
		elseif ActionId == Actions.DefendEnd then
			CombatService.DefendEnd(C)
		elseif ActionId == Actions.Dodge then
			CombatService.Dodge(C, Direction)
		end
	end)

	CombatNet.HitClaim:OnServer(function(Player : Player, NetId : number, Target : Instance?)
		Reject(Player, "ClaimsReceived") -- volume counter, not a rejection
		if not Allow(ClaimBuckets, Config.ClaimRate, Player) then
			Reject(Player, "ClaimRateLimited")
			return
		end
		local Reason = HitService.Claim(Player, NetId, Target)
		if Reason then
			Reject(Player, `Claim{Reason}`)
		end
	end)
end

return IntentService

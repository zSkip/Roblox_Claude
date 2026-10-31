--!strict
-- Client → server traffic: rate-limited intents (token bucket per player) into CombatService,
-- hit claims into HitService. Attack / Dodge intents a status effect blocks are dropped here (no state
-- change, no ack); defend intents always pass so a held block resumes after a stun.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local Buckets : { [Player]: { Tokens : number, Last : number } } = {}

local function Allow(Player : Player) : boolean
	local Now = os.clock()
	local B = Buckets[Player]
	if not B then
		B = { Tokens = Config.IntentRate, Last = Now }
		Buckets[Player] = B
	end
	B.Tokens = math.min(Config.IntentRate, B.Tokens + (Now - B.Last) * Config.IntentRate)
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
		Buckets[Player] = nil
	end)

	CombatNet.Intent:OnServer(function(Player : Player, ActionId : number, DirectionId : number)
		if not Allow(Player) then
			return
		end
		local Character = Player.Character
		local C = Character and CombatService.Combatants[Character]
		if not C then
			return
		end
		local Gate = Gated[ActionId]
		if Gate and not C.Status:Can(Gate) then
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
		HitService.Claim(Player, NetId, Target)
	end)
end

return IntentService

--!strict
-- Server entry: players → combatants, intents → CombatService, hit claims → validation, dummies.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatEnums = require(ReplicatedStorage.Combat.CombatEnums)
local Config = require(ReplicatedStorage.Combat.CombatConfig)
local CombatNet = require(ReplicatedStorage.Combat.Net)
local Service = require(script.Parent.CombatService)
local Dummies = require(script.Parent.Dummies)

local WEAPON = "LinkedSword" -- later: the equipped weapon from the player's saved profile

---------------------------------------------------------------- players

local function OnCharacter(Player : Player, Character : Model)
	Service.Register(Character, Player, WEAPON)
end

local function OnPlayer(Player : Player)
	Player.CharacterAdded:Connect(function(Character)
		OnCharacter(Player, Character)
	end)
	if Player.Character then
		task.spawn(OnCharacter, Player, Player.Character)
	end
end

Players.PlayerAdded:Connect(OnPlayer)
for _, Player in Players:GetPlayers() do
	task.spawn(OnPlayer, Player)
end

---------------------------------------------------------------- intents (token bucket per player)

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

Players.PlayerRemoving:Connect(function(Player)
	Buckets[Player] = nil
end)

local Actions = CombatEnums.Actions

CombatNet.Intent:OnServer(function(Player : Player, ActionId : number, DirectionId : number)
	if not Allow(Player) then
		return
	end
	local Character = Player.Character
	local C = Character and Service.Combatants[Character]
	if not C then
		return
	end
	local Direction = CombatEnums.DirectionName(DirectionId) -- 0 / unknown → nil
	if ActionId == Actions.Attack then
		Service.StartAttack(C, Direction)
	elseif ActionId == Actions.DefendStart then
		Service.DefendStart(C, Direction)
	elseif ActionId == Actions.DefendEnd then
		Service.DefendEnd(C)
	elseif ActionId == Actions.Dodge then
		Service.Dodge(C, Direction)
	end
end)

CombatNet.HitClaim:OnServer(function(Player : Player, NetId : number, Target : Instance?)
	Service.Claim(Player, NetId, Target)
end)

---------------------------------------------------------------- dummies

Dummies.SpawnAll()

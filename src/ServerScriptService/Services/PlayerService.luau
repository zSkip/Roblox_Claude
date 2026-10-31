--!strict
-- Players' characters → combatants.

local Players = game:GetService("Players")

local PlayerService = { Priority = 50 }

local WEAPON = "LinkedSword" -- later: the equipped weapon from the player's saved profile

local CombatService : any = nil

function PlayerService.Init(_self : any, Get : (string) -> any)
	CombatService = Get("CombatService")
end

local function OnPlayer(Player : Player)
	Player.CharacterAdded:Connect(function(Character)
		CombatService.Register(Character, Player, WEAPON)
	end)
	if Player.Character then
		task.spawn(CombatService.Register, Player.Character, Player, WEAPON)
	end
end

function PlayerService.Start(_self : any)
	Players.PlayerAdded:Connect(OnPlayer)
	for _, Player in Players:GetPlayers() do
		task.spawn(OnPlayer, Player)
	end
end

return PlayerService

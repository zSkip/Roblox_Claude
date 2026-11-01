--!strict
-- Plays your own character's combat animations (they replicate to everyone; the server animates NPCs).
-- Preloads every animation in ReplicatedStorage.Assets.Animations so the first swing never waits on a
-- download, and AnimationPlayer checks each track's real length against the baked manifest.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Combat = ReplicatedStorage.Shared.Combat
local AnimationPlayer = require(Combat.AnimationPlayer)
local Manifest = require(Combat.AnimationManifest)

local AnimationController = { Priority = 30 }

local CombatController : any = nil
local Current : any = nil -- AnimationPlayer for the current character

function AnimationController.Init(_self : any, Get : (string) -> any)
	CombatController = Get("CombatController")
end

local function ManifestIds() : { string }
	local Ids = {}
	for Id in Manifest.ById do
		table.insert(Ids, Id)
	end
	return Ids
end

local function OnCharacter(Model : Model)
	if Current then
		Current:Destroy()
		Current = nil
	end
	local Hum = Model:WaitForChild("Humanoid") :: Humanoid
	local Animator = Hum:WaitForChild("Animator") :: Animator
	if CombatController.Character ~= Model then
		return -- respawned while waiting
	end
	Current = AnimationPlayer.new(Animator)
	Current:Preload(ManifestIds())
end

function AnimationController.Start(_self : any)
	task.spawn(function()
		ContentProvider:PreloadAsync(ReplicatedStorage.Assets.Animations:GetChildren())
	end)
	CombatController.CharacterChanged:Connect(OnCharacter)
	if CombatController.Character then
		task.spawn(OnCharacter, CombatController.Character)
	end
	CombatController.StateChanged:Connect(function(State : string, Direction : string?, Attack : any?, T : any?)
		if Current then
			Current:OnState(CombatController.Weapon().Schema, State, Direction, Attack, T)
		end
	end)
end

return AnimationController

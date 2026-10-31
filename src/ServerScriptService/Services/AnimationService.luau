--!strict
-- Server-side animation: plays NPC combat animations (players animate their own character on the
-- client, so each track replicates once). Frame timing for validation comes from the baked
-- AnimationManifest through Combat/Timeline, never from playing tracks; loading a track still checks
-- its real length against the manifest (AnimationPlayer).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationPlayer = require(ReplicatedStorage.Shared.Combat.AnimationPlayer)

local AnimationService = { Priority = 25 }

local CombatService : any = nil
local Players : { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

function AnimationService.Init(_self : any, Get : (string) -> any)
	CombatService = Get("CombatService")
end

local function PlayerFor(C : any) : any?
	local P = Players[C]
	if P then
		return P
	end
	local Hum = C.Humanoid :: Humanoid
	local Animator = Hum:FindFirstChildOfClass("Animator")
	if not Animator then
		Animator = Instance.new("Animator")
		Animator.Parent = Hum
	end
	P = AnimationPlayer.new(Animator :: Animator)
	Players[C] = P
	C.Runtime.Destroyed:Connect(function()
		P:Destroy()
		Players[C] = nil
	end)
	return P
end

function AnimationService.Start(_self : any)
	CombatService.StateChanged:Connect(function(C : any, State : string, Context : any?)
		if C.Player then
			return
		end
		local P = PlayerFor(C)
		if P then
			P:OnState(C.Schema, State, Context and Context.Direction, Context and Context.Attack, Context and Context.Timeline)
		end
	end)
end

return AnimationService

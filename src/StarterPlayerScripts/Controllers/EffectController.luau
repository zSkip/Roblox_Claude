--!strict
-- Client mirror of every combatant's status effects (status-effect-system §9, frame-timed per
-- replication-and-validation §8): applies S_Effect / S_EffectEnd, expires rows locally by their
-- server-time end frame as a fallback, and answers LockTier / Can so your own MovementController's lock
-- feels instant (the server's WalkCap stays the authority). HudController draws the icons from Changed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Deps = require(ReplicatedStorage.Core.Deps)
local Clock = require(ReplicatedStorage.Core.Clock)
local Combat = ReplicatedStorage.Shared.Combat
local LockProfile = require(Combat.LockProfile)
local CombatNet = require(Combat.CombatNet)
local Effects = require(ReplicatedStorage.Shared.StatusEffects.Effects)

export type Row = { Def : any, Stacks : number, StartFrame : number, EndsFrame : number } -- EndsFrame 0 = until removed

local EffectController = { Priority = 15 }
EffectController.Changed = Deps.Signal.new() -- (Model, Def, Row?) nil row = removed

local Mirror : { [Model]: { [number]: Row } } = {}

function EffectController.Get(Model : Model?) : { [number]: Row }
	return Model and Mirror[Model] or {}
end

-- the strongest lock tier the model's effects force, Free if none
function EffectController.LockTier(Model : Model?) : number
	local Tier = LockProfile.Tiers.Free
	for _, R in EffectController.Get(Model) do
		local Lock = R.Def.Lock
		if Lock and Lock > Tier then
			Tier = Lock
		end
	end
	return Tier
end

function EffectController.Can(Model : Model?, Action : string) : boolean
	for _, R in EffectController.Get(Model) do
		local Blocks = R.Def.Blocks
		if Blocks and Blocks[Action] then
			return false
		end
	end
	return true
end

-- seconds left on a row by the shared clock (math.huge for until-removed)
function EffectController.Remaining(R : Row) : number
	if R.EndsFrame == 0 then
		return math.huge
	end
	return math.max(0, Clock.FrameTime(R.EndsFrame) - Clock.Now())
end

local function Drop(Model : Model, NetId : number)
	local Rows = Mirror[Model]
	local R = Rows and Rows[NetId]
	if not R then
		return
	end
	(Rows :: any)[NetId] = nil
	if next(Rows :: any) == nil then
		Mirror[Model] = nil
	end
	EffectController.Changed:Fire(Model, R.Def, nil)
end

local function OnEffect(Target : Instance?, NetId : number, Stacks : number, StartFrame : number, EndsFrame : number)
	local Def = Effects.FromNetId(NetId)
	if not Def or not Target or not Target:IsA("Model") then
		return
	end
	local Model = Target :: Model
	if EndsFrame ~= 0 and EndsFrame <= Clock.Frame() then
		Drop(Model, NetId) -- arrived after it ended
		return
	end
	local Rows = Mirror[Model]
	if not Rows then
		Rows = {}
		Mirror[Model] = Rows
	end
	local R = { Def = Def, Stacks = Stacks, StartFrame = StartFrame, EndsFrame = EndsFrame }
	(Rows :: any)[NetId] = R
	EffectController.Changed:Fire(Model, Def, R)
end

function EffectController.Start(_self : any)
	CombatNet.Effect:OnClient(OnEffect)
	CombatNet.EffectEnd:OnClient(function(Target : Instance?, NetId : number)
		if Target and Target:IsA("Model") then
			Drop(Target :: Model, NetId)
		end
	end)

	-- local expiry by frame (the server's EffectEnd is the normal path) and cleanup of removed models
	RunService.Heartbeat:Connect(function()
		local Frame = Clock.Frame()
		for Model, Rows in Mirror do
			if not Model.Parent then
				Mirror[Model] = nil
			else
				for NetId, R in Rows do
					if R.EndsFrame ~= 0 and R.EndsFrame <= Frame then
						Drop(Model, NetId)
					end
				end
			end
		end
	end)

	-- listeners are connected: ask for what is already active (late join, respawned controllers)
	CombatNet.EffectSync:Fire()
	Players.LocalPlayer.CharacterAdded:Connect(function()
		CombatNet.EffectSync:Fire()
	end)
end

return EffectController

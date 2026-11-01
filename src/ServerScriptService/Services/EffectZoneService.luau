--!strict
-- Every Part tagged "EffectZone" is a pad: a combatant (player or NPC) that steps onto it gets the pad's
-- effect once; leave and step back on to trigger it again. Pads are real instances you place and edit in
-- Studio (see Tools/BuildArena), and they can be moved, resized or rotated freely. Attributes:
--   Effect         effect id (required)
--   Duration       seconds, default the effect's own
--   Potency        effect strength (Slow)
--   LaunchUp       launches you upward at this speed first
--   DrainPosture   true: empties posture and drops your guard first
--   AddExhaustion  adds this many exhaustion stacks instead of applying Effect directly (the real path:
--                  CombatService's regen tick turns them into the effect)

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Combat = ReplicatedStorage.Shared.Combat
local Exhaustion = require(Combat.Exhaustion)
local Movement = require(Combat.Movement)
local Config = require(Combat.CombatConfig)
local CombatNet = require(Combat.CombatNet)
local Effects = require(ReplicatedStorage.Shared.StatusEffects.Effects)

local EffectZoneService = { Priority = 900 }

local CombatService : any = nil
local EffectService : any = nil

function EffectZoneService.Init(_self : any, Get : (string) -> any)
	CombatService = Get("CombatService")
	EffectService = Get("EffectService")
end

local TAG = "EffectZone"
local TICK = 0.1

local function Launch(C : any, Up : number)
	local Velocity = C.Root.CFrame.LookVector * -20 + Vector3.new(0, Up, 0)
	if C.Player then
		CombatNet.Knockback:FireClient(C.Player, Velocity, 0.3)
	else
		Movement.Knockback(C.Root, Velocity, 0.3)
	end
end

local function ApplyZone(Zone : BasePart, C : any)
	local Id = Zone:GetAttribute("Effect")
	local Def = if type(Id) == "string" then Effects.Get(Id) else nil
	if not Def then
		warn(`[Zones] {Zone:GetFullName()}: unknown Effect {tostring(Id)}`)
		return
	end
	if Def.ForcedMove then
		warn(`[Zones] {Zone:GetFullName()}: {Def.Id} needs a caster; use an NPC with the Caster brain`)
		return
	end
	local Stacks = Zone:GetAttribute("AddExhaustion")
	if type(Stacks) == "number" then
		Exhaustion.Add(C.Exhaustion, Config.Exhaustion, Stacks, os.clock())
		return
	end
	if Zone:GetAttribute("DrainPosture") then
		C.Posture = 0
		C.Holding = false
	end
	local Up = Zone:GetAttribute("LaunchUp")
	if type(Up) == "number" then
		Launch(C, Up)
	end
	EffectService.Apply(C, Def.Id, "Zone", {
		Duration = Zone:GetAttribute("Duration"),
		Potency = Zone:GetAttribute("Potency"),
	})
end

local function Inside(Part : BasePart, Position : Vector3) : boolean
	local Local = Part.CFrame:PointToObjectSpace(Position)
	return math.abs(Local.X) <= Part.Size.X / 2 and math.abs(Local.Z) <= Part.Size.Z / 2 and Local.Y > -1 and Local.Y < 8
end

function EffectZoneService.Start(_self : any)
	local Occupied : { [any]: { [BasePart]: boolean } } = {}
	local Accumulated = 0
	RunService.Heartbeat:Connect(function(Dt)
		Accumulated += Dt
		if Accumulated < TICK then
			return
		end
		Accumulated = 0
		for C in Occupied do
			if not CombatService.Combatants[C.Model] then
				Occupied[C] = nil
			end
		end
		local Zones = CollectionService:GetTagged(TAG)
		for _, C in CombatService.Combatants do
			if not CombatService.Alive(C) then
				continue
			end
			local Was = Occupied[C] or {}
			Occupied[C] = Was
			local Position = C.Root.Position
			for _, Zone in Zones do
				if not Zone:IsA("BasePart") or not Zone:IsDescendantOf(workspace) then
					continue
				end
				local In = Inside(Zone, Position)
				if In and not Was[Zone] then
					if RunService:IsStudio() then
						print(`[Zones] {C.Model.Name} entered {Zone.Name}`)
					end
					ApplyZone(Zone, C)
				end
				Was[Zone] = In or nil
			end
		end
	end)
end

return EffectZoneService

--!strict
-- Studio-only tool: builds the tagged test arena as real instances you can move and edit in Studio.
-- Run from the command bar, then save the place (Workspace is not in git, so this is its source record):
--   require(game.ServerScriptService.Tools.BuildArena).Run()
-- Only creates what is missing by name, so hand edits to existing pads and NPCs are kept.
--
--   workspace.EffectZones  Parts tagged "EffectZone" (EffectZoneService reads their attributes)
--   workspace.NPCs         R6 rigs tagged "NPC" (NpcService reads Brain and the Cast* attributes)

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Combat.CombatConfig)
local Effects = require(ReplicatedStorage.Shared.StatusEffects.Effects)

local BuildArena = {}

local GROUND = 0
local PAD = Vector3.new(6, 0.4, 6)
local ROW_Z = 14
local SPACING = 8

local KindColors = {
	CC = Color3.fromRGB(235, 60, 60),
	Debuff = Color3.fromRGB(240, 150, 40),
	Buff = Color3.fromRGB(60, 170, 255),
}

-- pad attributes; durations are long enough to watch, short enough to walk off
local ZoneAttributes : { [string]: { [string]: any } } = {
	Hitstun = { Duration = 1 },
	Stagger = {},
	GuardBroken = { DrainPosture = true },
	Airborne = { Duration = 0.6, LaunchUp = 45 },
	Root = { Duration = 2 },
	Slow = { Duration = 3, Potency = 0.5 },
	Cripple = { Duration = 3 },
	Disarm = { Duration = 3 },
	Silence = { Duration = 3 },
	Exhausted = { AddExhaustion = Config.Exhaustion.Threshold + 3 },
	FollowUpReady = { Duration = 2 },
	BreakerIFrames = { Duration = 3 },
	DodgeIFrames = { Duration = 3 },
}

local NpcColors = {
	Bag = Color3.fromRGB(163, 162, 165),
	Blocker = Color3.fromRGB(70, 110, 200),
	Parrier = Color3.fromRGB(220, 180, 60),
	Dodger = Color3.fromRGB(80, 200, 200),
	Fighter = Color3.fromRGB(200, 70, 70),
	Charmer = Color3.fromRGB(240, 110, 190),
	Fearmonger = Color3.fromRGB(130, 80, 200),
}

-- Brain picks NpcService's behaviour; the name and colour are only what you see
local Npcs : { { Name : string, Brain : string, Position : Vector3, Attributes : { [string]: any }? } } = {
	{ Name = "Bag", Brain = "Bag", Position = Vector3.new(-20, 3, -22) },
	{ Name = "Blocker", Brain = "Blocker", Position = Vector3.new(-10, 3, -22) },
	{ Name = "Parrier", Brain = "Parrier", Position = Vector3.new(0, 3, -22) },
	{ Name = "Dodger", Brain = "Dodger", Position = Vector3.new(10, 3, -22) },
	{ Name = "Fighter", Brain = "Fighter", Position = Vector3.new(0, 3, 30), Attributes = { AggroRange = 30 } },
	{ Name = "Charmer", Brain = "Caster", Position = Vector3.new(-34, 3, 40), Attributes = {
		CastEffect = "Charmed", CastInterval = 6, CastWindup = 0.8, CastDuration = 2.5, CastRange = 20,
	} },
	{ Name = "Fearmonger", Brain = "Caster", Position = Vector3.new(34, 3, 40), Attributes = {
		CastEffect = "Feared", CastInterval = 6, CastWindup = 0.8, CastDuration = 2, CastRange = 20,
	} },
}

local function Folder(Name : string) : Instance
	local F = workspace:FindFirstChild(Name)
	if not F then
		F = Instance.new("Folder")
		F.Name = Name
		F.Parent = workspace
	end
	return F :: Instance
end

local function Billboard(Parent : Instance, Text : string, Color : Color3, Offset : number, Name : string)
	local Gui = Instance.new("BillboardGui")
	Gui.Name = Name
	Gui.Size = UDim2.fromOffset(120, 36)
	Gui.StudsOffset = Vector3.new(0, Offset, 0)
	Gui.AlwaysOnTop = true
	Gui.MaxDistance = 120
	local L = Instance.new("TextLabel")
	L.BackgroundTransparency = 1
	L.Size = UDim2.fromScale(1, 1)
	L.Font = Enum.Font.GothamBold
	L.TextScaled = true
	L.TextColor3 = Color
	L.TextStrokeTransparency = 0.2
	L.Text = Text
	L.Parent = Gui
	Gui.Parent = Parent
end

local function BuildZone(Def : any, Index : number, Count : number, Parent : Instance)
	local P = Instance.new("Part")
	P.Name = `Zone_{Def.Id}`
	P.Anchored = true
	P.CanCollide = false
	P.CanQuery = false
	P.CanTouch = false
	P.Material = Enum.Material.Neon
	P.Color = KindColors[Def.Kind] or Color3.new(0.5, 0.5, 0.5)
	P.Transparency = 0.25
	P.Size = PAD
	P.Position = Vector3.new((Index - (Count + 1) / 2) * SPACING, GROUND + PAD.Y / 2, ROW_Z)
	P:SetAttribute("Effect", Def.Id)
	for Key, Value in ZoneAttributes[Def.Id] do
		P:SetAttribute(Key, Value)
	end
	Billboard(P, `{Def.Id}\n{Def.Kind}`, P.Color, 3, "ZoneLabel")
	CollectionService:AddTag(P, "EffectZone")
	P.Parent = Parent
end

local function RangeRing(Model : Model, Position : Vector3, Range : number, Color : Color3)
	local Ring = Instance.new("Part")
	Ring.Name = "RangeRing"
	Ring.Shape = Enum.PartType.Cylinder
	Ring.Anchored = true
	Ring.CanCollide = false
	Ring.CanQuery = false
	Ring.CanTouch = false
	Ring.Material = Enum.Material.Neon
	Ring.Color = Color
	Ring.Transparency = 0.85
	Ring.Size = Vector3.new(0.2, Range * 2, Range * 2)
	Ring.CFrame = CFrame.new(Position.X, GROUND + 0.1, Position.Z) * CFrame.Angles(0, 0, math.rad(90))
	Ring.Parent = Model
end

local function BuildNpc(Spec : any, Parent : Instance)
	local Color = NpcColors[Spec.Name] or NpcColors.Bag
	local Desc = Instance.new("HumanoidDescription")
	Desc.HeadColor = Color
	Desc.TorsoColor = Color
	Desc.LeftArmColor = Color
	Desc.RightArmColor = Color
	Desc.LeftLegColor = Color
	Desc.RightLegColor = Color
	local Model = Players:CreateHumanoidModelFromDescription(Desc, Enum.HumanoidRigType.R6)
	Model.Name = `{Spec.Name} Dummy`
	local Hum = Model:FindFirstChildOfClass("Humanoid") :: Humanoid
	Hum.DisplayName = `{Spec.Name} Dummy`
	Hum.MaxHealth = 150
	Hum.Health = 150
	Model:PivotTo(CFrame.lookAt(Spec.Position, Vector3.new(0, Spec.Position.Y, 0)))
	Model:SetAttribute("Brain", Spec.Brain)
	Model:SetAttribute("Weapon", "LinkedSword")
	for Key, Value in Spec.Attributes or {} do
		Model:SetAttribute(Key, Value)
	end
	local Head = Model:FindFirstChild("Head")
	if Head then
		local Text = if Spec.Attributes and Spec.Attributes.CastEffect then `{Spec.Name}\ncasts {Spec.Attributes.CastEffect}` else Spec.Name
		Billboard(Head, Text, Color3.new(1, 1, 1), 2.4, "NpcLabel")
	end
	if Spec.Attributes and Spec.Attributes.CastRange then
		RangeRing(Model, Spec.Position, Spec.Attributes.CastRange, Color)
	end
	CollectionService:AddTag(Model, "NPC")
	Model.Parent = Parent
end

function BuildArena.Run() : string
	local Made = 0
	local Zones = Folder("EffectZones")
	local Pads = {}
	for _, Def in Effects.List do
		if ZoneAttributes[Def.Id] then
			table.insert(Pads, Def)
		end
	end
	for I, Def in Pads do
		if not Zones:FindFirstChild(`Zone_{Def.Id}`) then
			BuildZone(Def, I, #Pads, Zones)
			Made += 1
		end
	end
	local NpcFolder = Folder("NPCs")
	for _, Spec in Npcs do
		if not NpcFolder:FindFirstChild(`{Spec.Name} Dummy`) then
			BuildNpc(Spec, NpcFolder)
			Made += 1
		end
	end
	return `[BuildArena] created {Made} instances`
end

return BuildArena

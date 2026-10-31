--!strict
-- Your character and the server's broadcasts: tracks the local character and its weapon, sends intents,
-- runs the local hitbox for your own attacks (→ hit claims) and fans every broadcast out: Fx / Hud for
-- every combatant, StateChanged (Animation, Movement, Input controllers) for your own character.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Deps = require(ReplicatedStorage.Core.Deps)
local Combat = ReplicatedStorage.Shared.Combat
local WeaponClass = require(Combat.WeaponClass)
local CombatEnums = require(Combat.CombatEnums)
local Movement = require(Combat.Movement)
local CombatNet = require(Combat.CombatNet)
local Resolver = require(Combat.Resolver)
local Timeline = require(Combat.Timeline)

local CombatController = { Priority = 20 }
CombatController.Character = nil :: Model?
CombatController.Root = nil :: BasePart?
CombatController.State = "Idle" -- your character's last broadcast state
CombatController.CharacterChanged = Deps.Signal.new() -- (Model)
CombatController.StateChanged = Deps.Signal.new() -- (State, Direction?, AttackDef?, Timeline?) own character only

local Fx : any = nil
local Hud : any = nil

function CombatController.Init(_self : any, Get : (string) -> any)
	Fx = Get("FxController")
	Hud = Get("HudController")
	WeaponClass.LoadAll()
end

function CombatController.Weapon() : any
	local Character = CombatController.Character
	local Id = Character and Character:GetAttribute("Weapon") :: string?
	return WeaponClass.Get(Id) or WeaponClass.Get("LinkedSword")
end

function CombatController.Send(Action : string, Direction : string?)
	CombatNet.Intent:Fire(CombatEnums.Actions[Action], CombatEnums.DirectionId(Direction))
end

---------------------------------------------------------------- own attacks: local hitbox → claims

local Box = Deps.Hitbox.new()
local CurrentNetId : number? = nil

Box.Hit:Connect(function(Model : Model)
	if CurrentNetId then
		CombatNet.HitClaim:Fire(CurrentNetId, Model)
	end
end)

local function RunOwnAttack(NetId : number, Attack : any, T : any)
	local Character, Root = CombatController.Character, CombatController.Root
	if not Attack.Spec.Hitbox or not Character or not Root then
		return
	end
	CurrentNetId = NetId
	task.delay(T.Startup, function()
		if CurrentNetId == NetId then
			Box:Start(Root, Attack.Spec.Hitbox, { Character })
		end
	end)
	task.delay(T.Startup + T.Active, function()
		if CurrentNetId == NetId then
			Box:Stop()
			CurrentNetId = nil
		end
	end)
end

---------------------------------------------------------------- broadcasts

local function OnAction(Actor : Instance?, StateId : number, DirectionId : number, NetId : number, AttackId : string)
	if not Actor or not Actor:IsA("Model") then
		return
	end
	local State = CombatEnums.StateNames[StateId]
	if not State then
		return
	end
	local Direction = CombatEnums.DirectionName(DirectionId)
	local IsLocal = Actor == CombatController.Character
	Fx.OnState(Actor, State, Direction, AttackId, IsLocal)
	if not IsLocal then
		return
	end

	local Attack, T = nil, nil
	if State == "Attacking" then
		local Def = CombatController.Weapon()
		Attack = Def.Registry:Get(AttackId)
		if Attack then
			T = Timeline.ForAttack(Def.Schema, Attack.Spec, Actor:GetAttribute("AttackSpeed") :: number?)
			RunOwnAttack(NetId, Attack, T)
		end
	else
		CurrentNetId = nil
		Box:Stop()
	end
	if State == "Dodging" and CombatController.Root then
		local Defense = CombatController.Weapon().Schema.Defense
		local Root = CombatController.Root :: BasePart
		Movement.Dash(Root, Movement.DirectionVector(Root, Direction), Defense.DodgeSpeed, Defense.DodgeDuration)
	end
	CombatController.State = State
	CombatController.StateChanged:Fire(State, Direction, Attack, T)
end

local function OnCharacter(Model : Model)
	local Root = Model:WaitForChild("HumanoidRootPart") :: BasePart
	CombatController.Character = Model
	CombatController.Root = Root
	CombatController.State = "Idle"
	CurrentNetId = nil
	Box:Stop()
	CombatController.CharacterChanged:Fire(Model)
end

function CombatController.Start(_self : any)
	local Player = Players.LocalPlayer
	Player.CharacterAdded:Connect(OnCharacter)
	if Player.Character then
		task.spawn(OnCharacter, Player.Character)
	end

	CombatNet.Action:OnClient(OnAction)

	CombatNet.Result:OnClient(function(Attacker : Instance?, Defender : Instance?, OutcomeId : number, Damage : number)
		local Outcome = Resolver.Outcomes[OutcomeId]
		if Outcome and Defender and Defender:IsA("Model") then
			Fx.OnResult(Attacker :: Model?, Defender, Outcome, Damage)
		end
	end)

	CombatNet.Limb:OnClient(function(Target : Instance?, LimbId : number, Fill : number)
		local Group = CombatEnums.LimbNames[LimbId]
		if Group and Target and Target:IsA("Model") then
			Fx.SetLimb(Target, Group, Fill / 255)
		end
	end)

	CombatNet.LimbBurst:OnClient(function(Target : Instance?, LimbId : number)
		local Group = CombatEnums.LimbNames[LimbId]
		if Group and Target and Target:IsA("Model") then
			Fx.LimbBurst(Target, Group)
		end
	end)

	CombatNet.Meters:OnClient(function(Posture : number, Stacks : number)
		Hud.SetMeters(Posture, Stacks)
	end)

	CombatNet.Knockback:OnClient(function(Velocity : Vector3, Duration : number)
		if CombatController.Root then
			Movement.Knockback(CombatController.Root, Velocity, Duration)
		end
	end)
end

return CombatController

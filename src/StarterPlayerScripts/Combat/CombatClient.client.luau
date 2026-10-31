--!strict
-- Client entry: input → intents, local hit queries → claims, and feedback for every combatant.
-- The shared modules know nothing about input or visuals; this script connects them (G1).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Deps = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Deps"))
local Combat = ReplicatedStorage:WaitForChild("Combat")
local WeaponClass = require(Combat:WaitForChild("WeaponClass"))
local CombatEnums = require(Combat:WaitForChild("CombatEnums"))
local Movement = require(Combat:WaitForChild("Movement"))
local CombatNet = require(Combat:WaitForChild("Net"))
local Resolver = require(Combat:WaitForChild("Resolver"))
for _, Module in Combat:WaitForChild("Weapons"):GetChildren() do
	if Module:IsA("ModuleScript") then
		(require :: any)(Module)
	end
end

local Fx = require(script.Parent:WaitForChild("Fx"))
local Hud = require(script.Parent:WaitForChild("Hud"))

local Player = Players.LocalPlayer
local Character : Model? = nil
local Root : BasePart? = nil

Hud.Mount()

local function OnCharacter(Model : Model)
	Character = Model
	Root = Model:WaitForChild("HumanoidRootPart") :: BasePart
end
Player.CharacterAdded:Connect(OnCharacter)
if Player.Character then
	task.spawn(OnCharacter, Player.Character)
end

local function Weapon() : any
	local Id = Character and Character:GetAttribute("Weapon") :: string?
	return WeaponClass.Get(Id) or WeaponClass.Get("LinkedSword")
end

---------------------------------------------------------------- input

-- latest W/A/S/D tap; consumed by the next M1 / F / Q inside DirectionalWindow
local Buffered : string? = nil
local BufferedAt = -math.huge

local function ConsumeDirection() : string?
	local Window = Weapon().Schema.Timings.DirectionalWindow
	local Dir = Buffered
	Buffered = nil
	if Dir and os.clock() - BufferedAt <= Window then
		return Dir
	end
	return nil
end

-- built around shift-lock: without it, face the camera's yaw when an action starts
local function SnapToCamera()
	local Camera = workspace.CurrentCamera
	if not Root or not Camera or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		return
	end
	local Look = Camera.CFrame.LookVector * Vector3.new(1, 0, 1)
	if Look.Magnitude > 1e-3 then
		Root.CFrame = CFrame.lookAt(Root.Position, Root.Position + Look.Unit)
	end
end

local function Send(Action : string, Direction : string?)
	CombatNet.Intent:Fire(CombatEnums.Actions[Action], CombatEnums.DirectionId(Direction))
end

UserInputService.InputBegan:Connect(function(Input : InputObject, Processed : boolean)
	if Processed or not Character then
		return
	end
	local Keys = Weapon().Schema.Keybinds
	local Dir = Keys.Directions[Input.KeyCode]
	if Dir then
		Buffered, BufferedAt = Dir, os.clock()
		return
	end
	if Input.UserInputType == Keys.Attack then
		SnapToCamera()
		Send("Attack", ConsumeDirection())
	elseif Input.KeyCode == Keys.Defend then
		SnapToCamera()
		Send("DefendStart", ConsumeDirection())
	elseif Input.KeyCode == Keys.Dodge then
		SnapToCamera()
		Send("Dodge", ConsumeDirection())
	end
end)

UserInputService.InputEnded:Connect(function(Input : InputObject)
	if Input.KeyCode == Weapon().Schema.Keybinds.Defend then
		Send("DefendEnd")
	end
end)

---------------------------------------------------------------- own attacks: local hitbox → claims

local Box = Deps.Hitbox.new()
local CurrentNetId : number? = nil

Box.Hit:Connect(function(Model : Model)
	if CurrentNetId then
		CombatNet.HitClaim:Fire(CurrentNetId, Model)
	end
end)

local function RunOwnAttack(NetId : number, AttackId : string)
	local Attack = Weapon().Registry:Get(AttackId)
	if not Attack or not Attack.Spec.Hitbox or not Character or not Root then
		return
	end
	local T = WeaponClass.Timeline(Attack.Spec, Character:GetAttribute("AttackSpeed") :: number?)
	CurrentNetId = NetId
	local Follow, Ignore = Root, { Character }
	task.delay(T.Startup, function()
		if CurrentNetId == NetId then
			Box:Start(Follow, Attack.Spec.Hitbox, Ignore)
		end
	end)
	task.delay(T.Startup + T.Active, function()
		if CurrentNetId == NetId then
			Box:Stop()
			CurrentNetId = nil
		end
	end)
end

---------------------------------------------------------------- server broadcasts

CombatNet.Action:OnClient(function(Actor : Instance?, StateId : number, DirectionId : number, NetId : number, AttackId : string)
	if not Actor or not Actor:IsA("Model") then
		return
	end
	local State = CombatEnums.StateNames[StateId]
	if not State then
		return
	end
	local Direction = CombatEnums.DirectionName(DirectionId)
	local IsLocal = Actor == Character
	Fx.OnState(Actor, State, Direction, AttackId, IsLocal)

	if not IsLocal then
		return
	end
	if State == "Attacking" then
		RunOwnAttack(NetId, AttackId)
	else
		CurrentNetId = nil
		Box:Stop()
	end
	if State == "Dodging" and Root then
		local Defense = Weapon().Schema.Defense
		Movement.Dash(Root, Movement.DirectionVector(Root, Direction), Defense.DodgeSpeed, Defense.DodgeDuration)
	end
end)

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
	if Root then
		Movement.Knockback(Root, Velocity, Duration)
	end
end)

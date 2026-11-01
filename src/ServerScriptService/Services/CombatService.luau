--!strict
-- Server authority over combat state: owns every Combatant, runs intents through the state machine,
-- applies walk caps, and ticks posture / exhaustion / limb regen. Hits live in HitService; stuns,
-- i-frames and the follow-up window are status effects (EffectService), and an action needs both the
-- state machine and C.Status:Can(Action). Players and NPCs go through the same functions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Deps = require(ReplicatedStorage.Core.Deps)
local Combat = ReplicatedStorage.Shared.Combat
local WeaponClass = require(Combat.WeaponClass)
local Combatant = require(Combat.Combatant)
local Exhaustion = require(Combat.Exhaustion)
local Movement = require(Combat.Movement)
local WeaponModel = require(Combat.WeaponModel)
local Timeline = require(Combat.Timeline)
local LockProfile = require(Combat.LockProfile)
local CombatEnums = require(Combat.CombatEnums)
local Config = require(Combat.CombatConfig)
local CombatNet = require(Combat.CombatNet)
local ServerClock = require(ReplicatedStorage.Core.Clock)

local CombatService = { Priority = 20 }
CombatService.Combatants = {} :: { [Model]: any }
CombatService.Registered = Deps.Signal.new() -- (Combatant)
CombatService.StateChanged = Deps.Signal.new() -- (Combatant, NewState, Context)
CombatService.AttackStarted = Deps.Signal.new() -- (Combatant, Attack, Timeline)

local HitService : any = nil
local EffectService : any = nil

function CombatService.Init(_self : any, Get : (string) -> any)
	HitService = Get("HitService")
	EffectService = Get("EffectService")
	WeaponClass.LoadAll()
end

local function Clock() : number
	return os.clock()
end

---------------------------------------------------------------- replication helpers

function CombatService.SendMeters(C : any)
	if not C.Player then
		return
	end
	local Posture = math.clamp(math.floor(C.Posture / C.MaxPosture * 100 + 0.5), 0, 100)
	local Stacks = C.Exhaustion.Stacks
	local Key = Posture * 256 + Stacks
	if C.LastMeters == Key then
		return
	end
	C.LastMeters = Key
	CombatNet.Meters:FireClient(C.Player, Posture, Stacks)
end

-- players get a walk cap their MovementController shapes with the lock curve; NPCs are set directly
function CombatService.ApplyMovement(C : any)
	local Hum = C.Humanoid :: Humanoid
	if Hum.Health <= 0 then
		return
	end
	local Cap = C:WalkSpeed(Config)
	if C.Player then
		C.Model:SetAttribute("WalkCap", Cap)
	elseif not C.Forced then -- EffectService sets the speed while it walks the combatant
		Hum.WalkSpeed = if C.Runtime.Current == "Attacking" then 0 else Cap
	end
	Hum.JumpHeight = if C.Runtime.Current == "Idle" and C.Status:Can("Jump") then Config.BaseJumpHeight else 0
end
local ApplyMovement = CombatService.ApplyMovement

local function SyncExhaustion(C : any)
	local Before = C.ExhaustedLevel
	C:RefreshExhausted(Config, ServerClock.Now())
	if C.ExhaustedLevel ~= Before then
		C.Model:SetAttribute("AttackSpeed", C.Stats:Get("AttackSpeed"))
		C.Model:SetAttribute("Exhausted", C.ExhaustedLevel)
		ApplyMovement(C)
	end
	CombatService.SendMeters(C)
end

local function Broadcast(C : any, State : string, Context : any?)
	local Dir = Context and Context.Direction
	local AttackId = if Context and Context.Attack then Context.Attack.Id else ""
	CombatNet.Action:Fire(C.Model, CombatEnums.States[State], CombatEnums.DirectionId(Dir), C.Runtime.ActionId % 65536, AttackId)
end

---------------------------------------------------------------- state helpers

function CombatService.Alive(C : any) : boolean
	return C.Runtime.Alive and not C:Is("Dead") and (C.Humanoid :: Humanoid).Health > 0
end
local Alive = CombatService.Alive

-- the state machine and every active status effect must allow it
local function CanAct(C : any, Action : string, Now : number) : boolean
	return Alive(C) and C.Runtime:CanStart(Action, Now) and C.Status:Can(Action)
end

-- back to Blocking if the defend key is still held, else Idle (EffectService calls this when the last
-- lock effect ends)
function CombatService.ToNeutral(C : any)
	if not Alive(C) or C.Status:LockTier() >= LockProfile.Tiers.Locked then
		return
	end
	C.Attack = nil
	if C.Holding then
		C.Runtime:SetState("Blocking")
	else
		C.Runtime:SetState("Idle")
	end
end

-- runs Fn after Delay only if no other action started in between (actions only; stuns are effects)
local function After(C : any, Id : number, Delay : number, Fn : () -> ())
	task.delay(Delay, function()
		if C.Runtime.ActionId == Id and Alive(C) then
			Fn()
		end
	end)
end

---------------------------------------------------------------- registration

function CombatService.Register(Model : Model, Player : Player?, WeaponId : string?) : any?
	local Hum = Model:WaitForChild("Humanoid", 10) :: Humanoid?
	local Root = Model:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not Hum or not Root or not Model.Parent then
		return nil
	end
	if Hum.RigType ~= Enum.HumanoidRigType.R6 then
		warn(`[Combat] {Model.Name} is not R6. Set Game Settings > Avatar > Avatar Type to R6.`)
	else
		Model:WaitForChild("Right Arm", 5) -- character parts can arrive after CharacterAdded
	end
	local Def = WeaponClass.Get(WeaponId or "LinkedSword")
	assert(Def, `unknown weapon {tostring(WeaponId)}`)

	local Previous = CombatService.Combatants[Model]
	if Previous then
		Previous:Destroy()
	end

	local C = Combatant.new({
		Model = Model,
		Root = Root,
		Humanoid = Hum,
		Player = Player,
		Definition = Def,
		BaseWalkSpeed = Config.BaseWalkSpeed,
	})
	CombatService.Combatants[Model] = C

	Hum.UseJumpPower = false
	Model:SetAttribute("Weapon", Def.Id)
	Model:SetAttribute("AttackSpeed", C.Stats:Get("AttackSpeed"))
	Model:SetAttribute("Exhausted", 0)
	WeaponModel.Attach(Model, Def.Schema)

	C.Runtime.StateChanged:Connect(function(New : string, _Old : string, Context : any)
		Broadcast(C, New, Context)
		ApplyMovement(C)
		CombatService.StateChanged:Fire(C, New, Context)
	end)
	ApplyMovement(C)
	CombatService.SendMeters(C)

	Hum.Died:Connect(function()
		C.Attack = nil
		C.Runtime:SetState("Dead")
	end)
	Model.AncestryChanged:Connect(function(_, Parent)
		if Parent == nil and CombatService.Combatants[Model] == C then
			CombatService.Combatants[Model] = nil
			C:Destroy()
		end
	end)
	CombatService.Registered:Fire(C)
	return C
end

---------------------------------------------------------------- actions (intents)

function CombatService.StartAttack(C : any, Direction : string?) : boolean
	local Now = Clock()
	if not CanAct(C, "Attack", Now) then
		return false
	end
	local Def = C.Runtime:MatchAttack(Direction, Now, C:MatchState(Now))
	if not Def then
		return false
	end
	if Def.Kind == "FollowUp" then
		C.Status:Remove("FollowUpReady", "Consumed")
	end

	-- exhaustion first, so this swing already uses the new attack speed
	Exhaustion.OnM1(C.Exhaustion, Config.Exhaustion, Now)
	if Def.Spec.Knockback then
		Exhaustion.OnKnockback(C.Exhaustion, Config.Exhaustion, Now)
	end
	SyncExhaustion(C)

	local T = Timeline.ForAttack(C.Schema, Def.Spec, C.Stats:Get("AttackSpeed"))
	local Id = C.Runtime:SetState("Attacking", { Attack = Def, Direction = Direction, Timeline = T })
	local Attack = {
		Def = Def,
		Direction = Direction,
		ActionId = Id,
		NetId = Id % 65536,
		Start = Now,
		ActiveStart = Now + T.Startup,
		ActiveEnd = Now + T.Startup + T.Active,
		Timeline = T,
		StartPosition = C.Root.Position, -- windup travel check (HitService.Claim)
		WalkCap = C:WalkSpeed(Config),
		Hit = {},
	}
	C.Attack = Attack
	CombatService.AttackStarted:Fire(C, Attack, T)
	if not C.Player then
		HitService.RunServerHitbox(C, Attack, T)
	end
	After(C, Id, T.Total, function()
		CombatService.ToNeutral(C)
	end)
	return true
end

function CombatService.DefendStart(C : any, Direction : string?)
	local Now = Clock()
	C.Holding = true
	if not CanAct(C, "Defend", Now) then
		return -- still held: ToNeutral will block once the current action ends
	end
	local Defense = C.Schema.Defense
	if Direction and C.Runtime:CooldownReady("Parry", Now) then
		C.ParryStart = Now
		C.ParryDirection = Direction
		C.Runtime:SetCooldown("Parry", Now + Defense.ParryCooldown)
		local Id = C.Runtime:SetState("Parrying", { Direction = Direction })
		After(C, Id, Defense.ParryWindow, function()
			CombatService.ToNeutral(C)
		end)
	else
		C.Runtime:SetState("Blocking")
	end
end

function CombatService.DefendEnd(C : any)
	C.Holding = false
	if Alive(C) and C:Is("Blocking") then
		C.Runtime:SetState("Idle")
	end
	-- a parry finishes its window, then ToNeutral sees Holding = false and goes Idle
end

function CombatService.Dodge(C : any, Direction : string?)
	local Now = Clock()
	if not CanAct(C, "Dodge", Now) then
		return
	end
	local Dir = Direction or "Back"
	local Defense = C.Schema.Defense
	C.DodgeStart = Now
	C.DodgeDirection = Dir
	C.Runtime:SetCooldown("Dodge", Now + Defense.DodgeCooldown)
	local Id = C.Runtime:SetState("Dodging", { Direction = Dir })
	EffectService.Apply(C, "DodgeIFrames", nil, { Duration = Defense.DodgeIFrames })
	if not C.Player then
		Movement.Dash(C.Root, Movement.DirectionVector(C.Root, Dir), Defense.DodgeSpeed, Defense.DodgeDuration)
	end
	After(C, Id, Defense.DodgeDuration, function()
		CombatService.ToNeutral(C)
	end)
end

---------------------------------------------------------------- periodic: posture regen, exhaustion decay, limb decay

local TICK = 0.1

function CombatService.Start(_self : any)
	local Accumulated = 0
	RunService.Heartbeat:Connect(function(Dt)
		Accumulated += Dt
		if Accumulated < TICK then
			return
		end
		local Step = Accumulated
		Accumulated = 0
		local Now = Clock()
		for _, C in CombatService.Combatants do
			if C.Runtime.Alive then
				local Changed = C:Regen(Now, Step, Config)
				for Group, Fill in Changed do
					local LimbId = CombatEnums.Limbs[Group]
					if LimbId then
						CombatNet.Limb:Fire(C.Model, LimbId, Fill)
					end
				end
				SyncExhaustion(C)
			end
		end
	end)
end

return CombatService

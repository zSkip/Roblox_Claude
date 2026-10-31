--!strict
-- Server authority: owns every Combatant, runs intents through the state machine, validates hit claims,
-- resolves outcomes and applies their effects. Players and NPCs go through the same functions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Deps = require(ReplicatedStorage.Core.Deps)
local Combat = ReplicatedStorage.Combat
local WeaponClass = require(Combat.WeaponClass)
local Combatant = require(Combat.Combatant)
local Resolver = require(Combat.Resolver)
local Exhaustion = require(Combat.Exhaustion)
local Stats = require(Combat.Stats)
local Movement = require(Combat.Movement)
local WeaponModel = require(Combat.WeaponModel)
local CombatEnums = require(Combat.CombatEnums)
local Config = require(Combat.CombatConfig)
local CombatNet = require(Combat.Net)

-- weapons register themselves when required
for _, Module in Combat.Weapons:GetChildren() do
	if Module:IsA("ModuleScript") then
		(require :: any)(Module)
	end
end

local Service = {}
Service.Combatants = {} :: { [Model]: any }
Service.AttackStarted = Deps.Signal.new() -- (Combatant, Attack, Timeline)
Service.Resolved = Deps.Signal.new() -- (Attacker, Defender, Outcome)

-- limb break handlers (plan §8): what a full limb does is decided later; default = burst damage only
Service.BreakHandlers = {
	Default = function(_Defender : any, _Attacker : any, _Group : string) end,
} :: { [string]: (any, any, string) -> () }

local function Clock() : number
	return os.clock()
end

---------------------------------------------------------------- replication helpers

local function SendMeters(C : any)
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

local function ApplyMovement(C : any)
	local Hum = C.Humanoid :: Humanoid
	if Hum.Health <= 0 then
		return
	end
	Hum.WalkSpeed = C:WalkSpeed(Config)
	Hum.JumpHeight = if C.Runtime.Current == "Idle" then Config.BaseJumpHeight else 0
end

local function SyncExhaustion(C : any)
	local Before = C.ExhaustedLevel
	C:RefreshExhausted(Config)
	if C.ExhaustedLevel ~= Before then
		C.Model:SetAttribute("AttackSpeed", C.Stats:Get("AttackSpeed"))
		C.Model:SetAttribute("Exhausted", C.ExhaustedLevel)
		ApplyMovement(C)
	end
	SendMeters(C)
end

local function Broadcast(C : any, State : string, Context : any?)
	local Dir = Context and Context.Direction
	local AttackId = if Context and Context.Attack then Context.Attack.Id else ""
	CombatNet.Action:Fire(C.Model, CombatEnums.States[State], CombatEnums.DirectionId(Dir), C.Runtime.ActionId % 65536, AttackId)
end

---------------------------------------------------------------- state helpers

local function Alive(C : any) : boolean
	return C.Runtime.Alive and not C:Is("Dead") and (C.Humanoid :: Humanoid).Health > 0
end

-- back to Blocking if the defend key is still held, else Idle
function Service.ToNeutral(C : any)
	if not Alive(C) then
		return
	end
	C.Attack = nil
	if C.Holding then
		C.Runtime:SetState("Blocking")
	else
		C.Runtime:SetState("Idle")
	end
end

-- runs Fn after Delay only if no other action started in between
local function After(C : any, Id : number, Delay : number, Fn : () -> ())
	task.delay(Delay, function()
		if C.Runtime.ActionId == Id and Alive(C) then
			Fn()
		end
	end)
end

function Service.Stun(C : any, Duration : number, State : string?, OnEnd : (() -> ())?)
	if not Alive(C) then
		return
	end
	C.Attack = nil
	local Name = State or "Stunned"
	if Name == "Stunned" then
		Duration = Stats.CCDuration(Duration, C.Stats:Get("Tenacity"), "Stun")
	end
	local Id = C.Runtime:SetState(Name)
	After(C, Id, Duration, function()
		if OnEnd then
			OnEnd()
		end
		Service.ToNeutral(C)
	end)
end

---------------------------------------------------------------- registration

function Service.Register(Model : Model, Player : Player?, WeaponId : string?) : any?
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

	local Previous = Service.Combatants[Model]
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
	Service.Combatants[Model] = C

	Hum.UseJumpPower = false
	Model:SetAttribute("Weapon", Def.Id)
	Model:SetAttribute("AttackSpeed", C.Stats:Get("AttackSpeed"))
	Model:SetAttribute("Exhausted", 0)
	WeaponModel.Attach(Model, Def.Schema)

	C.Runtime.StateChanged:Connect(function(New : string, _Old : string, Context : any)
		Broadcast(C, New, Context)
		ApplyMovement(C)
	end)
	ApplyMovement(C)
	SendMeters(C)

	Hum.Died:Connect(function()
		C.Attack = nil
		C.Runtime:SetState("Dead")
	end)
	Model.AncestryChanged:Connect(function(_, Parent)
		if Parent == nil and Service.Combatants[Model] == C then
			Service.Combatants[Model] = nil
			C:Destroy()
		end
	end)
	return C
end

---------------------------------------------------------------- actions (intents)

local function RunServerHitbox(C : any, Attack : any, T : WeaponClass.Timeline)
	local Spec = Attack.Def.Spec
	if not Spec.Hitbox then
		return
	end
	local Box = Deps.Hitbox.new()
	Box.Hit:Connect(function(Model : Model)
		local D = Service.Combatants[Model]
		if D and D ~= C and C.Attack == Attack then
			Service.ResolveHit(C, D, Attack)
		end
	end)
	task.delay(T.Startup, function()
		if C.Attack == Attack then
			Box:Start(C.Root, Spec.Hitbox, { C.Model })
		end
		task.delay(T.Active, function()
			Box:Destroy()
		end)
	end)
end

function Service.StartAttack(C : any, Direction : string?) : boolean
	local Now = Clock()
	if not Alive(C) or not C.Runtime:CanStart("Attack", Now) then
		return false
	end
	local Def = C.Runtime:MatchAttack(Direction, Now, C:MatchState(Now))
	if not Def then
		return false
	end
	if Def.Kind == "FollowUp" then
		C.FollowUpUntil = -math.huge
	end

	-- exhaustion first, so this swing already uses the new attack speed
	Exhaustion.OnM1(C.Exhaustion, Config.Exhaustion, Now)
	if Def.Spec.Knockback then
		Exhaustion.OnKnockback(C.Exhaustion, Config.Exhaustion, Now)
	end
	SyncExhaustion(C)

	local T = WeaponClass.Timeline(Def.Spec, C.Stats:Get("AttackSpeed"))
	local Id = C.Runtime:SetState("Attacking", { Attack = Def, Direction = Direction })
	local Attack = {
		Def = Def,
		Direction = Direction,
		ActionId = Id,
		NetId = Id % 65536,
		Start = Now,
		ActiveStart = Now + T.Startup,
		ActiveEnd = Now + T.Startup + T.Active,
		Hit = {},
	}
	C.Attack = Attack
	Service.AttackStarted:Fire(C, Attack, T)
	if not C.Player then
		RunServerHitbox(C, Attack, T)
	end
	After(C, Id, T.Total, function()
		Service.ToNeutral(C)
	end)
	return true
end

function Service.DefendStart(C : any, Direction : string?)
	local Now = Clock()
	C.Holding = true
	if not Alive(C) or not C.Runtime:CanStart("Defend", Now) then
		return -- still held: ToNeutral will block once the current action ends
	end
	local Defense = C.Schema.Defense
	if Direction and C.Runtime:CooldownReady("Parry", Now) then
		C.ParryStart = Now
		C.ParryDirection = Direction
		C.Runtime:SetCooldown("Parry", Now + Defense.ParryCooldown)
		local Id = C.Runtime:SetState("Parrying", { Direction = Direction })
		After(C, Id, Defense.ParryWindow, function()
			Service.ToNeutral(C)
		end)
	else
		C.Runtime:SetState("Blocking")
	end
end

function Service.DefendEnd(C : any)
	C.Holding = false
	if Alive(C) and C:Is("Blocking") then
		C.Runtime:SetState("Idle")
	end
	-- a parry finishes its window, then ToNeutral sees Holding = false and goes Idle
end

function Service.Dodge(C : any, Direction : string?)
	local Now = Clock()
	if not Alive(C) or not C.Runtime:CanStart("Dodge", Now) then
		return
	end
	local Dir = Direction or "Back"
	local Defense = C.Schema.Defense
	C.DodgeStart = Now
	C.DodgeDirection = Dir
	C.IFramesUntil = math.max(C.IFramesUntil, Now + Defense.DodgeIFrames)
	C.Runtime:SetCooldown("Dodge", Now + Defense.DodgeCooldown)
	local Id = C.Runtime:SetState("Dodging", { Direction = Dir })
	if not C.Player then
		Movement.Dash(C.Root, Movement.DirectionVector(C.Root, Dir), Defense.DodgeSpeed, Defense.DodgeDuration)
	end
	After(C, Id, Defense.DodgeDuration, function()
		Service.ToNeutral(C)
	end)
end

---------------------------------------------------------------- hits

local function ApplyKnockback(A : any, D : any, Spec : any)
	local Velocity = Movement.KnockbackVelocity(A.Root.Position, D.Root.Position, Spec)
	local Duration = Spec.Duration or 0.2
	if D.Player then
		CombatNet.Knockback:FireClient(D.Player, Velocity, Duration) -- the owner moves its own character
	else
		Movement.Knockback(D.Root, Velocity, Duration)
	end
end

local function Damage(D : any, Amount : number)
	if Amount > 0 then
		(D.Humanoid :: Humanoid):TakeDamage(Amount)
	end
end

function Service.ResolveHit(A : any, D : any, Attack : any)
	if Attack.Hit[D.Model] or not Alive(D) then
		return
	end
	Attack.Hit[D.Model] = true
	local Now = Clock()
	local Spec = Attack.Def.Spec

	local Outcome = Resolver.Resolve({
		Direction = Attack.Direction,
		AttackerPosition = A.Root.Position,
		PostureDamage = Spec.PostureDamage or 0,
	}, D:Snapshot(Now), Now, Config.Resolver)

	local Chain = if Outcome == "Hit" then D:RegisterHitTaken(Now, Config.ChainResetTime) else 0
	local Cons = Resolver.Consequences(Outcome, {
		Damage = Spec.Damage,
		PostureDamage = Spec.PostureDamage,
		Hitstun = Spec.Hitstun,
		Knockback = Spec.Knockback,
		Target = Attack.Def.Target,
	}, D.Schema.Defense, Chain)

	local Dealt = 0
	if Cons.Damage > 0 and Spec.Damage then
		Dealt = Stats.FinalDamage(Cons.Damage, Spec.Damage.Type, A.Stats:Snapshot(), D.Stats:Snapshot())
		Damage(D, Dealt)
	end
	if Cons.PostureDamage > 0 then
		D:TakePosture(Cons.PostureDamage, Now)
	end
	Exhaustion.Touch(D.Exhaustion, Config.Exhaustion, Now)
	Exhaustion.Touch(A.Exhaustion, Config.Exhaustion, Now)

	if Outcome == "Hit" then
		if Cons.LimbTarget then
			local Fill, Burst, Cfg = D:AddLimbHit(Cons.LimbTarget, Now)
			local LimbId = CombatEnums.Limbs[Cons.LimbTarget]
			if Fill and LimbId then
				CombatNet.Limb:Fire(D.Model, LimbId, Fill)
				if Burst then
					Damage(D, Cfg.BurstDamage)
					Dealt += Cfg.BurstDamage
					CombatNet.LimbBurst:Fire(D.Model, LimbId)
					local Handler = Service.BreakHandlers[Cfg.OnBreak] or Service.BreakHandlers.Default
					task.spawn(Handler, D, A, Cons.LimbTarget)
				end
			end
		end
		if Alive(D) then
			if Cons.Knockback then
				ApplyKnockback(A, D, Cons.Knockback)
			end
			if Cons.Hitstun > 0 then
				Service.Stun(D, Cons.Hitstun)
			end
		end
	elseif Outcome == "GuardBreak" then
		D.Posture = 0
		D.Holding = false
		Service.Stun(D, Config.GuardBrokenStun, "GuardBroken", function()
			D:RestorePosture()
		end)
	elseif Outcome == "Parried" then
		D:RestorePosture(Config.ParryPostureRefund)
		Service.Stun(A, Config.ParriedStagger)
	elseif Outcome == "PerfectDodge" then
		D.FollowUpUntil = Now + Config.FollowUpWindow
		D.IFramesUntil = math.max(D.IFramesUntil, Now + Config.PerfectDodgeIFrames)
	end

	CombatNet.Result:Fire(A.Model, D.Model, Resolver.OutcomeIds[Outcome], math.clamp(math.floor(Dealt + 0.5), 0, 65535))
	SendMeters(A)
	SendMeters(D)
	Service.Resolved:Fire(A, D, Outcome)
end

local function HitboxReach(Hitbox : any) : number
	local Offset = if Hitbox.Offset then Hitbox.Offset.Position.Magnitude else 0
	return Offset + Hitbox.Size.Magnitude / 2
end

-- client claim → hard checks → resolve. Lag compensation / witnesses come in milestone M5.
function Service.Claim(Player : Player, NetId : number, Target : Instance?)
	local Character = Player.Character
	local A = Character and Service.Combatants[Character]
	if not A or not A.Attack or not Alive(A) then
		return
	end
	local Attack = A.Attack
	if Attack.NetId ~= NetId or not Attack.Def.Spec.Hitbox then
		return
	end
	local Now = Clock()
	if Now < Attack.ActiveStart - Config.ClaimTimeSlack or Now > Attack.ActiveEnd + Config.ClaimTimeSlack then
		return
	end
	if typeof(Target) ~= "Instance" or not (Target :: Instance):IsA("Model") then
		return
	end
	local D = Service.Combatants[Target :: Model]
	if not D or D == A then
		return
	end
	local Reach = HitboxReach(Attack.Def.Spec.Hitbox) + Config.ClaimRangeSlack
	if (D.Root.Position - A.Root.Position).Magnitude > Reach then
		return
	end
	Service.ResolveHit(A, D, Attack)
end

---------------------------------------------------------------- periodic: posture regen, exhaustion decay, limb decay

local Accumulated = 0
local TICK = 0.1
RunService.Heartbeat:Connect(function(Dt)
	Accumulated += Dt
	if Accumulated < TICK then
		return
	end
	local Step = Accumulated
	Accumulated = 0
	local Now = Clock()
	for _, C in Service.Combatants do
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

return Service

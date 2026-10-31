--!strict
-- Hits: server hitboxes for NPC attacks, client hit-claim validation, outcome resolution and its
-- effects (damage, posture, limbs, knockback; stuns go through CombatService).
-- V2: a claim is also rejected when the attacker travelled further during the windup than the
-- LockProfile movement curve allows (anti-slide).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Deps = require(ReplicatedStorage.Core.Deps)
local Combat = ReplicatedStorage.Shared.Combat
local Resolver = require(Combat.Resolver)
local Exhaustion = require(Combat.Exhaustion)
local Stats = require(Combat.Stats)
local Movement = require(Combat.Movement)
local LockProfile = require(Combat.LockProfile)
local CombatEnums = require(Combat.CombatEnums)
local Config = require(Combat.CombatConfig)
local CombatNet = require(Combat.CombatNet)

local HitService = { Priority = 30 }
HitService.Resolved = Deps.Signal.new() -- (Attacker, Defender, Outcome)

-- limb break handlers (plan §8): what a full limb does is decided later; default = burst damage only
HitService.BreakHandlers = {
	Default = function(_Defender : any, _Attacker : any, _Group : string) end,
} :: { [string]: (any, any, string) -> () }

local CombatService : any = nil

function HitService.Init(_self : any, Get : (string) -> any)
	CombatService = Get("CombatService")
end

local function Clock() : number
	return os.clock()
end

---------------------------------------------------------------- server hitboxes (NPC attackers)

function HitService.RunServerHitbox(C : any, Attack : any, T : any)
	local Spec = Attack.Def.Spec
	if not Spec.Hitbox then
		return
	end
	local Box = Deps.Hitbox.new()
	Box.Hit:Connect(function(Model : Model)
		local D = CombatService.Combatants[Model]
		if D and D ~= C and C.Attack == Attack then
			HitService.ResolveHit(C, D, Attack)
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

---------------------------------------------------------------- resolution

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

function HitService.ResolveHit(A : any, D : any, Attack : any)
	if Attack.Hit[D.Model] or not CombatService.Alive(D) then
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
					local Handler = HitService.BreakHandlers[Cfg.OnBreak] or HitService.BreakHandlers.Default
					task.spawn(Handler, D, A, Cons.LimbTarget)
				end
			end
		end
		if CombatService.Alive(D) then
			if Cons.Knockback then
				ApplyKnockback(A, D, Cons.Knockback)
			end
			if Cons.Hitstun > 0 then
				CombatService.Stun(D, Cons.Hitstun)
			end
		end
	elseif Outcome == "GuardBreak" then
		D.Posture = 0
		D.Holding = false
		CombatService.Stun(D, Config.GuardBrokenStun, "GuardBroken", function()
			D:RestorePosture()
		end)
	elseif Outcome == "Parried" then
		D:RestorePosture(Config.ParryPostureRefund)
		CombatService.Stun(A, Config.ParriedStagger)
	elseif Outcome == "PerfectDodge" then
		D.FollowUpUntil = Now + Config.FollowUpWindow
		D.IFramesUntil = math.max(D.IFramesUntil, Now + Config.PerfectDodgeIFrames)
	end

	CombatNet.Result:Fire(A.Model, D.Model, Resolver.OutcomeIds[Outcome], math.clamp(math.floor(Dealt + 0.5), 0, 65535))
	CombatService.SendMeters(A)
	CombatService.SendMeters(D)
	HitService.Resolved:Fire(A, D, Outcome)
end

---------------------------------------------------------------- client claims

local function HitboxReach(Hitbox : any) : number
	local Offset = if Hitbox.Offset then Hitbox.Offset.Position.Magnitude else 0
	return Offset + Hitbox.Size.Magnitude / 2
end

-- the attacker may only have moved as far as the windup's movement curve allows (plus latency slack)
local function Slid(A : any, Attack : any, Now : number) : (boolean, number, number)
	if not Attack.StartPosition or not Attack.Timeline then
		return false, 0, 0
	end
	local Moved = ((A.Root.Position - Attack.StartPosition) * Vector3.new(1, 0, 1)).Magnitude
	local Allowed = LockProfile.MaxTravel(Attack.Timeline, Now - Attack.Start, Attack.WalkCap or 0, Config.Lock) + Config.Lock.SlideSlack
	return Moved > Allowed, Moved, Allowed
end

-- client claim → hard checks → resolve. Lag compensation / witnesses come in milestone M5.
function HitService.Claim(Player : Player, NetId : number, Target : Instance?)
	local Character = Player.Character
	local A = Character and CombatService.Combatants[Character]
	if not A or not A.Attack or not CombatService.Alive(A) then
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
	local D = CombatService.Combatants[Target :: Model]
	if not D or D == A then
		return
	end
	local Reach = HitboxReach(Attack.Def.Spec.Hitbox) + Config.ClaimRangeSlack
	if (D.Root.Position - A.Root.Position).Magnitude > Reach then
		return
	end
	local IsSlide, Moved, Allowed = Slid(A, Attack, Now)
	if IsSlide then
		warn(`[Combat] {Player.Name} moved {string.format("%.1f", Moved)} studs during an attack windup (allowed {string.format("%.1f", Allowed)}); claim rejected`)
		return
	end
	HitService.ResolveHit(A, D, Attack)
end

return HitService

--!strict
-- Server owner of status effects (status-effect-system §8–9): gives every combatant's StatusController its
-- change handler, steps all of them from one Heartbeat on server time, runs the server-only hooks, derives
-- the Stunned / GuardBroken runtime states from lock effects (the effect owns the timing, the state is a
-- name for animation and HUD) and replicates effects as server-time frames.
--
--   EffectService.Apply(C, Id, Source?, Overrides?) -> Instance?     EffectService.Remove(C, Id, Reason?)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Deps = require(ReplicatedStorage.Core.Deps)
local Clock = require(ReplicatedStorage.Core.Clock)
local Combat = ReplicatedStorage.Shared.Combat
local Stats = require(Combat.Stats)
local LockProfile = require(Combat.LockProfile)
local CombatNet = require(Combat.CombatNet)
local Effects = require(ReplicatedStorage.Shared.StatusEffects.Effects)

local EffectService = { Priority = 25 }
EffectService.Changed = Deps.Signal.new() -- (Combatant, StatusController.Event)

local CombatService : any = nil

local Tiers = LockProfile.Tiers

function EffectService.Now() : number
	return Clock.Now()
end

---------------------------------------------------------------- replication

local function EndsFrame(EndsAt : number) : number
	return if EndsAt == math.huge then 0 else Clock.Frame(EndsAt)
end

local function Send(C : any, Def : any, Player : Player?)
	local Entry = C.Status:Entry(Def.Id)
	local Private = Def.Tags.Private
	if Private and not C.Player then
		return -- nobody to tell
	end
	local Target = Player or (if Private then C.Player else nil)
	if Entry then
		local Stacks = math.min(Entry.Stacks, 255)
		if Target then
			CombatNet.Effect:FireClient(Target, C.Model, Def.NetId, Stacks, Clock.Frame(Entry.StartedAt), EndsFrame(Entry.EndsAt))
		else
			CombatNet.Effect:Fire(C.Model, Def.NetId, Stacks, Clock.Frame(Entry.StartedAt), EndsFrame(Entry.EndsAt))
		end
	elseif Target then
		CombatNet.EffectEnd:FireClient(Target, C.Model, Def.NetId)
	else
		CombatNet.EffectEnd:Fire(C.Model, Def.NetId)
	end
end

-- every active effect the player may see, for a client mirror that just started listening
function EffectService.SendSnapshot(Player : Player)
	for _, C in CombatService.Combatants do
		for _, Row in C.Status:Snapshot() do
			local Def = Effects.FromNetId(Row.NetId)
			if Def and (not Def.Tags.Private or C.Player == Player) then
				Send(C, Def, Player)
			end
		end
	end
end

---------------------------------------------------------------- change handling

-- Stunned / GuardBroken while any Locked-or-stronger effect is active, back to neutral when the last ends
local function SyncLockState(C : any)
	if not CombatService.Alive(C) then
		return
	end
	local Current = C.Runtime.Current
	if C.Status:LockTier() >= Tiers.Locked then
		local Name = if C.Status:Get("GuardBroken") then "GuardBroken" else "Stunned"
		if Current ~= Name then
			C.Attack = nil
			C.Runtime:SetState(Name)
		end
	elseif Current == "Stunned" or Current == "GuardBroken" then
		CombatService.ToNeutral(C)
	end
end

local function RunHook(C : any, Hook : ((any) -> ())?, Inst : any)
	if not Hook then
		return
	end
	local Ok, Err = pcall(Hook, { Combatant = C, Instance = Inst, Source = Inst.Source, Now = Clock.Now() })
	if not Ok then
		warn(`[Effects] {Inst.Def.Id} hook failed: {Err}`)
	end
end

local function OnChanged(C : any, Event : any)
	local Def = Event.Instance.Def
	local Hooks = Def.Hooks
	if Hooks then
		RunHook(C, if Event.Kind == "Applied" then Hooks.OnApply elseif Event.Kind == "Removed" then Hooks.OnRemove else nil, Event.Instance)
	end
	Send(C, Def, nil)
	SyncLockState(C)
	CombatService.ApplyMovement(C)
	EffectService.Changed:Fire(C, Event)
end

local function Attach(C : any)
	C.Status.OnChanged = function(Event)
		OnChanged(C, Event)
	end
end

function EffectService.Init(_self : any, Get : (string) -> any)
	CombatService = Get("CombatService")
	-- connected in Init so no combatant registers before its controller has a handler
	CombatService.Registered:Connect(Attach)
	for _, C in CombatService.Combatants do
		Attach(C)
	end
end

---------------------------------------------------------------- API

function EffectService.Apply(C : any, Id : string, Source : any?, Overrides : any?) : any?
	if not CombatService.Alive(C) then
		return nil
	end
	return C.Status:Apply(Id, Source, Clock.Now(), Overrides)
end

function EffectService.Remove(C : any, Id : string, Reason : string?) : boolean
	return C.Status:Remove(Id, Reason)
end

---------------------------------------------------------------- ticking (the first step toward one scheduler)

local function ApplyTick(C : any, Inst : any)
	local Tick = Inst.Def.Tick
	local Hum = C.Humanoid :: Humanoid
	if Tick.Damage and Tick.Damage > 0 and not C.Status:Has("Invulnerable") then
		local Attacker = if type(Inst.Source) == "table" and Inst.Source.Stats then Inst.Source.Stats:Snapshot() else {}
		Hum:TakeDamage(Stats.FinalDamage(Tick.Damage * Inst.Stacks, Tick.DamageType or "True", Attacker, C.Stats:Snapshot()))
	end
	if Tick.Heal and Tick.Heal > 0 and Hum.Health > 0 then
		Hum.Health = math.min(Hum.MaxHealth, Hum.Health + Stats.Heal(Tick.Heal * Inst.Stacks, C.Stats:Get("HealShieldPower")))
	end
	local Hooks = Inst.Def.Hooks
	RunHook(C, Hooks and Hooks.OnTick, Inst)
end

local SyncCooldown : { [Player]: number } = {}

function EffectService.Start(_self : any)
	RunService.Heartbeat:Connect(function()
		local Now = Clock.Now()
		for _, C in CombatService.Combatants do
			for _, Inst in C.Status:Update(Now) do
				ApplyTick(C, Inst)
			end
		end
	end)

	CombatNet.EffectSync:OnServer(function(Player : Player)
		local Now = os.clock()
		if (SyncCooldown[Player] or -math.huge) > Now then
			return
		end
		SyncCooldown[Player] = Now + 1
		EffectService.SendSnapshot(Player)
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(Player)
		SyncCooldown[Player] = nil
	end)
end

return EffectService

--!strict
-- Frozen EffectDef registry (status-effect-system §3–4): Id → def and NetId → def, validated at load.
-- Durations default to CombatConfig values; callers pass the real one as Overrides.Duration at apply
-- time (spec hitstun, weapon i-frames, knockback), so tuning stays where it is today.

local Combat = script.Parent.Parent.Combat
local Stats = require(Combat.Stats)
local LockProfile = require(Combat.LockProfile)
local Config = require(Combat.CombatConfig)
local EffectTags = require(script.Parent.EffectTags)

export type Action = "Move" | "Rotate" | "Jump" | "Attack" | "Defend" | "Dodge" | "Ability"
export type StackMode = "Refresh" | "Extend" | "Independent" | "Intensity" | "Ignore"
export type ModSpec = { Stat : string, Kind : Stats.ModKind, Value : number }
export type ForcedMove = { Mode : "Toward" | "Away", Speed : number, StopAt : number? }

export type EffectDef = {
	Id : string,
	NetId : number, -- U8, stable; never reuse a retired id
	Kind : "Buff" | "Debuff" | "CC",
	Tags : { [string]: true },
	Duration : number, -- seconds; math.huge = until removed
	StackMode : StackMode,
	MaxStacks : number?,
	Blocks : { [string]: true }?,
	Lock : number?, -- LockProfile.Tiers value this effect forces
	Modifiers : { ModSpec }?, -- per stack
	Potency : number?, -- default strength (Slow: share of walk speed removed)
	Tick : { Interval : number, Damage : number?, DamageType : Stats.DamageType?, Heal : number? }?,
	BreaksOnDamage : boolean?,
	MinDuration : number?, -- floor after Tenacity (default CombatConfig.Status.MinCCDuration)
	ForcedMove : ForcedMove?, -- the server walks the target relative to the effect's Source (a combatant)
	Hooks : { OnApply : ((any) -> ())?, OnRemove : ((any) -> ())?, OnTick : ((any) -> ())? }?, -- server only
}

local Effects = {}

Effects.Kinds = table.freeze({ Buff = true, Debuff = true, CC = true })
Effects.StackModes = table.freeze({ Refresh = true, Extend = true, Independent = true, Intensity = true, Ignore = true })

local function Fail(Id : string, Message : string) : never
	error(`[Effects] {Id}: {Message}`, 0)
end

-- errors on the first bad definition (unique Id / NetId, U8 NetId, known kinds, tags, actions, tiers)
function Effects.Validate(List : { EffectDef })
	local TierValues = {}
	for _, V in LockProfile.Tiers do
		TierValues[V] = true
	end
	local Ids, NetIds = {}, {}
	for I, Def in List do
		local Id = if type(Def.Id) == "string" and Def.Id ~= "" then Def.Id else `#{I}`
		if Id == `#{I}` then
			Fail(Id, "needs a string Id")
		end
		if Ids[Id] then
			Fail(Id, "duplicate Id")
		end
		Ids[Id] = true
		local Net = Def.NetId
		if type(Net) ~= "number" or Net % 1 ~= 0 or Net < 1 or Net > 255 then
			Fail(Id, "NetId must be an integer 1-255")
		end
		if NetIds[Net] then
			Fail(Id, `NetId {Net} is already used by {NetIds[Net]}`)
		end
		NetIds[Net] = Id
		if not Effects.Kinds[Def.Kind] then
			Fail(Id, `unknown Kind {tostring(Def.Kind)}`)
		end
		if not Effects.StackModes[Def.StackMode] then
			Fail(Id, `unknown StackMode {tostring(Def.StackMode)}`)
		end
		if Def.StackMode == "Intensity" and type(Def.MaxStacks) ~= "number" then
			Fail(Id, "Intensity needs MaxStacks")
		end
		if type(Def.Duration) ~= "number" or Def.Duration <= 0 then
			Fail(Id, "Duration must be a number > 0")
		end
		if type(Def.Tags) ~= "table" then
			Fail(Id, "Tags must be a table")
		end
		for Tag in Def.Tags do
			if not EffectTags.IsTag[Tag] then
				Fail(Id, `unknown tag {tostring(Tag)}`)
			end
		end
		for Action in Def.Blocks or {} do
			if not EffectTags.IsAction[Action] then
				Fail(Id, `unknown action {tostring(Action)}`)
			end
		end
		if Def.Lock ~= nil and not TierValues[Def.Lock] then
			Fail(Id, "Lock must be a LockProfile.Tiers value")
		end
		for _, Mod in Def.Modifiers or {} do
			if type(Mod.Stat) ~= "string" or type(Mod.Value) ~= "number" then
				Fail(Id, "every modifier needs Stat and Value")
			end
		end
		if Def.Tick and (type(Def.Tick.Interval) ~= "number" or Def.Tick.Interval <= 0) then
			Fail(Id, "Tick.Interval must be a number > 0")
		end
		if Def.ForcedMove then
			local Mode = Def.ForcedMove.Mode
			if Mode ~= "Toward" and Mode ~= "Away" then
				Fail(Id, `unknown ForcedMove.Mode {tostring(Mode)}`)
			end
			if type(Def.ForcedMove.Speed) ~= "number" or Def.ForcedMove.Speed <= 0 then
				Fail(Id, "ForcedMove.Speed must be a number > 0")
			end
		end
	end
end

local Tiers = LockProfile.Tiers
local All = EffectTags.All
local Per = Config.ExhaustedPerLevel

-- the starting set (§4); T = TenacityAffected, C = Cleansable
Effects.List = {
	{ Id = "Hitstun", NetId = 1, Kind = "CC", Tags = { Stun = true, TenacityAffected = true, Cleansable = true },
		Duration = 0.35, StackMode = "Refresh", Blocks = All, Lock = Tiers.Locked },
	{ Id = "Stagger", NetId = 2, Kind = "CC", Tags = { Stun = true, TenacityAffected = true },
		Duration = Config.ParriedStagger, StackMode = "Refresh", Blocks = All, Lock = Tiers.Locked },
	{ Id = "GuardBroken", NetId = 3, Kind = "CC", Tags = { Stun = true },
		Duration = Config.GuardBrokenStun, StackMode = "Ignore", Blocks = All, Lock = Tiers.Locked,
		Hooks = { OnRemove = function(Ctx : any) Ctx.Combatant:RestorePosture() end } },
	{ Id = "Airborne", NetId = 4, Kind = "CC", Tags = { Airborne = true },
		Duration = 0.2, StackMode = "Refresh", Blocks = All, Lock = Tiers.Forced },
	{ Id = "Root", NetId = 5, Kind = "CC", Tags = { Root = true, TenacityAffected = true, Cleansable = true },
		Duration = 1, StackMode = "Refresh", Blocks = { Move = true, Jump = true, Dodge = true }, Lock = Tiers.Rooted },
	{ Id = "Slow", NetId = 6, Kind = "Debuff", Tags = { Slow = true, Cleansable = true },
		Duration = 1, StackMode = "Independent", Potency = 0.3 }, -- WalkSpeed via the strongest-slow rule
	{ Id = "Cripple", NetId = 7, Kind = "Debuff", Tags = { Cripple = true, Cleansable = true },
		Duration = 1, StackMode = "Refresh", Modifiers = { { Stat = "AttackSpeed", Kind = "PercentMult", Value = 0.7 } } },
	{ Id = "Disarm", NetId = 8, Kind = "CC", Tags = { Disarm = true, TenacityAffected = true, Cleansable = true },
		Duration = 1, StackMode = "Refresh", Blocks = { Attack = true } },
	{ Id = "Silence", NetId = 9, Kind = "CC", Tags = { Silence = true, TenacityAffected = true, Cleansable = true },
		Duration = 1, StackMode = "Refresh", Blocks = { Ability = true } },
	{ Id = "Exhausted", NetId = 10, Kind = "Debuff", Tags = { Private = true }, -- driven by SetIntensity
		Duration = math.huge, StackMode = "Intensity", MaxStacks = Config.Exhaustion.MaxIntensity, Modifiers = {
			{ Stat = "AttackSpeed", Kind = "PercentMult", Value = 1 - Per.AttackSpeed },
			{ Stat = "WalkSpeed", Kind = "PercentMult", Value = 1 - Per.WalkSpeed },
			{ Stat = "PostureTaken", Kind = "PercentAdd", Value = Per.PostureTaken },
		} },
	{ Id = "FollowUpReady", NetId = 11, Kind = "Buff", Tags = {},
		Duration = Config.FollowUpWindow, StackMode = "Refresh" },
	{ Id = "BreakerIFrames", NetId = 12, Kind = "Buff", Tags = { Invulnerable = true, Unstoppable = true },
		Duration = 0.4, StackMode = "Ignore" },
	{ Id = "DodgeIFrames", NetId = 13, Kind = "Buff", Tags = { Invulnerable = true },
		Duration = Config.PerfectDodgeIFrames, StackMode = "Refresh" },
	-- these two need a caster: EffectService ends them if the Source dies
	{ Id = "Charmed", NetId = 14, Kind = "CC", Tags = { Charm = true, TenacityAffected = true, Cleansable = true },
		Duration = 2.5, StackMode = "Refresh", Blocks = All, Lock = Tiers.Forced,
		ForcedMove = { Mode = "Toward", Speed = 8, StopAt = 4 } },
	{ Id = "Feared", NetId = 15, Kind = "CC", Tags = { Fear = true, TenacityAffected = true, Cleansable = true },
		Duration = 2, StackMode = "Refresh", Blocks = All, Lock = Tiers.Forced,
		ForcedMove = { Mode = "Away", Speed = 12 } },
} :: { EffectDef }

Effects.Validate(Effects.List)

Effects.ById = {} :: { [string]: EffectDef }
Effects.ByNetId = {} :: { [number]: EffectDef }
for _, Def in Effects.List do
	table.freeze(Def.Tags)
	table.freeze(Def)
	Effects.ById[Def.Id] = Def
	Effects.ByNetId[Def.NetId] = Def
end
table.freeze(Effects.List)
table.freeze(Effects.ById)
table.freeze(Effects.ByNetId)

function Effects.Get(Id : string) : EffectDef?
	return Effects.ById[Id]
end

function Effects.FromNetId(NetId : number) : EffectDef?
	return Effects.ByNetId[NetId]
end

return table.freeze(Effects)

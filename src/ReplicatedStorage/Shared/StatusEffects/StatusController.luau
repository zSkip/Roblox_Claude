--!strict
-- Per-combatant status effects (status-effect-system §5–6). Pure: no Instances and no clock reads; the
-- caller passes Now (server time on the server). Stat changes are StatBlock modifiers with
-- Source = effect Id, so an ending effect restores its stats exactly.
--
--   local S = StatusController.new(StatBlock, OnChanged?)
--   S:Apply(Id, Source?, Now, Overrides?) -> Instance?   S:Remove(Id, Reason?)   S:SetIntensity(Id, Stacks, Now)
--   S:Can(Action)  S:LockTier()  S:Has(Tag)  S:Get(Id)  S:Stacks(Id)  S:Entry(Id)  S:Snapshot()
--   S:Cleanse(Tag?)  S:OnDamaged(Now)  S:Update(Now) -> due ticks  S:Destroy()

local Combat = script.Parent.Parent.Combat
local Stats = require(Combat.Stats)
local LockProfile = require(Combat.LockProfile)
local Config = require(Combat.CombatConfig)
local Effects = require(script.Parent.Effects)

export type Reason = "Expired" | "Cleansed" | "Damage" | "Replaced" | "Consumed" | "Intensity" | "SourceLost"
export type Overrides = { Duration : number?, Stacks : number?, Modifiers : { Effects.ModSpec }?, Potency : number? }

export type Instance = {
	Key : string, -- the Id, or "<Id>#<n>" for Independent effects
	Def : Effects.EffectDef,
	Stacks : number,
	StartedAt : number,
	EndsAt : number,
	Source : any,
	Potency : number?,
	Modifiers : { Effects.ModSpec }?,
	NextTick : number?,
}

export type Event = { Kind : "Applied" | "Stacked" | "Removed", Id : string, Instance : Instance, Reason : Reason? }

-- one replicated row per effect: Independent instances are summed (clients only need icons)
export type Entry = { NetId : number, Stacks : number, StartedAt : number, EndsAt : number }

local StatusController = {}
StatusController.__index = StatusController

function StatusController.new(Block : Stats.StatBlock, OnChanged : ((Event) -> ())?)
	return setmetatable({
		Stats = Block,
		OnChanged = OnChanged,
		Active = {} :: { [string]: Instance },
		Serial = 0,
	}, StatusController)
end

local function Emit(self : any, Event : Event)
	if self.OnChanged then
		self.OnChanged(Event)
	end
end

-- only the strongest slow applies, as one "Slow" WalkSpeed modifier
local function RebuildSlow(self : any)
	local Potencies = {}
	for _, Inst in self.Active do
		if Inst.Def.Tags.Slow then
			table.insert(Potencies, Inst.Potency or Inst.Def.Potency or 0)
		end
	end
	local Strongest = Stats.StrongestSlow(Potencies, self.Stats:Get("SlowResist"))
	if Strongest > 0 then
		self.Stats:AddModifier("Slow", { Stat = "WalkSpeed", Kind = "PercentMult", Value = 1 - Strongest, Source = "Slow" })
	else
		self.Stats:RemoveModifier("Slow")
	end
end

-- rewrites every StatBlock modifier that belongs to one effect: PercentMult compounds per stack,
-- Flat / PercentAdd multiply by the stack count
local function Rebuild(self : any, Def : Effects.EffectDef)
	local Block = self.Stats
	Block:RemoveSource(Def.Id)
	for Key, Inst in self.Active do
		if Inst.Def == Def then
			for I, Mod in Inst.Modifiers or Def.Modifiers or {} do
				local Value = if Mod.Kind == "PercentMult" then Mod.Value ^ Inst.Stacks
					elseif Mod.Kind == "Override" then Mod.Value
					else Mod.Value * Inst.Stacks
				Block:AddModifier(`{Key}:{I}`, { Stat = Mod.Stat, Kind = Mod.Kind, Value = Value, Source = Def.Id })
			end
		end
	end
	if Def.Tags.Slow then
		RebuildSlow(self)
	end
end

function StatusController.Apply(self : any, Id : string, Source : any?, Now : number, Overrides : Overrides?) : Instance?
	local Def = Effects.Get(Id)
	assert(Def, `unknown effect {Id}`)
	local O = Overrides or {}
	if Def.Kind == "CC" and self:Has("Unstoppable") then
		return nil
	end

	local Duration = O.Duration or Def.Duration
	if Def.Tags.TenacityAffected then
		-- Tenacity is read at apply time only; it can't push a CC below the floor (or its own base, if shorter)
		local Floor = math.min(Duration, Def.MinDuration or Config.Status.MinCCDuration)
		Duration = math.max(Floor, Stats.CCDuration(Duration, self.Stats:Get("Tenacity")))
	end

	local Key = Id
	if Def.StackMode == "Independent" then
		self.Serial += 1
		Key = `{Id}#{self.Serial}`
	end

	local Inst = self.Active[Key]
	local Kind : "Applied" | "Stacked" = "Applied"
	if Inst then
		local Mode = Def.StackMode
		if Mode == "Ignore" then
			return Inst
		elseif Mode == "Refresh" then
			Inst.EndsAt = Now + Duration
		elseif Mode == "Extend" then
			Inst.EndsAt += Duration
		elseif Mode == "Intensity" then
			Inst.Stacks = math.min(Def.MaxStacks :: number, Inst.Stacks + (O.Stacks or 1))
			Inst.EndsAt = Now + Duration
		end
		Inst.Source = if Source ~= nil then Source else Inst.Source
		Inst.Potency = O.Potency or Inst.Potency
		Inst.Modifiers = O.Modifiers or Inst.Modifiers
		Kind = "Stacked"
	else
		Inst = {
			Key = Key,
			Def = Def,
			Stacks = math.min(Def.MaxStacks or math.huge, O.Stacks or 1),
			StartedAt = Now,
			EndsAt = Now + Duration,
			Source = Source,
			Potency = O.Potency,
			Modifiers = O.Modifiers,
			NextTick = if Def.Tick then Now + Def.Tick.Interval else nil,
		}
		self.Active[Key] = Inst
	end
	local Applied = Inst :: Instance
	Rebuild(self, Def)
	Emit(self, { Kind = Kind, Id = Id, Instance = Applied })
	return Applied
end

local function Drop(self : any, Key : string, Reason : Reason)
	local Inst = self.Active[Key]
	if not Inst then
		return
	end
	self.Active[Key] = nil
	Rebuild(self, Inst.Def)
	Emit(self, { Kind = "Removed", Id = Inst.Def.Id, Instance = Inst, Reason = Reason })
end

local function DropWhere(self : any, Keep : (Instance) -> boolean, Reason : Reason) : number
	local Keys = {}
	for Key, Inst in self.Active do
		if not Keep(Inst) then
			table.insert(Keys, Key)
		end
	end
	table.sort(Keys)
	for _, Key in Keys do
		Drop(self, Key, Reason)
	end
	return #Keys
end

-- removes every instance of Id (all of them for Independent effects); true if any was active
-- the newest active effect that forces movement, if any
function StatusController.ForcedMove(self : any) : Instance?
	local Newest : Instance? = nil
	for _, Inst in self.Active do
		if Inst.Def.ForcedMove and (not Newest or Inst.StartedAt > Newest.StartedAt) then
			Newest = Inst
		end
	end
	return Newest
end

function StatusController.Remove(self : any, Id : string, Reason : Reason?) : boolean
	return DropWhere(self, function(Inst)
		return Inst.Def.Id ~= Id
	end, Reason or "Replaced") > 0
end

-- meter-driven effects (Exhausted): sets the stack count directly; 0 removes
function StatusController.SetIntensity(self : any, Id : string, Stacks : number, Now : number)
	local Inst = self.Active[Id]
	if Stacks <= 0 then
		self:Remove(Id, "Intensity")
		return
	end
	if not Inst then
		self:Apply(Id, nil, Now, { Stacks = Stacks })
		return
	end
	local Def = Inst.Def
	local New = math.min(Def.MaxStacks or math.huge, Stacks)
	if New == Inst.Stacks then
		return
	end
	Inst.Stacks = New
	Rebuild(self, Def)
	Emit(self, { Kind = "Stacked", Id = Id, Instance = Inst })
end

-- removes every Cleansable effect (optionally only those carrying Tag); returns how many
function StatusController.Cleanse(self : any, Tag : string?) : number
	return DropWhere(self, function(Inst)
		local Tags = Inst.Def.Tags
		return not (Tags.Cleansable and (Tag == nil or Tags[Tag]))
	end, "Cleansed")
end

function StatusController.OnDamaged(self : any, _Now : number)
	DropWhere(self, function(Inst)
		return not Inst.Def.BreaksOnDamage
	end, "Damage")
end

function StatusController.Has(self : any, Tag : string) : boolean
	for _, Inst in self.Active do
		if Inst.Def.Tags[Tag] then
			return true
		end
	end
	return false
end

function StatusController.Get(self : any, Id : string) : Instance?
	local Inst = self.Active[Id]
	if Inst then
		return Inst
	end
	for _, Other in self.Active do
		if Other.Def.Id == Id then
			return Other
		end
	end
	return nil
end

function StatusController.Stacks(self : any, Id : string) : number
	local Total = 0
	for _, Inst in self.Active do
		if Inst.Def.Id == Id then
			Total += Inst.Stacks
		end
	end
	return Total
end

-- false if any active effect blocks Action
function StatusController.Can(self : any, Action : string) : boolean
	for _, Inst in self.Active do
		local Blocks = Inst.Def.Blocks
		if Blocks and Blocks[Action] then
			return false
		end
	end
	return true
end

-- the strongest lock any active effect forces (LockProfile.Tiers), Free if none
function StatusController.LockTier(self : any) : number
	local Tier = LockProfile.Tiers.Free
	for _, Inst in self.Active do
		local Lock = Inst.Def.Lock
		if Lock and Lock > Tier then
			Tier = Lock
		end
	end
	return Tier
end

-- expires effects whose EndsAt has been reached and returns the ticks that came due (the server applies them)
function StatusController.Update(self : any, Now : number) : { Instance }
	local Due = {}
	local Expired = {}
	for Key, Inst in self.Active do
		local Tick = Inst.Def.Tick
		if Tick and Inst.NextTick then
			while Inst.NextTick <= Now and Inst.NextTick <= Inst.EndsAt do
				table.insert(Due, Inst)
				Inst.NextTick += Tick.Interval
			end
		end
		if Inst.EndsAt <= Now then
			table.insert(Expired, Key)
		end
	end
	table.sort(Expired)
	for _, Key in Expired do
		Drop(self, Key, "Expired")
	end
	return Due
end

-- the replicated row for one effect, nil when it isn't active
function StatusController.Entry(self : any, Id : string) : Entry?
	local Out : Entry? = nil
	for _, Inst in self.Active do
		if Inst.Def.Id == Id then
			if Out then
				Out.Stacks += Inst.Stacks
				Out.StartedAt = math.min(Out.StartedAt, Inst.StartedAt)
				Out.EndsAt = math.max(Out.EndsAt, Inst.EndsAt)
			else
				Out = { NetId = Inst.Def.NetId, Stacks = Inst.Stacks, StartedAt = Inst.StartedAt, EndsAt = Inst.EndsAt }
			end
		end
	end
	return Out
end

-- every active effect as replicated rows, sorted by NetId (late joiners)
function StatusController.Snapshot(self : any) : { Entry }
	local Seen, Out = {}, {}
	for _, Inst in self.Active do
		local Id = Inst.Def.Id
		if not Seen[Id] then
			Seen[Id] = true
			table.insert(Out, self:Entry(Id) :: Entry)
		end
	end
	table.sort(Out, function(A, B)
		return A.NetId < B.NetId
	end)
	return Out
end

-- forgets every effect without events or stat changes (the combatant is going away)
function StatusController.Destroy(self : any)
	table.clear(self.Active)
	self.OnChanged = nil
end

return StatusController

--!strict
-- LoL-style stat math (pure) and the StatBlock modifier container.
--
--   value = Override ?? clamp((Base + ΣFlat) × (1 + ΣPercentAdd) × ΠPercentMult, Min, Max)
--
-- StatBlock has no Signal dependency: pass an optional OnChanged(Stat, Value) callback and wire it
-- to a Deps.Signal in the entry script if you need one.

export type ModKind = "Flat" | "PercentAdd" | "PercentMult" | "Override"
export type Modifier = { Stat : string, Kind : ModKind, Value : number, Source : string? }
export type Bounds = { Min : number?, Max : number? }

local Stats = {}

---------------------------------------------------------------- formulas

-- damage multiplier from a resist (armor / MR) after penetration; negative resist amplifies up to 2x
function Stats.ResistMultiplier(Resist : number) : number
	if Resist >= 0 then
		return 100 / (100 + Resist)
	end
	return 2 - 100 / (100 - Resist)
end

-- LoL order: % penetration, then flat penetration (lethality); penetration can't take resist below 0
function Stats.EffectiveResist(Resist : number, PercentPen : number?, FlatPen : number?) : number
	if Resist <= 0 then
		return Resist
	end
	local Value = Resist * (1 - (PercentPen or 0))
	return math.max(0, Value - (FlatPen or 0))
end

export type DamageType = "Physical" | "Magical" | "True"
export type StatReader = { [string]: number }

-- Attacker / Defender are plain stat tables (StatBlock:Snapshot() or any { [Stat]: number })
function Stats.FinalDamage(Raw : number, Type : DamageType, Attacker : StatReader, Defender : StatReader) : number
	if Type == "True" then
		return Raw
	end
	local Physical = Type == "Physical"
	local Resist = (if Physical then Defender.Armor else Defender.MagicResist) or 0
	local PercentPen = if Physical then Attacker.ArmorPenPercent else Attacker.MagicPenPercent
	local FlatPen = if Physical then Attacker.ArmorPenFlat else Attacker.MagicPenFlat
	return Raw * Stats.ResistMultiplier(Stats.EffectiveResist(Resist, PercentPen, FlatPen))
end

-- tenacity sources stack multiplicatively: 1 - Π(1 - t)
function Stats.CombinedTenacity(Sources : { number }) : number
	local Remaining = 1
	for _, T in Sources do
		Remaining *= 1 - math.clamp(T, 0, 1)
	end
	return 1 - Remaining
end

Stats.TenacityExempt = table.freeze({ Airborne = true, Suppression = true, Stasis = true })

function Stats.CCDuration(Base : number, Tenacity : number, CCType : string?) : number
	if CCType and Stats.TenacityExempt[CCType] then
		return Base
	end
	return Base * (1 - math.clamp(Tenacity, 0, 1))
end

-- only the strongest slow applies
function Stats.StrongestSlow(Slows : { number }, SlowResist : number?) : number
	local Strongest = 0
	for _, S in Slows do
		Strongest = math.max(Strongest, S)
	end
	return math.clamp(Strongest * (1 - (SlowResist or 0)), 0, 1)
end

function Stats.Cooldown(Base : number, AbilityHaste : number) : number
	return Base * 100 / (100 + math.max(0, AbilityHaste))
end

Stats.AttackSpeedCap = 2.5

-- action-speed multiplier: base × (1 + bonus), capped; Startup/Recovery are divided by it
function Stats.AttackSpeed(Base : number, BonusPercent : number) : number
	return math.min(Base * (1 + BonusPercent), Stats.AttackSpeedCap)
end

function Stats.Heal(Amount : number, HealShieldPower : number?, GrievousWounds : number?) : number
	return Amount * (1 + (HealShieldPower or 0)) * (1 - math.clamp(GrievousWounds or 0, 0, 1))
end

---------------------------------------------------------------- StatBlock

local StatBlock = {}
StatBlock.__index = StatBlock

export type StatBlock = typeof(setmetatable({} :: {
	Base : { [string]: number },
	Bounds : { [string]: Bounds },
	Mods : { [string]: Modifier },
	Cache : { [string]: number },
	OnChanged : ((Stat : string, Value : number) -> ())?,
}, StatBlock))

function Stats.NewBlock(Base : { [string]: number }, Bounds : { [string]: Bounds }?, OnChanged : ((string, number) -> ())?) : StatBlock
	return setmetatable({
		Base = table.clone(Base),
		Bounds = Bounds or {},
		Mods = {},
		Cache = {},
		OnChanged = OnChanged,
	}, StatBlock)
end

local function Compute(self : StatBlock, Stat : string) : number
	local Flat, Add, Mult = 0, 0, 1
	local Override : number? = nil
	for _, Mod in self.Mods do
		if Mod.Stat == Stat then
			if Mod.Kind == "Flat" then
				Flat += Mod.Value
			elseif Mod.Kind == "PercentAdd" then
				Add += Mod.Value
			elseif Mod.Kind == "PercentMult" then
				Mult *= Mod.Value
			elseif Mod.Kind == "Override" then
				-- the lowest override wins (e.g. WalkSpeed 0 while stunned beats a 5 from a root)
				Override = if Override == nil then Mod.Value else math.min(Override, Mod.Value)
			end
		end
	end
	if Override ~= nil then
		return Override
	end
	local Value = ((self.Base[Stat] or 0) + Flat) * (1 + Add) * Mult
	local B = self.Bounds[Stat]
	if B then
		if B.Min then
			Value = math.max(B.Min, Value)
		end
		if B.Max then
			Value = math.min(B.Max, Value)
		end
	end
	return Value
end

function StatBlock.Get(self : StatBlock, Stat : string) : number
	local Cached = self.Cache[Stat]
	if Cached ~= nil then
		return Cached
	end
	local Value = Compute(self, Stat)
	self.Cache[Stat] = Value
	return Value
end

local function Invalidate(self : StatBlock, Stat : string)
	local Old = self.Cache[Stat]
	self.Cache[Stat] = nil
	if self.OnChanged then
		local New = self:Get(Stat)
		if New ~= Old then
			self.OnChanged(Stat, New)
		end
	end
end

function StatBlock.SetBase(self : StatBlock, Stat : string, Value : number)
	self.Base[Stat] = Value
	Invalidate(self, Stat)
end

-- adding with an existing Id replaces that modifier
function StatBlock.AddModifier(self : StatBlock, Id : string, Mod : Modifier)
	local Previous = self.Mods[Id]
	self.Mods[Id] = Mod
	if Previous and Previous.Stat ~= Mod.Stat then
		Invalidate(self, Previous.Stat)
	end
	Invalidate(self, Mod.Stat)
end

function StatBlock.RemoveModifier(self : StatBlock, Id : string) : boolean
	local Mod = self.Mods[Id]
	if Mod == nil then
		return false
	end
	self.Mods[Id] = nil
	Invalidate(self, Mod.Stat)
	return true
end

-- removes every modifier from one source (a status effect ending); returns how many
function StatBlock.RemoveSource(self : StatBlock, Source : string) : number
	local Ids = {}
	for Id, Mod in self.Mods do
		if Mod.Source == Source then
			table.insert(Ids, Id)
		end
	end
	for _, Id in Ids do
		self:RemoveModifier(Id)
	end
	return #Ids
end

-- plain table of every stat that has a base or a modifier, for Stats.FinalDamage
function StatBlock.Snapshot(self : StatBlock) : { [string]: number }
	local Out = {}
	for Stat in self.Base do
		Out[Stat] = self:Get(Stat)
	end
	for _, Mod in self.Mods do
		Out[Mod.Stat] = self:Get(Mod.Stat)
	end
	return Out
end

return table.freeze(Stats)

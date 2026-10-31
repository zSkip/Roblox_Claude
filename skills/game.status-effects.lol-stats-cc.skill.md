---
name: game.status-effects.lol-stats-cc
description: League of Legends-style stat and status effect system for a Roblox fighting game - stat list and formulas (armor/MR damage reduction, penetration order, tenacity, slow rules, attack speed, ability haste, crit, vamp, heal/shield power, grievous wounds), modifier stacking (flat / percent-additive / multiplicative), crowd-control taxonomy with what each blocks, buff types, effect stacking modes, and Luau class designs (StatBlock, StatusEffect definitions, StatusController) with replication. Use when implementing stats, buffs/debuffs, CC or limb-break effects.
---

# Status Effects & Stats (League of Legends model)

> Source note: built from League of Legends' public mechanics. The user's Trello card ("League of Legends stats") couldn't be fetched from the build environment. Align names and values with that card.

## 1. Stats

| Stat | LoL meaning | Combat-game use |
|---|---|---|
| `MaxHealth`, `HealthRegen` | | Humanoid MaxHealth / regen |
| `AttackDamage` (AD) | scales physical damage | scales `Physical` attacks |
| `AbilityPower` (AP) | scales magic damage | scales `Magical` attacks |
| `Armor` | reduces physical damage | |
| `MagicResist` (MR) | reduces magic damage | |
| `ArmorPenFlat` (Lethality), `ArmorPenPercent` | ignore armor | |
| `MagicPenFlat`, `MagicPenPercent` | ignore MR | |
| `AttackSpeed` | attacks/sec, base × (1 + bonus%), cap 2.5 | animation speed multiplier, scaled Startup/Recovery |
| `AbilityHaste` | cooldown = base × 100 / (100 + haste) | parry/dodge/skill cooldowns |
| `CritChance`, `CritDamage` (175% default) | | optional |
| `LifeSteal`, `Omnivamp` | heal % of damage dealt | |
| `HealShieldPower` | +% heals/shields given | |
| `Tenacity` | reduces CC duration | stun/stagger reduction |
| `SlowResist` | reduces slow strength | |
| `MoveSpeed` | flat + % with soft caps | WalkSpeed |
| `Posture` / `MaxPosture` | (not LoL) block meter | filled by blocked hits, break -> GuardBroken |
| `Stamina` / `MaxStamina` | (like mana/energy) | action costs, exhaustion |

## 2. Formulas

```luau
-- Damage multiplier from a resist (armor or MR) after penetration
local function ResistMultiplier(resist: number): number
	if resist >= 0 then return 100 / (100 + resist) end
	return 2 - 100 / (100 - resist)               -- negative resist amplifies, max 2x
end

-- LoL order: flat reduction -> % reduction -> % penetration -> flat penetration (lethality); pen can't take resist below 0
local function EffectiveResist(resist, pctPen, flatPen)
	local r = resist
	if r > 0 then r *= (1 - pctPen) ; r = math.max(0, r - flatPen) end
	return r
end

local function FinalDamage(raw: number, damageType: "Physical" | "Magical" | "True", attacker, defender): number
	if damageType == "True" then return raw end
	local resist = if damageType == "Physical" then defender.Armor else defender.MagicResist
	local pctPen = if damageType == "Physical" then attacker.ArmorPenPercent else attacker.MagicPenPercent
	local flatPen = if damageType == "Physical" then attacker.ArmorPenFlat else attacker.MagicPenFlat
	return raw * ResistMultiplier(EffectiveResist(resist, pctPen, flatPen))
end
```

- **Tenacity** stacks multiplicatively: `total = 1 - Π(1 - t_i)`. Duration = `base × (1 - total)`. It does **not** affect Airborne (knockups/knockbacks/pulls), Suppression or Stasis.
- **Slows**: only the **strongest** slow applies (they don't stack). Effective slow = `slow × (1 - SlowResist)`.
- **Move speed**: `(base + flat) × (1 + Σ%bonus) × (1 - strongestSlow) × Π(multiplicative)`, then soft caps (LoL: above 415 excess ×0.8, above 490 excess ×0.5, below 220 compressed). For Roblox, scale the caps to WalkSpeed (e.g. base 16, soft cap 22).
- **Cooldowns**: `cd = base × 100 / (100 + AbilityHaste)`.
- **Healing**: `heal × (1 + HealShieldPower) × (1 - GrievousWounds)` (Grievous Wounds 40%, or 60% enhanced).
- **Shields** absorb damage before health; typed shields (physical-only, magic-only) exist.

## 3. Modifier stacking (StatBlock)

| Kind | Combine | Example |
|---|---|---|
| `Flat` | sum | +10 Armor |
| `PercentAdd` | sum, then ×(1 + Σ) | +10% AD and +15% AD -> +25% |
| `PercentMult` | product | ×0.7 move speed from exhaustion |
| `Override` | last/highest wins | set WalkSpeed 0 while stunned |

`value = (base + ΣFlat) × (1 + ΣPercentAdd) × ΠPercentMult`, clamped to the stat's min/max.

```luau
--!strict
export type ModKind = "Flat" | "PercentAdd" | "PercentMult"
export type Modifier = { Stat: string, Kind: ModKind, Value: number, Source: string }

local StatBlock = {} ; StatBlock.__index = StatBlock

function StatBlock.new(base: { [string]: number })
	return setmetatable({ Base = table.clone(base), Mods = {} :: { [string]: Modifier }, Cache = {} :: { [string]: number } }, StatBlock)
end

function StatBlock:AddModifier(id: string, mod: Modifier)
	self.Mods[id] = mod ; self.Cache[mod.Stat] = nil
end

function StatBlock:RemoveModifier(id: string)
	local m = self.Mods[id]
	if m then self.Mods[id] = nil ; self.Cache[m.Stat] = nil end
end

function StatBlock:Get(stat: string): number
	local c = self.Cache[stat] ; if c then return c end
	local flat, add, mult = 0, 0, 1
	for _, m in self.Mods do
		if m.Stat == stat then
			if m.Kind == "Flat" then flat += m.Value elseif m.Kind == "PercentAdd" then add += m.Value else mult *= m.Value end
		end
	end
	local v = ((self.Base[stat] or 0) + flat) * (1 + add) * mult
	self.Cache[stat] = v
	return v
end
```
Fire a `StatChanged(stat, value)` signal (any SignalLike) from Add/Remove so WalkSpeed, UI etc. react (reaction-based).

## 4. Crowd control taxonomy

Flags: what the effect blocks. `T` = reduced by Tenacity, `C` = cleansable.

| CC | Move | Rotate | Attack (M1) | Block/Parry | Dodge | Notes |
|---|---|---|---|---|---|---|
| **Stun** | ✗ | ✗ | ✗ | ✗ | ✗ | T, C. hitstun, GuardBroken, Parried-stagger |
| **Root / Snare** | ✗ | ✓ | ✓ | ✓ | ✗ | T, C |
| **Slow** | reduced | ✓ | ✓ | ✓ | ✓ | strongest only; SlowResist |
| **Cripple** | ✓ | ✓ | slower (attack speed down) | ✓ | ✓ | T |
| **Silence** | ✓ | ✓ | ✓ | ✓ | ✓ | blocks *abilities*; use for "no specials" |
| **Disarm** | ✓ | ✓ | ✗ | ✓ | ✓ | T, C. arm-break candidate |
| **Grounded** | ✓ | ✓ | ✓ | ✓ | ✗ (no dashes) | T, C. leg-break candidate |
| **Blind** | ✓ | ✓ | attacks miss | ✓ | ✓ | T, C. head-break candidate |
| **Nearsight** | ✓ | ✓ | ✓ | ✓ | ✓ | vision radius reduced (screen vignette) |
| **Airborne** (knockup / knockback / pull) | ✗ (forced) | ✗ | ✗ | ✗ | ✗ | **not** T, not C. our Knockback |
| **Suppression** | ✗ | ✗ | ✗ | ✗ | ✗ | not T; grabs |
| **Charm / Taunt / Fear (Flee)** | forced move | ✗ | Taunt forces attacks | ✗ | ✗ | T, C |
| **Sleep / Drowsy** | ✗ | ✗ | ✗ | ✗ | ✗ | breaks on damage (bonus damage on wake) |
| **Polymorph** | slowed | ✓ | ✗ | ✗ | ✗ | silence + disarm + slow |
| **Stasis** (self) | ✗ | ✗ | ✗ | ✗ | ✗ | invulnerable + untargetable |

Buffs: `Haste` (move speed), `Shield`, `Unstoppable` (CC immune, still takes damage), `Invulnerable`, `Untargetable`, `SpellShield` (blocks next effect), `Camouflage/Invisible`, `Regen`, `Empowered` (next attack bonus).

## 5. Effect definition & stacking

```luau
export type StackMode =
	"Refresh"        -- reapply resets duration (most CC)
	| "Extend"        -- adds duration
	| "Independent"   -- each application is its own instance (DoTs from different sources)
	| "Intensity"     -- stacks count up to MaxStacks, duration shared (e.g. Conqueror)
	| "Ignore"        -- reapply does nothing while active

export type EffectDef = {
	Id: string,
	NetId: number,                              -- small integer id for the network
	Kind: "Buff" | "Debuff" | "CC",
	Tags: { [string]: true },                   -- "Stun", "Slow", "Airborne", "Cleansable", "TenacityAffected"
	Duration: number,
	StackMode: StackMode,
	MaxStacks: number?,
	Modifiers: { { Stat: string, Kind: ModKind, Value: number } }?,   -- per stack
	Blocks: { Move: boolean?, Rotate: boolean?, Attack: boolean?, Defend: boolean?, Dodge: boolean? }?,
	Tick: { Interval: number, Damage: number?, DamageType: DamageType? }?,   -- DoT / HoT
	BreaksOnDamage: boolean?,
}
```

## 6. StatusController (per combatant, server authoritative)

```luau
local StatusController = {} ; StatusController.__index = StatusController

function StatusController.new(owner: Model, stats)
	return setmetatable({
		Owner = owner, Stats = stats,
		Active = {} :: { [string]: { Def: any, Stacks: number, EndsAt: number, Source: any } },
		Applied = Deps.Signal.new(), Removed = Deps.Signal.new(),   -- (id, instance)
	}, StatusController)
end

function StatusController:Apply(def, source, now: number)
	if self:Has("Unstoppable") and def.Kind == "CC" then return end
	local duration = def.Duration
	if def.Tags.TenacityAffected then duration *= (1 - self.Stats:Get("Tenacity")) end
	local inst = self.Active[def.Id]
	if inst then
		if def.StackMode == "Refresh" then inst.EndsAt = now + duration
		elseif def.StackMode == "Extend" then inst.EndsAt += duration
		elseif def.StackMode == "Intensity" then inst.Stacks = math.min(inst.Stacks + 1, def.MaxStacks or 1) ; inst.EndsAt = now + duration
		elseif def.StackMode == "Ignore" then return end
		self:_RebuildModifiers(def.Id, inst)
		return
	end
	inst = { Def = def, Stacks = 1, EndsAt = now + duration, Source = source }
	self.Active[def.Id] = inst
	self:_RebuildModifiers(def.Id, inst)
	self.Applied:Fire(def.Id, inst)
end

function StatusController:Remove(id: string)
	local inst = self.Active[id] ; if not inst then return end
	self.Active[id] = nil
	for i in (inst.Def.Modifiers or {}) do self.Stats:RemoveModifier(`{id}:{i}`) end
	self.Removed:Fire(id, inst)
end

function StatusController:_RebuildModifiers(id, inst)
	for i, m in (inst.Def.Modifiers or {}) do
		local value = if m.Kind == "PercentMult" then m.Value ^ inst.Stacks else m.Value * inst.Stacks
		self.Stats:AddModifier(`{id}:{i}`, { Stat = m.Stat, Kind = m.Kind, Value = value, Source = id })
	end
end

function StatusController:SetIntensity(id: string, stacks: number, now: number)   -- for meters that drive a debuff (Exhaustion)
	local def = Effects[id]
	local inst = self.Active[id]
	if not inst then
		inst = { Def = def, Stacks = stacks, EndsAt = math.huge, Source = nil }
		self.Active[id] = inst
		self.Applied:Fire(id, inst)
	else
		inst.Stacks = stacks
	end
	self:_RebuildModifiers(id, inst)
end

function StatusController:Can(action: "Move" | "Rotate" | "Attack" | "Defend" | "Dodge"): boolean
	for _, inst in self.Active do
		local b = inst.Def.Blocks
		if b and b[action] then return false end
	end
	return true
end

function StatusController:Has(tag: string): boolean
	for _, inst in self.Active do if inst.Def.Tags[tag] then return true end end
	return false
end

function StatusController:Update(now: number)              -- one Heartbeat loop for all controllers
	for id, inst in self.Active do if now >= inst.EndsAt then self:Remove(id) end end
end
```
- The slow rule ("strongest slow only") lives in the MoveSpeed computation: collect `Slow` modifiers separately and apply `max`.
- `Can()` gates intents on the server and drives client prediction (client mirrors the replicated effects).

Exhausted definition:
```luau
Effects.Exhausted = {
	Id = "Exhausted", NetId = 20, Kind = "Debuff", Tags = { Exhaustion = true },
	Duration = math.huge, StackMode = "Intensity", MaxStacks = 10,
	Modifiers = {                                   -- applied per intensity level (PercentMult compounds: 0.94^n)
		{ Stat = "AttackSpeed", Kind = "PercentMult", Value = 0.94 },
		{ Stat = "MoveSpeed", Kind = "PercentMult", Value = 0.96 },
		{ Stat = "PostureDamageTaken", Kind = "PercentAdd", Value = 0.08 },
		{ Stat = "RecoveryTime", Kind = "Flat", Value = 0.05 },
	},
}
```

## 7. Replication

```luau
-- Net
EffectApplied = Net.Define("S_Effect", { "Instance", "U8", "U8", "F64" }),  -- target, NetId, stacks, endsAt (server time)
EffectRemoved = Net.Define("S_EffectEnd", { "Instance", "U8" }),
```
Clients keep a mirror for UI icons, movement lock and VFX. The server is the authority for damage/CC.

## 7b. Effects vs the action state machine
Effects overlap, so they are **not** action states. The action chart reads them through guards (`Can("Attack")`, `Has("Invulnerable")`). The controller raises chart events when the first lock-tier effect starts (`Disabled`) and when the last one ends (`Recovered`). See `roblox.architecture.state-machines` §6.4.

## 8. Mapping to this combat system

| Event | Effect |
|---|---|
| Hit by M1 | `Hitstun` (Stun, short, Refresh, T) |
| Parried | `Stagger` (Stun ~0.6s) |
| Guard broken | `GuardBroken` (Stun ~1.2s, posture reset) |
| Knockback finisher | `Airborne` (not T) |
| Exhaustion stacks past threshold | `Exhausted` (Intensity, set via `SetIntensity`, per level: AttackSpeed ×0.94, PostureDamageTaken +8%, MoveSpeed ×0.96; no duration, removed when stacks fall below threshold) |
| Combo breaker | `BreakerIFrames` (Invulnerable 0.4 s, Unstoppable) |
| Perfect dodge | `FollowUpReady` (buff, 0.45 s, enables the follow-up AttackDef) |
| Limb break: arm | `Disarm` side-arm or `Cripple` (see game.combat.limb-damage) |
| Limb break: leg | `Slow` + `Grounded` |
| Limb break: head | `Blind` / `Nearsight` |
| Limb break: torso | `Bleed` (DoT, Independent) + `GrievousWounds` |
| Perfect dodge (optional extra) | `Haste` + `Empowered` (next attack bonus) |

--!strict
-- Limb group registry (game.combat.limb-damage-highlight §2) and pure meter math.
-- Weapon schemas can override any field per group through Schema.Limbs[group].

export type LimbGroup = {
	Parts : { string },
	Max : number,
	PerHit : number,
	BurstDamage : number,
	Decay : number, -- per second, after CombatConfig.LimbDecayDelay without hits
	OnBreak : string,
}

local Limbs = {}

Limbs.Groups = table.freeze({
	["Left Arm"] = table.freeze({ Parts = { "Left Arm" }, Max = 100, PerHit = 25, BurstDamage = 15, Decay = 5, OnBreak = "Default" }),
	["Right Arm"] = table.freeze({ Parts = { "Right Arm" }, Max = 100, PerHit = 25, BurstDamage = 15, Decay = 5, OnBreak = "Default" }),
	Torso = table.freeze({ Parts = { "Torso" }, Max = 120, PerHit = 20, BurstDamage = 20, Decay = 4, OnBreak = "Default" }),
	Legs = table.freeze({ Parts = { "Left Leg", "Right Leg" }, Max = 100, PerHit = 30, BurstDamage = 12, Decay = 5, OnBreak = "Default" }), -- reserved
	Head = table.freeze({ Parts = { "Head" }, Max = 80, PerHit = 25, BurstDamage = 25, Decay = 5, OnBreak = "Default" }), -- reserved
} :: { [string]: LimbGroup })

-- group config merged with a weapon's overrides
function Limbs.Config(Group : string, Overrides : { [string]: any }?) : LimbGroup?
	local Base = Limbs.Groups[Group]
	if not Base then
		return nil
	end
	local Over = Overrides and Overrides[Group]
	if not Over then
		return Base
	end
	local Merged = table.clone(Base) :: any
	for K, V in Over do
		Merged[K] = V
	end
	return Merged
end

-- adds a hit; returns the new meter value and whether it burst (the meter resets to 0 on burst)
function Limbs.AddHit(Value : number, Cfg : LimbGroup) : (number, boolean)
	local New = Value + Cfg.PerHit
	if New >= Cfg.Max then
		return 0, true
	end
	return New, false
end

function Limbs.Decay(Value : number, Cfg : LimbGroup, Dt : number) : number
	return math.max(0, Value - Cfg.Decay * Dt)
end

-- U8 fraction for visuals
function Limbs.Fill(Value : number, Cfg : LimbGroup) : number
	return math.clamp(math.floor(Value / Cfg.Max * 255 + 0.5), 0, 255)
end

return table.freeze(Limbs)

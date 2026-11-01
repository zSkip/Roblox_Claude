--!strict
-- Tag and action names shared by effect definitions, the StatusController gates and the HUD
-- (status-effect-system §3).

local function Set(List : { string }) : { [string]: true }
	local Out = {}
	for _, Name in List do
		Out[Name] = true
	end
	return table.freeze(Out)
end

local EffectTags = {}

-- what Blocks can name; StatusController:Can(Action) answers for these
EffectTags.Actions = table.freeze({ "Move", "Rotate", "Jump", "Attack", "Defend", "Dodge", "Ability" })

EffectTags.Tags = table.freeze({
	"Stun", "Slow", "Root", "Cripple", "Disarm", "Silence", "Airborne", "Grounded", "Charm", "Fear",
	"Cleansable", -- Cleanse removes it
	"TenacityAffected", -- Tenacity shortens it (with the MinCCDuration floor)
	"Invulnerable", -- skips damage (the Resolver treats it as i-frames); does not stop CC
	"Unstoppable", -- rejects CC
	"Private", -- replicated to its owner only
})

EffectTags.IsAction = Set(EffectTags.Actions)
EffectTags.IsTag = Set(EffectTags.Tags)

-- Blocks for effects that stop everything (stuns)
EffectTags.All = EffectTags.IsAction

return table.freeze(EffectTags)

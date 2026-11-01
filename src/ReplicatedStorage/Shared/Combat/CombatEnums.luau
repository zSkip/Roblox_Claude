--!strict
-- Small numeric ids shared by both sides for network traffic (U8 fields).

local function Enumerate(Names : { string }) : ({ string }, { [string]: number })
	local Ids = {}
	for I, Name in Names do
		Ids[Name] = I
	end
	return table.freeze(Names), table.freeze(Ids)
end

local CombatEnums = {}

-- client → server intents
CombatEnums.ActionNames, CombatEnums.Actions = Enumerate({ "Attack", "DefendStart", "DefendEnd", "Dodge" })

-- runtime states (WeaponClass)
CombatEnums.StateNames, CombatEnums.States = Enumerate({
	"Idle", "Attacking", "Blocking", "Parrying", "Dodging", "Stunned", "GuardBroken", "Dead",
})

-- limb groups (Combat/Limbs)
CombatEnums.LimbNames, CombatEnums.Limbs = Enumerate({ "Left Arm", "Right Arm", "Torso", "Legs", "Head" })

-- direction ids: 0 = none, 1..4 = Directions.Names
function CombatEnums.DirectionId(Direction : string?) : number
	if Direction == nil then
		return 0
	end
	return (({ Front = 1, Back = 2, Left = 3, Right = 4 }) :: any)[Direction] or 0
end

function CombatEnums.DirectionName(Id : number) : string?
	return ({ "Front", "Back", "Left", "Right" })[Id]
end

return table.freeze(CombatEnums)

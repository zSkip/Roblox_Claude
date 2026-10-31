--!strict
-- Pure direction helpers shared by input, resolver, limbs and tests. No Instances, no clocks.

export type Direction = "Front" | "Back" | "Left" | "Right"
export type Rule = "Mirrored" | "Same" | "Away"

local Directions = {}

Directions.Ids = table.freeze({ Front = 1, Back = 2, Left = 3, Right = 4 })
Directions.Names = table.freeze({ "Front", "Back", "Left", "Right" } :: { Direction })

-- left/right swap when two fighters face each other
Directions.Mirror = table.freeze({ Front = "Front", Back = "Back", Left = "Right", Right = "Left" } :: { [Direction]: Direction })

Directions.Opposite = table.freeze({ Front = "Back", Back = "Front", Left = "Right", Right = "Left" } :: { [Direction]: Direction })

-- side of `DefenderCFrame` that `AttackerPosition` is on (-Z is forward)
function Directions.IncomingSide(DefenderCFrame : CFrame, AttackerPosition : Vector3) : Direction
	local Relative = DefenderCFrame:PointToObjectSpace(AttackerPosition)
	if math.abs(Relative.X) > math.abs(Relative.Z) then
		return if Relative.X > 0 then "Right" else "Left"
	end
	return if Relative.Z < 0 then "Front" else "Back"
end

-- One matcher for directional parry and counter-dodge ("a tie script-wise").
--   Mirrored : Chosen == side the attack comes from, in the defender's view
--   Same     : Chosen == the attacker's own direction key
--   Away     : Chosen == opposite of the incoming side
function Directions.Matches(Rule : Rule, AttackDirection : Direction?, Incoming : Direction, Chosen : Direction?) : boolean
	if Chosen == nil then
		return false
	end
	if Rule == "Same" then
		return Chosen == AttackDirection
	elseif Rule == "Away" then
		return Chosen == Directions.Opposite[Incoming]
	end
	return Chosen == Incoming
end

-- Which side of the defender a directional swing lands on, assuming the fighters face each other.
function Directions.LandingSide(AttackDirection : Direction) : Direction
	return Directions.Mirror[AttackDirection]
end

return table.freeze(Directions)

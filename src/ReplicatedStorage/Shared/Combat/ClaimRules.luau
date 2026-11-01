--!strict
-- Pure rules for accepting a client's hit claim (HitService.Claim).
-- Timing: the client starts its swing only after the server's Action reaches it, so an honest claim can
-- never arrive before the hit frames. The early side only covers rounding and attack speed changing in
-- flight; the late side covers round-trip latency.
-- Reach: the target must be inside the swing's hitbox plus slack, measured from the attacker's facing on
-- the server, and not behind the attacker.

export type Config = {
	ClaimEarlySlack : number,
	ClaimLateSlack : number,
	ClaimRangeSlack : number,
	ClaimBehindSlack : number,
}

local ClaimRules = {}

function ClaimRules.InWindow(Now : number, ActiveStart : number, ActiveEnd : number, Config : Config) : boolean
	return Now >= ActiveStart - Config.ClaimEarlySlack and Now <= ActiveEnd + Config.ClaimLateSlack
end

-- nil when the target is in reach, otherwise "Behind" or "OutOfRange"
function ClaimRules.Reach(Attacker : CFrame, Hitbox : { Size : Vector3, Offset : CFrame? }, Target : Vector3, Config : Config) : string?
	if Attacker:PointToObjectSpace(Target).Z > Config.ClaimBehindSlack then
		return "Behind" -- +Z is behind a CFrame
	end
	local Box = if Hitbox.Offset then Attacker * Hitbox.Offset else Attacker
	local Local = Box:PointToObjectSpace(Target)
	local Half = Hitbox.Size / 2 + Vector3.one * Config.ClaimRangeSlack
	if math.abs(Local.X) > Half.X or math.abs(Local.Y) > Half.Y or math.abs(Local.Z) > Half.Z then
		return "OutOfRange"
	end
	return nil
end

return table.freeze(ClaimRules)

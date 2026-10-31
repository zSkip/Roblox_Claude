--!strict
-- Combat channels (plan §10). Required identically by the server and the client.

local Net = require(script.Parent.Parent.Core.Deps).Net

return table.freeze({
	-- client → server
	Intent = Net.Define("C_Intent", { "U8", "U8" }), -- Action id, Direction id (0 = none)
	HitClaim = Net.Define("C_HitClaim", { "U16", "Instance" }), -- ActionId, Target model

	-- server → all
	Action = Net.Define("S_Action", { "Instance", "U8", "U8", "U16", "String" }), -- Actor, State id, Direction id, ActionId, AttackId
	Result = Net.Define("S_Result", { "Instance", "Instance", "U8", "U16" }), -- Attacker, Defender, Outcome id, Damage
	Limb = Net.Define("S_Limb", { "Instance", "U8", "U8" }), -- Target, Limb id, Fill 0-255
	LimbBurst = Net.Define("S_LimbBurst", { "Instance", "U8" }),

	-- server → one
	Meters = Net.Define("S_Meters", { "U8", "U8" }), -- Posture %, Exhaustion stacks
	Knockback = Net.Define("S_Knockback", { "Vector3", "F32" }), -- Velocity, Duration
})

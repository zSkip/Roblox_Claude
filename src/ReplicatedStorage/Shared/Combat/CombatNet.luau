--!strict
-- Combat channels (plan §10). Required identically by the server and the client.

local Net = require(game:GetService("ReplicatedStorage").Core.Deps).Net

return table.freeze({
	-- client → server
	Intent = Net.Define("C_Intent", { "U8", "U8" }), -- Action id, Direction id (0 = none)
	HitClaim = Net.Define("C_HitClaim", { "U16", "Instance" }), -- ActionId, Target model
	EffectSync = Net.Define("C_EffectSync", {}), -- the client mirror is listening: send every active effect

	-- server → all
	Action = Net.Define("S_Action", { "Instance", "U8", "U8", "U16", "String" }), -- Actor, State id, Direction id, ActionId, AttackId
	Result = Net.Define("S_Result", { "Instance", "Instance", "U8", "U16" }), -- Attacker, Defender, Outcome id, Damage
	Limb = Net.Define("S_Limb", { "Instance", "U8", "U8" }), -- Target, Limb id, Fill 0-255
	LimbBurst = Net.Define("S_LimbBurst", { "Instance", "U8" }),
	-- status effects, timed on the server-time frame clock (Core/Clock) instead of receipt time. Interim
	-- transport until the Replicator's Effects component (replication-and-validation §8). Frames travel as
	-- F64 because absolute server-time frames don't fit U32.
	Effect = Net.Define("S_Effect", { "Instance", "U8", "U8", "F64", "F64" }), -- Target, NetId, Stacks, StartFrame, EndsFrame (0 = until removed)
	EffectEnd = Net.Define("S_EffectEnd", { "Instance", "U8" }), -- Target, NetId

	-- server → one (and Private effects through Effect)
	Meters = Net.Define("S_Meters", { "U8", "U8" }), -- Posture %, Exhaustion stacks
	Knockback = Net.Define("S_Knockback", { "Vector3", "F32" }), -- Velocity, Duration
})

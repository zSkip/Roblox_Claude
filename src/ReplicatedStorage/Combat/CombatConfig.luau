--!strict
-- Global combat tuning shared by both sides. Weapon-specific numbers live in each weapon schema.

local Exhaustion = require(script.Parent.Exhaustion)
local Resolver = require(script.Parent.Resolver)

return table.freeze({
	Resolver = table.freeze({
		ParryRule = "Mirrored", -- "Mirrored" (attacker D -> press A) or "Same" (attacker D -> press D)
		CounterDodgeRule = "Away",
		ParryWindow = 0.2, -- fallback; weapons override with Defense.ParryWindow
		PerfectDodgeWindow = 0.12,
		ClashEnabled = false,
	} :: Resolver.Config),

	Exhaustion = Exhaustion.DefaultConfig,

	-- each Exhausted intensity level
	ExhaustedPerLevel = table.freeze({
		AttackSpeed = 0.06, -- -6% action speed
		WalkSpeed = 0.04, -- -4% walk speed
		PostureTaken = 0.08, -- +8% posture damage taken
	}),

	BaseWalkSpeed = 16,
	BaseJumpHeight = 7.2,

	-- walk speed multiplier per state (movement lock; jump is disabled outside Idle)
	StateWalk = table.freeze({
		Idle = 1,
		Attacking = 0.35,
		Blocking = 0.5, -- times the weapon's BlockWalkSpeedMultiplier
		Parrying = 0.5,
		Dodging = 1,
		Stunned = 0,
		GuardBroken = 0,
		Dead = 0,
	} :: { [string]: number }),

	ParriedStagger = 0.7, -- attacker stun when parried
	GuardBrokenStun = 1.4,
	ParryPostureRefund = 10,
	PerfectDodgeIFrames = 0.35,
	FollowUpWindow = 0.45,
	ChainResetTime = 1.2, -- consecutive hits within this keep diminishing hitstun

	-- hit-claim validation (server)
	ClaimTimeSlack = 0.35, -- seconds of latency allowed around the active window
	ClaimRangeSlack = 4, -- studs beyond the hitbox reach
	IntentRate = 20, -- intents per second per player

	-- limbs
	LimbDecayDelay = 3,
})

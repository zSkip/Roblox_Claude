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

	-- walk speed cap per state; players' MovementController shapes it with LockProfile (jump only in Idle).
	-- Attacking is 1 because the lock curve does the slowing; NPCs are rooted while attacking.
	StateWalk = table.freeze({
		Idle = 1,
		Attacking = 1,
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

	-- status effects (Shared/StatusEffects)
	Status = table.freeze({
		MinCCDuration = 0.3, -- LoL floor: Tenacity never takes a CC below this (or below its own base, if shorter)
		DefaultCleanseTags = table.freeze({ Cleansable = true }),
	}),

	-- hit-claim validation (server)
	ClaimTimeSlack = 0.35, -- seconds of latency allowed around the active window
	ClaimRangeSlack = 4, -- studs beyond the hitbox reach
	IntentRate = 20, -- intents per second per player

	-- limbs
	LimbDecayDelay = 3,

	-- V2 animations: an attack with an animation takes its frame data from the baked AnimationManifest
	Animation = table.freeze({
		Fps = 60,
		HitFrames = 16, -- without markers, the last 16 frames of an attack animation are the hit; the rest is windup
	}),

	-- V2 attack speed (Timeline, LoL rule): Windup = BaseWindup + (AttackTime × WindupPercent − BaseWindup) × WindupModifier
	WindupModifier = 0.5, -- 1 = windup scales like the swing, 0 = never changes; specs may override
	MaxWindupShare = 0.9, -- the windup never takes more than this share of the attack time

	-- V2 tiered animation lock (LockProfile, MovementController)
	Lock = table.freeze({
		WindupMoveExponent = 1, -- move share over the windup: (1 - t)^k, 1 = linear to stillness
		WindupTurnEnd = 0.35, -- share of TurnRate left on the last windup frame
		ActiveTurn = 0,
		RecoveryTurn = 0.25,
		RecoveryReleaseAt = 0.5, -- movement ramps back over the last half of recovery
		TurnRate = math.rad(720), -- radians per second at Turn = 1
		SlideSlack = 3, -- studs of latency slack in the server's windup travel check
	}),
})

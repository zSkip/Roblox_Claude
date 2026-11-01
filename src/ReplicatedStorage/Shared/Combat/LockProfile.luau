--!strict
-- Tiered animation lock (V2, Trello "Animation Locking"). From a combatant's state, the time since it
-- began and the attack Timeline, says how much the owner may move, turn and jump right now:
--   Free   0  everything                                         Idle
--   Steer  1  movement eases to stillness over the windup,       attack windup, block, parry
--             turning narrows
--   Rooted 2  no movement, limited turning; movement and turning hit frames, recovery, dodges
--             ramp back during recovery, then Free until Idle
--   Locked 3  nothing                                            stun, guard break, death
--   Forced 4  physics / the server drives the root (reserved)    knockback, airborne
-- Pure: the owner client applies a Sample every frame; the server integrates the same curve
-- (MaxTravel) to reject hit claims from attackers who slid during their windup.

export type Sample = { Tier : number, Move : number, Turn : number, Jump : boolean }
export type Config = {
	WindupMoveExponent : number,
	WindupTurnEnd : number,
	ActiveTurn : number,
	RecoveryTurn : number,
	RecoveryReleaseAt : number,
	RecoveryReleaseEnd : number?, -- share of recovery where control is fully back (default 1)
}

local LockProfile = {}

LockProfile.Tiers = table.freeze({ Free = 0, Steer = 1, Rooted = 2, Locked = 3, Forced = 4 })
local Tiers = LockProfile.Tiers

local function Fixed(Tier : number, Move : number, Turn : number, Jump : boolean) : Sample
	return table.freeze({ Tier = Tier, Move = Move, Turn = Turn, Jump = Jump })
end

-- states without a timeline (Move is a share of the server's walk cap, which already slows blocking)
LockProfile.States = table.freeze({
	Idle = Fixed(Tiers.Free, 1, 1, true),
	Blocking = Fixed(Tiers.Steer, 1, 1, false),
	Parrying = Fixed(Tiers.Steer, 1, 1, false),
	Dodging = Fixed(Tiers.Rooted, 1, 0, false), -- the dash mover drives the root
	Stunned = Fixed(Tiers.Locked, 0, 0, false),
	GuardBroken = Fixed(Tiers.Locked, 0, 0, false),
	Dead = Fixed(Tiers.Locked, 0, 0, false),
}) :: { [string]: Sample }

-- what a status effect's lock tier alone allows (Root keeps turning; Locked and Forced stop everything)
LockProfile.TierSamples = table.freeze({
	[Tiers.Free] = Fixed(Tiers.Free, 1, 1, true),
	[Tiers.Steer] = Fixed(Tiers.Steer, 1, 1, false),
	[Tiers.Rooted] = Fixed(Tiers.Rooted, 0, 1, false),
	[Tiers.Locked] = Fixed(Tiers.Locked, 0, 0, false),
	[Tiers.Forced] = Fixed(Tiers.Forced, 0, 0, false),
}) :: { [number]: Sample }

-- merges a state sample with the strongest effect lock: the higher tier, the smaller Move / Turn
function LockProfile.Combine(S : Sample, EffectTier : number) : Sample
	if EffectTier <= Tiers.Free then
		return S
	end
	local E = LockProfile.TierSamples[EffectTier] or LockProfile.TierSamples[Tiers.Locked]
	return {
		Tier = math.max(S.Tier, E.Tier),
		Move = math.min(S.Move, E.Move),
		Turn = math.min(S.Turn, E.Turn),
		Jump = S.Jump and E.Jump,
	}
end

local function ReleaseSpan(Config : Config) : (number, number)
	local At = math.min(Config.RecoveryReleaseAt, 1)
	return At, math.clamp(Config.RecoveryReleaseEnd or 1, At, 1)
end

local function Release(Beta : number, At : number, End : number) : number
	if At >= End then
		return if Beta >= End then 1 else 0
	end
	return math.clamp((Beta - At) / (End - At), 0, 1)
end

function LockProfile.Sample(State : string, Elapsed : number, Timeline : any?, Config : Config) : Sample
	if State ~= "Attacking" or not Timeline then
		return LockProfile.States[State] or LockProfile.States.Idle
	end
	local Windup = Timeline.Startup
	if Elapsed < Windup then
		local Alpha = math.clamp(Elapsed / Windup, 0, 1)
		return {
			Tier = Tiers.Steer,
			Move = (1 - Alpha) ^ Config.WindupMoveExponent,
			Turn = 1 + (Config.WindupTurnEnd - 1) * Alpha,
			Jump = false,
		}
	end
	local RecoveryStart = Windup + Timeline.Active
	if Elapsed < RecoveryStart then
		return { Tier = Tiers.Rooted, Move = 0, Turn = Config.ActiveTurn, Jump = false }
	end
	local Beta = if Timeline.Recovery > 0 then math.clamp((Elapsed - RecoveryStart) / Timeline.Recovery, 0, 1) else 1
	local Move = Release(Beta, ReleaseSpan(Config))
	if Move >= 1 then
		return { Tier = Tiers.Free, Move = 1, Turn = 1, Jump = false } -- the server allows jumps again at Idle
	end
	return { Tier = Tiers.Rooted, Move = Move, Turn = Config.RecoveryTurn + (1 - Config.RecoveryTurn) * Move, Jump = false }
end

-- farthest horizontal distance the curve allows from the attack's start until Elapsed, at walk speed Cap
function LockProfile.MaxTravel(Timeline : any, Elapsed : number, Cap : number, Config : Config) : number
	local K = Config.WindupMoveExponent
	local Windup = Timeline.Startup
	local Distance = 0
	if Windup > 0 then
		-- ∫ (1 - x)^K over the elapsed share of the windup
		local Alpha = math.clamp(Elapsed / Windup, 0, 1)
		Distance += Windup * (1 - (1 - Alpha) ^ (K + 1)) / (K + 1)
	end
	local At, End = ReleaseSpan(Config)
	local Span = Timeline.Recovery * (End - At)
	local RampStart = Windup + Timeline.Active + Timeline.Recovery * At
	if Span > 0 and Elapsed > RampStart then
		local U = math.clamp((Elapsed - RampStart) / Span, 0, 1)
		Distance += Span * U * U / 2
	end
	Distance += math.max(0, Elapsed - (RampStart + Span)) -- full speed for the rest of recovery
	return Distance * Cap
end

return table.freeze(LockProfile)

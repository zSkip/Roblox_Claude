--!strict
-- Pure attack-vs-defense resolution. The server calls it with snapshots taken at the claim's time
-- (after rewind). No Instances, no clocks: the caller passes CFrames, positions and `Now`.
--
--   Resolver.Resolve(Attack, Defender, Now, Config?) -> Outcome
--   Resolver.Consequences(Outcome, Attack, Defense?, ChainHits?) -> Consequences
--
-- Priority order (first match wins):
--   1. i-frames          -> PerfectDodge (dodging, counter direction, inside the perfect window) or Dodged
--   2. parry window      -> Parried if the direction matches Config.ParryRule, else Hit (punished)
--   3. block / held parry, attacker not behind -> GuardBreak if posture runs out, else Blocked
--   4. clash (optional)  -> both attacking in their Active phase
--   5. otherwise         -> Hit

local Directions = require(script.Parent.Directions)

type Direction = Directions.Direction
type Rule = Directions.Rule

export type Outcome = "Hit" | "Blocked" | "Parried" | "Dodged" | "PerfectDodge" | "GuardBreak" | "Clash"

export type DefenderState = "Idle" | "Moving" | "Attacking" | "Blocking" | "Parrying" | "Dodging" | "Stunned" | "GuardBroken" | "Knocked" | string

export type Config = {
	ParryRule : Rule,
	CounterDodgeRule : Rule,
	ParryWindow : number,
	PerfectDodgeWindow : number,
	ClashEnabled : boolean,
}

export type Attack = {
	Direction : Direction?,     -- nil for combo M1s, the buffered key for directional attacks
	AttackerPosition : Vector3,
	PostureDamage : number,
}

export type Defender = {
	CFrame : CFrame,
	State : DefenderState,
	Phase : string?,            -- "Startup" | "Active" | "Recovery" while attacking
	Posture : number,           -- remaining guard; 0 = broken
	PostureDamageTaken : number?, -- multiplier (Exhausted debuff), default 1
	IFramesUntil : number?,
	ParryStart : number?,
	ParryDirection : Direction?,
	DodgeStart : number?,
	DodgeDirection : Direction?,
	ParryWindow : number?,      -- per-weapon override of Config.ParryWindow
	PerfectDodgeWindow : number?,
}

export type DefenseSpec = {
	BlockDamageMultiplier : number?,
}

export type AttackSpec = {
	Damage : { Type : string, Amount : number }?,
	PostureDamage : number?,
	Hitstun : number?,
	Knockback : any?,
	Target : string?,
}

export type Consequences = {
	Damage : number,
	PostureDamage : number,
	Hitstun : number,
	Knockback : any?,
	LimbTarget : string?,
	AttackerStagger : boolean,
	FollowUp : boolean,
	ResetPosture : boolean,
}

local Resolver = {}

Resolver.Outcomes = table.freeze({ "Hit", "Blocked", "Parried", "Dodged", "PerfectDodge", "GuardBreak", "Clash" } :: { Outcome })

Resolver.OutcomeIds = table.freeze({
	Hit = 1, Blocked = 2, Parried = 3, Dodged = 4, PerfectDodge = 5, GuardBreak = 6, Clash = 7,
} :: { [Outcome]: number })

Resolver.DefaultConfig = table.freeze({
	ParryRule = "Mirrored",
	CounterDodgeRule = "Away",
	ParryWindow = 0.2,
	PerfectDodgeWindow = 0.12,
	ClashEnabled = false,
} :: Config)

Resolver.HitstunFalloff = 0.85 -- diminishing hitstun per consecutive hit on the same target

-- Side of the defender the attack lands on.
-- From the front, a directional swing lands mirrored (attacker D -> defender's Left).
-- From a flank or from behind, the geometric side wins.
function Resolver.IncomingSide(DefenderCFrame : CFrame, AttackerPosition : Vector3, AttackDirection : Direction?) : Direction
	local Side = Directions.IncomingSide(DefenderCFrame, AttackerPosition)
	if Side == "Front" and AttackDirection ~= nil then
		return Directions.LandingSide(AttackDirection)
	end
	return Side
end

local function IsBehind(Defender : Defender, AttackerPosition : Vector3) : boolean
	return Directions.IncomingSide(Defender.CFrame, AttackerPosition) == "Back"
end

function Resolver.Resolve(Attack : Attack, Defender : Defender, Now : number, Config : Config?) : Outcome
	local Cfg = Config or Resolver.DefaultConfig
	local Incoming = Resolver.IncomingSide(Defender.CFrame, Attack.AttackerPosition, Attack.Direction)
	local State = Defender.State

	-- 1. i-frames (dodge, combo breaker, perfect-dodge extension)
	if Defender.IFramesUntil ~= nil and Now <= Defender.IFramesUntil then
		if State == "Dodging" and Defender.DodgeStart ~= nil then
			local Window = Defender.PerfectDodgeWindow or Cfg.PerfectDodgeWindow
			if Now - Defender.DodgeStart <= Window
				and Directions.Matches(Cfg.CounterDodgeRule, Attack.Direction, Incoming, Defender.DodgeDirection) then
				return "PerfectDodge"
			end
		end
		return "Dodged"
	end

	-- 2. parry window (only a directional parry sets ParryStart)
	if State == "Parrying" and Defender.ParryStart ~= nil then
		local Window = Defender.ParryWindow or Cfg.ParryWindow
		if Now - Defender.ParryStart <= Window then
			if Directions.Matches(Cfg.ParryRule, Attack.Direction, Incoming, Defender.ParryDirection) then
				return "Parried"
			end
			return "Hit" -- wrong-direction parry is punished
		end
	end

	-- 3. omni block (F held, or a parry held past its window). Everything but the back is covered.
	if (State == "Blocking" or State == "Parrying") and not IsBehind(Defender, Attack.AttackerPosition) then
		local Taken = Attack.PostureDamage * (Defender.PostureDamageTaken or 1)
		if Defender.Posture - Taken <= 0 then
			return "GuardBreak"
		end
		return "Blocked"
	end

	-- 4. clash
	if Cfg.ClashEnabled and State == "Attacking" and Defender.Phase == "Active" then
		return "Clash"
	end

	return "Hit"
end

-- What an outcome does to the defender, from the attack spec. ChainHits = consecutive hits already
-- landed on this target in the current chain (0 for the first), for diminishing hitstun.
function Resolver.Consequences(Outcome : Outcome, Spec : AttackSpec, Defense : DefenseSpec?, ChainHits : number?) : Consequences
	local Damage = if Spec.Damage then Spec.Damage.Amount else 0
	local Posture = Spec.PostureDamage or 0
	local Result : Consequences = {
		Damage = 0,
		PostureDamage = 0,
		Hitstun = 0,
		Knockback = nil,
		LimbTarget = nil,
		AttackerStagger = false,
		FollowUp = false,
		ResetPosture = false,
	}

	if Outcome == "Hit" then
		Result.Damage = Damage
		Result.Hitstun = (Spec.Hitstun or 0) * Resolver.HitstunFalloff ^ (ChainHits or 0)
		Result.Knockback = Spec.Knockback
		Result.LimbTarget = Spec.Target
	elseif Outcome == "Blocked" then
		local Multiplier = if Defense and Defense.BlockDamageMultiplier then Defense.BlockDamageMultiplier else 0
		Result.Damage = Damage * Multiplier
		Result.PostureDamage = Posture
	elseif Outcome == "GuardBreak" then
		Result.PostureDamage = Posture
		Result.ResetPosture = true
	elseif Outcome == "Parried" then
		Result.AttackerStagger = true
	elseif Outcome == "PerfectDodge" then
		Result.FollowUp = true
	end

	return Result
end

return table.freeze(Resolver)

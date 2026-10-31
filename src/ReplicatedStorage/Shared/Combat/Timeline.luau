--!strict
-- Attack frame data (V2). The base phases come from the attack's animation when it has one (baked
-- AnimationManifest: Windup/HitEnd markers, else the last Config.HitFrames frames are the hit), otherwise
-- from the spec's Startup / Active / Recovery. Attack speed then scales them with League of Legends' rule:
--   AttackTime = BaseTime / AttackSpeed
--   Windup     = BaseWindup + (AttackTime × WindupPercent − BaseWindup) × WindupModifier
-- WindupModifier 1 scales the windup like the rest of the swing; below 1 the telegraph shrinks slower, so
-- fast attackers stay readable. The animation plays its windup frames at WindupSpeed, the rest at ActiveSpeed.
--
--   Timeline.ForAttack(Schema, Spec, AttackSpeed) -> Timeline       -- finds the animation's manifest entry
--   Timeline.Compute(Spec, Entry?, AttackSpeed, Config?) -> Timeline -- pure, Entry = manifest entry

local WeaponClass = require(script.Parent.WeaponClass)
local Manifest = require(script.Parent.AnimationManifest)
local CombatConfig = require(script.Parent.CombatConfig)

export type Timeline = {
	Startup : number, -- windup: seconds before the hit frames
	Active : number,
	Recovery : number,
	Total : number,
	WindupSpeed : number, -- animation playback speed during the windup
	ActiveSpeed : number, -- playback speed from the first hit frame on
	AnimationId : string?,
}

export type Entry = { Name : string?, Length : number, Markers : { [string]: number }?, Looped : boolean? }
export type Config = { Fps : number, HitFrames : number, WindupModifier : number, MaxWindupShare : number }

local Timeline = {}

Timeline.DefaultConfig = table.freeze({
	Fps = CombatConfig.Animation.Fps,
	HitFrames = CombatConfig.Animation.HitFrames,
	WindupModifier = CombatConfig.WindupModifier,
	MaxWindupShare = CombatConfig.MaxWindupShare,
}) :: Config

-- base windup, active and recovery at attack speed 1
function Timeline.Base(Spec : { [string]: any }, Entry : Entry?, Config : Config) : (number, number, number)
	if Entry and Entry.Length > 0 then
		local Markers = Entry.Markers or {}
		local HitEnd = math.clamp(Markers.HitEnd or Entry.Length, 0, Entry.Length)
		local WindupEnd = math.clamp(Markers.Windup or (HitEnd - Config.HitFrames / Config.Fps), 0, HitEnd)
		-- frames after HitEnd count as recovery, on top of the spec's own recovery
		return WindupEnd, HitEnd - WindupEnd, (Spec.Recovery or 0) + (Entry.Length - HitEnd)
	end
	return Spec.Startup or 0, Spec.Active or 0, Spec.Recovery or 0
end

function Timeline.Compute(Spec : { [string]: any }, Entry : Entry?, AttackSpeed : number?, Config : Config?) : Timeline
	local Cfg = Config or Timeline.DefaultConfig
	local W, A, R = Timeline.Base(Spec, Entry, Cfg)
	local Speed = math.max(AttackSpeed or 1, 0.05)
	local BaseTime = W + A + R
	local AttackTime = BaseTime / Speed
	local Windup = W
	if BaseTime > 0 then
		local Modifier = Spec.WindupModifier or Cfg.WindupModifier
		Windup = W + (AttackTime * (W / BaseTime) - W) * Modifier
		Windup = math.clamp(Windup, 0, AttackTime * Cfg.MaxWindupShare)
	end
	local Rest = AttackTime - Windup
	local Active = if A + R > 0 then Rest * A / (A + R) else 0
	return {
		Startup = Windup,
		Active = Active,
		Recovery = Rest - Active,
		Total = AttackTime,
		WindupSpeed = if Windup > 0 then W / Windup else 1,
		ActiveSpeed = if Active > 0 then A / Active else 1,
		AnimationId = nil,
	}
end

function Timeline.ForAttack(Schema : { [string]: any }, Spec : { [string]: any }, AttackSpeed : number?) : Timeline
	local Id = WeaponClass.AnimationId(Schema, Spec.Animation)
	local Entry = if Id then Manifest.ById[Id] else nil
	local T = Timeline.Compute(Spec, Entry, AttackSpeed)
	T.AnimationId = Id
	return T
end

return table.freeze(Timeline)

--!strict
-- Combatant: anything that fights (players and NPCs share all resolver, effect and limb code).
-- Holds the authoritative per-owner combat state the server mutates; pure logic + data, so the parts
-- (Root, Humanoid) are passed in and unit tests can use plain tables.
--
--   local C = Combatant.new({ Model, Root, Humanoid, Player?, Definition })
--   C:Snapshot(Now) -> Resolver.Defender     C:TakePosture(Amount, Now) -> broke?
--   C:Regen(Now, Dt)                          C:RefreshExhausted(Config, Now?) -> intensity
-- C.Status (Shared/StatusEffects/StatusController) owns stuns, i-frames, the follow-up window and the
-- Exhausted debuff; EffectService gives it its change handler and steps it on server time.

local Stats = require(script.Parent.Stats)
local Exhaustion = require(script.Parent.Exhaustion)
local Limbs = require(script.Parent.Limbs)
local StatusController = require(script.Parent.Parent.StatusEffects.StatusController)

local Combatant = {}
Combatant.__index = Combatant

export type CurrentAttack = {
	Def : any,
	Direction : string?,
	ActionId : number,
	NetId : number, -- ActionId % 65536, what the client echoes in claims
	Start : number,
	ActiveStart : number,
	ActiveEnd : number,
	Hit : { [any]: boolean },
}

export type Args = {
	Model : any,
	Root : any,
	Humanoid : any,
	Player : any?,
	Definition : any,
	BaseWalkSpeed : number?,
}

function Combatant.new(Args : Args)
	local Schema = Args.Definition.Schema
	local S = Schema.Stats
	local Block = Stats.NewBlock({
		AttackSpeed = S.AttackSpeed or 1,
		WalkSpeed = Args.BaseWalkSpeed or 16,
		Armor = S.Armor or 0,
		MagicResist = S.MagicResist or 0,
		Tenacity = S.Tenacity or 0,
		PostureTaken = 1,
	}, {
		AttackSpeed = { Min = 0.25, Max = Stats.AttackSpeedCap },
		WalkSpeed = { Min = 0 },
	})
	local self = setmetatable({
		Model = Args.Model,
		Root = Args.Root,
		Humanoid = Args.Humanoid,
		Player = Args.Player,
		Definition = Args.Definition,
		Schema = Schema,
		Runtime = Args.Definition:Instantiate(Args.Model),

		Stats = Block,
		Status = StatusController.new(Block),

		MaxPosture = S.MaxPosture,
		Posture = S.MaxPosture,
		PostureHitTime = -math.huge,

		Exhaustion = Exhaustion.New(),
		ExhaustedLevel = 0,

		Attack = nil :: CurrentAttack?,
		Holding = false, -- defend key held
		ParryStart = nil :: number?,
		ParryDirection = nil :: string?,
		DodgeStart = nil :: number?,
		DodgeDirection = nil :: string?,

		ChainHits = 0,
		LastHitTaken = -math.huge,

		LimbMeters = {} :: { [string]: number },
		LimbLastHit = {} :: { [string]: number },
	}, Combatant)
	return self
end

function Combatant.Is(self : any, State : string) : boolean
	return self.Runtime.Current == State
end

-- snapshot for Resolver.Resolve (taken at the claim's time)
function Combatant.Snapshot(self : any, Now : number)
	local Rt = self.Runtime
	local Phase : string? = nil
	if self.Attack then
		Phase = if Now < self.Attack.ActiveStart then "Startup" elseif Now <= self.Attack.ActiveEnd then "Active" else "Recovery"
	end
	local Defense = self.Schema.Defense
	return {
		CFrame = self.Root.CFrame,
		State = Rt.Current,
		Phase = Phase,
		Posture = self.Posture,
		PostureDamageTaken = self.Stats:Get("PostureTaken"),
		IFramesUntil = if self.Status:Has("Invulnerable") then math.huge else nil, -- DodgeIFrames / BreakerIFrames
		ParryStart = if Rt.Current == "Parrying" then self.ParryStart else nil,
		ParryDirection = self.ParryDirection,
		DodgeStart = if Rt.Current == "Dodging" then self.DodgeStart else nil,
		DodgeDirection = self.DodgeDirection,
		ParryWindow = Defense.ParryWindow,
		PerfectDodgeWindow = Defense.PerfectDodgeWindow,
	}
end

-- state used for attack matching: "FollowUp" while the FollowUpReady effect (perfect dodge) is active
function Combatant.MatchState(self : any, _Now : number) : string
	if self.Status:Get("FollowUpReady") then
		return "FollowUp"
	end
	return self.Runtime.Current
end

-- applies posture damage (already scaled by the resolver's multiplier); returns true when it broke
function Combatant.TakePosture(self : any, Amount : number, Now : number) : boolean
	self.PostureHitTime = Now
	self.Posture = math.max(0, self.Posture - Amount * self.Stats:Get("PostureTaken"))
	return self.Posture <= 0
end

function Combatant.RestorePosture(self : any, Amount : number?)
	self.Posture = if Amount then math.min(self.MaxPosture, self.Posture + Amount) else self.MaxPosture
end

-- chained hits for diminishing hitstun; call once per landed hit, returns hits before this one
function Combatant.RegisterHitTaken(self : any, Now : number, ResetTime : number) : number
	if Now - self.LastHitTaken > ResetTime then
		self.ChainHits = 0
	end
	local Before = self.ChainHits
	self.ChainHits += 1
	self.LastHitTaken = Now
	return Before
end

-- returns new limb meter fill (0-255) and whether it burst; nil if the group is unknown
function Combatant.AddLimbHit(self : any, Group : string, Now : number) : (number?, boolean, any)
	local Cfg = Limbs.Config(Group, self.Schema.Limbs)
	if not Cfg then
		return nil, false, nil
	end
	local New, Burst = Limbs.AddHit(self.LimbMeters[Group] or 0, Cfg)
	self.LimbMeters[Group] = New
	self.LimbLastHit[Group] = Now
	return Limbs.Fill(New, Cfg), Burst, Cfg
end

-- periodic regen/decay. Returns a list of limb groups whose fill changed: { [Group]: Fill }
function Combatant.Regen(self : any, Now : number, Dt : number, Config : any) : { [string]: number }
	local S = self.Schema.Stats
	if Now - self.PostureHitTime >= (S.PostureRegenDelay or 1.5) and not self:Is("GuardBroken") then
		self.Posture = math.min(self.MaxPosture, self.Posture + (S.PostureRegen or 10) * Dt)
	end
	Exhaustion.Tick(self.Exhaustion, Config.Exhaustion, Now)

	local Changed = {}
	for Group, Value in self.LimbMeters do
		if Value > 0 and Now - (self.LimbLastHit[Group] or -math.huge) >= Config.LimbDecayDelay then
			local Cfg = Limbs.Config(Group, self.Schema.Limbs)
			if Cfg then
				local Before = Limbs.Fill(Value, Cfg)
				local New = Limbs.Decay(Value, Cfg, Dt)
				self.LimbMeters[Group] = New
				local After = Limbs.Fill(New, Cfg)
				if After ~= Before then
					Changed[Group] = After
				end
			end
		end
	end
	return Changed
end

-- syncs the Exhausted effect's intensity with the current stack count; returns the intensity
function Combatant.RefreshExhausted(self : any, Config : any, Now : number?) : number
	local Level = Exhaustion.Intensity(self.Exhaustion, Config.Exhaustion)
	if Level == self.ExhaustedLevel then
		return Level
	end
	self.ExhaustedLevel = Level
	self.Status:SetIntensity("Exhausted", Level, Now or 0)
	return Level
end

-- walk speed for the current state (server sets Humanoid.WalkSpeed from this)
function Combatant.WalkSpeed(self : any, Config : any) : number
	if not self.Status:Can("Move") then
		return 0
	end
	local State = self.Runtime.Current
	local Mult = Config.StateWalk[State] or 1
	if State == "Blocking" or State == "Parrying" then
		Mult *= self.Schema.Defense.BlockWalkSpeedMultiplier or 1
	end
	return self.Stats:Get("WalkSpeed") * (self.Schema.Stats.WalkSpeedMultiplier or 1) * Mult
end

function Combatant.Destroy(self : any)
	self.Attack = nil
	self.Status:Destroy()
	self.Runtime:Destroy()
end

return Combatant

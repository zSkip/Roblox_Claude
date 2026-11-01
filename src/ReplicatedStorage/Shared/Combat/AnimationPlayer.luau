--!strict
-- Plays combat animations on one Animator. Used on both sides, each for what it owns, so every track
-- replicates exactly once: the owner client for its own character, the server for NPCs.
-- Attacks play at two speeds from their Timeline (windup frames at WindupSpeed, then the hit frames at
-- ActiveSpeed). Loading a track checks its real length against the baked AnimationManifest.
--
--   local P = AnimationPlayer.new(Animator)
--   P:OnState(Schema, State, Direction, AttackDef?, Timeline?)   -- call on every state change
--   P:Destroy()

local Manifest = require(script.Parent.AnimationManifest)
local WeaponClass = require(script.Parent.WeaponClass)

local AnimationPlayer = {}
AnimationPlayer.__index = AnimationPlayer

local Checked : { [string]: boolean } = {}

-- once per animation id per side: warn if the loaded length disagrees with the manifest by over a frame
local function Verify(Id : string, Track : AnimationTrack)
	if Checked[Id] then
		return
	end
	Checked[Id] = true
	task.spawn(function()
		local Deadline = os.clock() + 10
		while Track.Length <= 0 and os.clock() < Deadline do
			task.wait(0.1)
		end
		local Entry = Manifest.ById[Id]
		if not Entry then
			warn(`[Anim] {Id} is not in the AnimationManifest; run ServerScriptService.Tools.AnimationBake`)
		elseif Track.Length <= 0 then
			warn(`[Anim] {Entry.Name} did not load within 10 s`)
		elseif math.abs(Track.Length - Entry.Length) > 1 / Manifest.Fps then
			warn(`[Anim] {Entry.Name} is {Track.Length} s but the manifest says {Entry.Length} s; rerun the bake`)
		end
	end)
end

function AnimationPlayer.new(Animator : Animator)
	return setmetatable({
		Animator = Animator,
		Tracks = {} :: { [string]: AnimationTrack },
		Current = nil :: AnimationTrack?,
		Token = 0,
	}, AnimationPlayer)
end

function AnimationPlayer.Load(self : any, Id : string) : AnimationTrack
	local Track = self.Tracks[Id]
	if Track then
		return Track
	end
	local Animation = Instance.new("Animation")
	Animation.AnimationId = Id
	Track = (self.Animator :: Animator):LoadAnimation(Animation)
	self.Tracks[Id] = Track
	Verify(Id, Track)
	return Track
end

-- loads every id up front so the first swing doesn't wait on the asset
function AnimationPlayer.Preload(self : any, Ids : { string })
	for _, Id in Ids do
		self:Load(Id)
	end
end

function AnimationPlayer.Stop(self : any, Fade : number?)
	self.Token += 1
	local Current = self.Current
	self.Current = nil
	if Current then
		Current:Stop(Fade or 0.1)
	end
end

function AnimationPlayer.PlayAttack(self : any, Id : string, T : any)
	self:Stop(0.05)
	local Token = self.Token
	local Track = self:Load(Id)
	Track:Play(0.05, 1, T.WindupSpeed)
	self.Current = Track
	task.delay(T.Startup, function()
		if self.Token == Token and Track.IsPlaying then
			Track:AdjustSpeed(T.ActiveSpeed)
		end
	end)
end

-- fits a one-shot animation into Duration; looped ones play at normal speed. Stops when Duration ends.
function AnimationPlayer.PlayFor(self : any, Id : string, Duration : number)
	self:Stop(0.05)
	local Token = self.Token
	local Track = self:Load(Id)
	local Entry = Manifest.ById[Id]
	local Length = if Entry then Entry.Length else Track.Length
	local Looped = if Entry then Entry.Looped else Track.Looped
	local Speed = if not Looped and Length > 0 and Duration > 0 then Length / Duration else 1
	Track:Play(0.05, 1, Speed)
	self.Current = Track
	task.delay(Duration, function()
		if self.Token == Token then
			self:Stop(0.1)
		end
	end)
end

function AnimationPlayer.OnState(self : any, Schema : any, State : string, Direction : string?, Attack : any?, T : any?)
	if State == "Attacking" and Attack and T then
		local Id = T.AnimationId or WeaponClass.AnimationId(Schema, Attack.Spec.Animation)
		if Id then
			self:PlayAttack(Id, T)
			return
		end
	elseif State == "Dodging" then
		local Id = WeaponClass.AnimationId(Schema, `Dodge.{Direction or "Back"}`)
		if Id then
			self:PlayFor(Id, Schema.Defense.DodgeDuration)
			return
		end
	elseif State == "Parrying" then
		local Id = WeaponClass.AnimationId(Schema, `Parry.{Direction or "Front"}`)
		if Id then
			self:PlayFor(Id, Schema.Defense.ParryWindow)
			return
		end
	elseif State == "Blocking" then
		local Id = WeaponClass.AnimationId(Schema, "Block")
		if Id then
			self:Stop(0.05)
			local Track = self:Load(Id)
			Track:Play(0.1)
			self.Current = Track
			return
		end
	end
	self:Stop(0.1) -- interrupted (stun, guard break, back to idle) or no animation for this state
end

function AnimationPlayer.Destroy(self : any)
	self:Stop(0)
	for _, Track in self.Tracks do
		Track:Destroy()
	end
	table.clear(self.Tracks)
end

return AnimationPlayer

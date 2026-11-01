--!strict
-- Every Model tagged "NPC" becomes a combatant when it appears, so NPCs are real instances you place and
-- edit in Studio (see Tools/BuildArena). They go through the same CombatService functions as players.
-- Attributes: Brain (below, default Bag), Weapon (default LinkedSword), plus the brain's own.
--
--   Bag      stands still: Hit, combo, knockback, limb meters
--   Blocker  holds an omni block: Blocked, posture, GuardBreak; hit it from behind
--   Parrier  reads your swing and parries (70% correct direction): Parried / punished parry
--   Dodger   counter-dodges, then answers a perfect dodge with its follow-up attack
--   Fighter  walks up and attacks you: practise block, parry (F + direction) and dodge (Q)
--            AggroRange = how far it notices players
--   Caster   every so often telegraphs a tether to the nearest player, then applies an effect sourced
--            from itself. Stun or silence it to interrupt the cast.
--            CastEffect, CastInterval, CastWindup, CastDuration, CastRange; a RangeRing child shows the range

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Combat = ReplicatedStorage.Shared.Combat
local Directions = require(Combat.Directions)
local Resolver = require(Combat.Resolver)
local Config = require(Combat.CombatConfig)
local Effects = require(ReplicatedStorage.Shared.StatusEffects.Effects)

local NpcService = { Priority = 60 }

local Service : any = nil -- CombatService
local Hits : any = nil -- HitService
local EffectService : any = nil

function NpcService.Init(_self : any, Get : (string) -> any)
	Service = Get("CombatService")
	Hits = Get("HitService")
	EffectService = Get("EffectService")
end

local TAG = "NPC"
local RESPAWN_DELAY = 3

local function Face(Root : BasePart, Position : Vector3)
	local Flat = Vector3.new(Position.X, Root.Position.Y, Position.Z)
	if (Flat - Root.Position).Magnitude > 0.1 then
		Root.CFrame = CFrame.lookAt(Root.Position, Flat)
	end
end

-- side the attack lands on, and the key the configured rule wants for it
local function ParryKey(D : any, A : any, Attack : any) : string
	local Incoming = Resolver.IncomingSide(D.Root.CFrame, A.Root.Position, Attack.Direction)
	if Config.Resolver.ParryRule == "Same" and Attack.Direction then
		return Attack.Direction
	end
	return Incoming
end

local function Near(D : any, A : any, Range : number) : boolean
	return A ~= D and (A.Root.Position - D.Root.Position).Magnitude <= Range
end

-- closest living player inside Range, and how far away
local function NearestPlayer(D : any, Range : number) : (any, number)
	local Target : any = nil
	local Best = Range
	for _, Plr in Players:GetPlayers() do
		local C = Plr.Character and Service.Combatants[Plr.Character]
		if C and Service.Alive(C) then
			local Dist = (C.Root.Position - D.Root.Position).Magnitude
			if Dist < Best then
				Best, Target = Dist, C
			end
		end
	end
	return Target, Best
end

local Brains : { [string]: (any) -> () } = {}

-- connections to shared signals end with the NPC's runtime
local function Own(D : any, Connection : any)
	D.Runtime.Destroyed:Connect(function()
		Connection:Disconnect()
	end)
end

-- walk back to the spawn point after being knocked around
local function ReturnHome(D : any, Home : CFrame)
	task.spawn(function()
		while D.Runtime.Alive do
			task.wait(1)
			if D:Is("Idle") and (D.Root.Position - Home.Position).Magnitude > 3 then
				local Hum = D.Humanoid :: Humanoid
				Hum:MoveTo(Home.Position)
				Hum.MoveToFinished:Wait()
				if D:Is("Idle") then
					D.Root.CFrame = CFrame.new(D.Root.Position) * Home.Rotation
				end
			end
		end
	end)
end

function Brains.Bag(_ : any) end

function Brains.Blocker(D : any)
	task.spawn(function()
		while D.Runtime.Alive do
			if D:Is("Idle") then
				Service.DefendStart(D, nil)
			end
			task.wait(0.25)
		end
	end)
end

function Brains.Parrier(D : any)
	Own(D, Service.AttackStarted:Connect(function(A : any, Attack : any, T : any)
		if not Near(D, A, 14) or not D.Runtime.Alive then
			return
		end
		task.delay(math.max(0, T.Startup - 0.06), function()
			if A.Attack ~= Attack or not D.Runtime.Alive then
				return
			end
			Face(D.Root, A.Root.Position)
			local Key = ParryKey(D, A, Attack)
			if math.random() > 0.7 then
				local Others = {}
				for _, Name in Directions.Names do
					if Name ~= Key then
						table.insert(Others, Name)
					end
				end
				Key = Others[math.random(#Others)]
			end
			Service.DefendStart(D, Key)
			task.delay(0.3, function()
				Service.DefendEnd(D)
			end)
		end)
	end))
end

function Brains.Dodger(D : any)
	Own(D, Service.AttackStarted:Connect(function(A : any, Attack : any, T : any)
		if not Near(D, A, 14) or not D.Runtime.Alive then
			return
		end
		task.delay(math.max(0, T.Startup - 0.05), function()
			if A.Attack ~= Attack or not D.Runtime.Alive then
				return
			end
			local Incoming = Resolver.IncomingSide(D.Root.CFrame, A.Root.Position, Attack.Direction)
			Service.Dodge(D, Directions.Opposite[Incoming])
		end)
	end))
	Own(D, Hits.Resolved:Connect(function(A : any, Def : any, Outcome : string)
		if Def == D and Outcome == "PerfectDodge" then
			-- attack as soon as the dodge ends, still inside the follow-up window
			local DodgeEnds = (D.DodgeStart or os.clock()) + D.Schema.Defense.DodgeDuration
			task.delay(math.max(0, DodgeEnds - os.clock()) + 0.03, function()
				if D.Runtime.Alive and A.Root.Parent then
					Face(D.Root, A.Root.Position)
					Service.StartAttack(D, nil) -- matches the CounterSlash follow-up
				end
			end)
		end
	end))
end

function Brains.Fighter(D : any)
	local Range = D.Model:GetAttribute("AggroRange") or 30
	task.spawn(function()
		local NextAttack = 0
		while D.Runtime.Alive do
			local Target, Best = NearestPlayer(D, Range)
			local Hum = D.Humanoid :: Humanoid
			if Target then
				if Best > 5 then
					Hum:MoveTo(Target.Root.Position)
				else
					Hum:MoveTo(D.Root.Position)
					if D:Is("Idle") and os.clock() >= NextAttack then
						Face(D.Root, Target.Root.Position)
						local Dir = if math.random() < 0.4 then Directions.Names[math.random(4)] else nil
						if Service.StartAttack(D, Dir) then
							NextAttack = os.clock() + 0.6 + math.random() * 0.8
						end
					end
				end
			end
			task.wait(0.15)
		end
	end)
end

-- visible link from caster to target; returns the function that removes it
local function Tether(D : any, Target : any, Color : Color3) : () -> ()
	local A0 = Instance.new("Attachment")
	A0.Parent = D.Root
	local A1 = Instance.new("Attachment")
	A1.Parent = Target.Root
	local Beam = Instance.new("Beam")
	Beam.Attachment0 = A0
	Beam.Attachment1 = A1
	Beam.FaceCamera = true
	Beam.Width0 = 0.5
	Beam.Width1 = 0.5
	Beam.LightEmission = 1
	Beam.Color = ColorSequence.new(Color)
	Beam.Parent = D.Root
	return function()
		Beam:Destroy()
		A0:Destroy()
		A1:Destroy()
	end
end

function Brains.Caster(D : any)
	local Model = D.Model
	local Effect = Model:GetAttribute("CastEffect")
	if type(Effect) ~= "string" or not Effects.Get(Effect) then
		warn(`[NPC] {Model.Name}: unknown CastEffect {tostring(Effect)}`)
		return
	end
	local Interval = Model:GetAttribute("CastInterval") or 6
	local Windup = Model:GetAttribute("CastWindup") or 0.8
	local Duration = Model:GetAttribute("CastDuration")
	local Range = Model:GetAttribute("CastRange") or 20
	local Color = (D.Root :: BasePart).Color
	local Head = Model:FindFirstChild("Head") :: BasePart?
	if Head then
		Color = Head.Color
	end
	local Ring = Model:FindFirstChild("RangeRing") :: BasePart?
	if Ring then
		Ring.Size = Vector3.new(Ring.Size.X, Range * 2, Range * 2)
	end

	local function CanCast() : boolean
		return D.Runtime.Alive and D:Is("Idle") and D.Status:Can("Ability")
	end

	local function Cast(Target : any) : boolean
		Face(D.Root, Target.Root.Position)
		local Untether = Tether(D, Target, Color)
		task.wait(Windup)
		if not CanCast() or not Service.Alive(Target) or not Near(D, Target, Range * 1.25) then
			Untether()
			return false -- interrupted, or the target got away
		end
		local Overrides = if Duration then { Duration = Duration } else nil
		local Inst = EffectService.Apply(Target, Effect, D, Overrides)
		task.delay(if Inst then Duration or Inst.Def.Duration else 0, Untether)
		return Inst ~= nil
	end

	task.spawn(function()
		task.wait(Interval * math.random())
		while D.Runtime.Alive do
			local Target = if CanCast() then NearestPlayer(D, Range) else nil
			if Target and Cast(Target) then
				task.wait(Interval)
			else
				task.wait(0.25)
			end
		end
	end)
end

local function Setup(Model : Model)
	if not Model:IsA("Model") or not Model:IsDescendantOf(workspace) then
		return
	end
	local Parent = Model.Parent
	local Template = Model:Clone() -- what a death brings back; carries the tag, so returning it runs Setup again

	local Root = Model:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not Root then
		warn(`[NPC] {Model:GetFullName()} has no HumanoidRootPart`)
		return
	end
	local Home = Root.CFrame

	local Weapon = Model:GetAttribute("Weapon")
	local C = Service.Register(Model, nil, if type(Weapon) == "string" then Weapon else "LinkedSword")
	if not C then
		return
	end
	-- server simulates NPCs (needed for server-side knockback/dodge); after Register, because welding the
	-- weapon on rebuilds the assembly and resets its owner to automatic
	Root:SetNetworkOwner(nil)
	local Kind = Model:GetAttribute("Brain")
	local Brain = Brains[Kind or "Bag"]
	if Brain then
		Brain(C)
	else
		warn(`[NPC] {Model.Name}: unknown Brain {tostring(Kind)}`)
	end
	if Kind ~= "Fighter" then
		ReturnHome(C, Home)
	end

	local Hum = Model:FindFirstChildOfClass("Humanoid") :: Humanoid
	Hum.Died:Connect(function()
		task.wait(RESPAWN_DELAY)
		Model:Destroy()
		Template.Parent = Parent
	end)
end

function NpcService.Start(_self : any)
	CollectionService:GetInstanceAddedSignal(TAG):Connect(function(Model : any)
		task.spawn(Setup, Model)
	end)
	for _, Model in CollectionService:GetTagged(TAG) do
		task.spawn(Setup, Model :: any)
	end
end

return NpcService

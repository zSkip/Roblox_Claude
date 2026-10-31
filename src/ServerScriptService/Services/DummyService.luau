--!strict
-- Training dummies (NPC combatants) so every outcome can be tested solo in Play mode.
-- They go through the same CombatService functions as players (PvE uses the same pipeline).
--
--   Bag      stands still: Hit, combo, knockback, limb meters
--   Blocker  holds an omni block: Blocked, posture, GuardBreak; hit it from behind
--   Parrier  reads your swing and parries (70% correct direction): Parried / punished parry
--   Dodger   counter-dodges, then answers a perfect dodge with its follow-up attack
--   Fighter  walks up and attacks you: practise block, parry (F + direction) and dodge (Q)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Combat = ReplicatedStorage.Shared.Combat
local Directions = require(Combat.Directions)
local Resolver = require(Combat.Resolver)
local Config = require(Combat.CombatConfig)

local Dummies = { Priority = 60 }

local Service : any = nil -- CombatService
local Hits : any = nil -- HitService

function Dummies.Init(_self : any, Get : (string) -> any)
	Service = Get("CombatService")
	Hits = Get("HitService")
end

local Colors = {
	Bag = Color3.fromRGB(163, 162, 165),
	Blocker = Color3.fromRGB(70, 110, 200),
	Parrier = Color3.fromRGB(220, 180, 60),
	Dodger = Color3.fromRGB(80, 200, 200),
	Fighter = Color3.fromRGB(200, 70, 70),
}

local function Face(Root : BasePart, Position : Vector3)
	local Flat = Vector3.new(Position.X, Root.Position.Y, Position.Z)
	if (Flat - Root.Position).Magnitude > 0.1 then
		Root.CFrame = CFrame.lookAt(Root.Position, Flat)
	end
end

local function Label(Model : Model, Text : string)
	local Head = Model:FindFirstChild("Head")
	if not Head then
		return
	end
	local Gui = Instance.new("BillboardGui")
	Gui.Name = "DummyLabel"
	Gui.Size = UDim2.fromOffset(160, 24)
	Gui.StudsOffset = Vector3.new(0, 2.2, 0)
	Gui.MaxDistance = 60
	local L = Instance.new("TextLabel")
	L.Size = UDim2.fromScale(1, 1)
	L.BackgroundTransparency = 1
	L.Text = Text
	L.TextColor3 = Color3.new(1, 1, 1)
	L.TextStrokeTransparency = 0.3
	L.Font = Enum.Font.GothamBold
	L.TextScaled = true
	L.Parent = Gui
	Gui.Parent = Head
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

local Brains : { [string]: (any) -> () } = {}

-- connections to shared signals end with the dummy's runtime
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
	task.spawn(function()
		local NextAttack = 0
		while D.Runtime.Alive do
			local Target : any = nil
			local Best = 30
			for _, Plr in Players:GetPlayers() do
				local C = Plr.Character and Service.Combatants[Plr.Character]
				if C and (C.Humanoid :: Humanoid).Health > 0 then
					local Dist = (C.Root.Position - D.Root.Position).Magnitude
					if Dist < Best then
						Best, Target = Dist, C
					end
				end
			end
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

local function Build(Kind : string) : Model
	local Desc = Instance.new("HumanoidDescription")
	local Color = Colors[Kind] or Colors.Bag
	Desc.HeadColor = Color
	Desc.TorsoColor = Color
	Desc.LeftArmColor = Color
	Desc.RightArmColor = Color
	Desc.LeftLegColor = Color
	Desc.RightLegColor = Color
	local Model = Players:CreateHumanoidModelFromDescription(Desc, Enum.HumanoidRigType.R6)
	Model.Name = `{Kind} Dummy`
	local Hum = Model:FindFirstChildOfClass("Humanoid") :: Humanoid
	Hum.DisplayName = `{Kind} Dummy`
	Hum.MaxHealth = 150
	Hum.Health = 150
	return Model
end

function Dummies.Spawn(Kind : string, At : CFrame)
	local Model = Build(Kind)
	Model:PivotTo(At)
	Model.Parent = workspace
	local Root = Model:FindFirstChild("HumanoidRootPart") :: BasePart
	Root:SetNetworkOwner(nil) -- server simulates NPCs (needed for server-side knockback/dodge)
	Label(Model, `{Kind}`)

	local C = Service.Register(Model, nil, "LinkedSword")
	if not C then
		return
	end
	local Brain = Brains[Kind]
	if Brain then
		Brain(C)
	end
	if Kind ~= "Fighter" then
		ReturnHome(C, At)
	end

	local Hum = Model:FindFirstChildOfClass("Humanoid") :: Humanoid
	Hum.Died:Connect(function()
		task.wait(3)
		Model:Destroy()
		Dummies.Spawn(Kind, At)
	end)
end

function Dummies.SpawnAll()
	local Spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	local Origin = if Spawn then Spawn.Position else Vector3.new(0, 0, 0)
	local Kinds = { "Bag", "Blocker", "Parrier", "Dodger", "Fighter" }
	for I, Kind in Kinds do
		local X = (I - (#Kinds + 1) / 2) * 10
		local Position = Origin + Vector3.new(X, 4, -22)
		local CF = CFrame.lookAt(Position, Vector3.new(Origin.X, Position.Y, Origin.Z))
		if Kind == "Fighter" then
			CF = CFrame.new(Origin + Vector3.new(0, 4, 30))
		end
		task.spawn(Dummies.Spawn, Kind, CF)
	end
end

function Dummies.Start(_self : any)
	Dummies.SpawnAll()
end

return Dummies

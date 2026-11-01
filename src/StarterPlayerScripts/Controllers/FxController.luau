--!strict
-- Client-side feedback for every combatant: state highlights (white = incoming attack telegraph),
-- a direction label so defenders can react (G9), procedural weapon swings for attacks whose animation
-- is still a placeholder, hit-area flashes, result popups and red limb-meter highlights.
-- Called by CombatController for every broadcast; has no lifecycle of its own.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Combat = ReplicatedStorage.Shared.Combat
local WeaponClass = require(Combat.WeaponClass)
local WeaponModel = require(Combat.WeaponModel)
local Directions = require(Combat.Directions)
local Limbs = require(Combat.Limbs)
local Timeline = require(Combat.Timeline)
local Config = require(Combat.CombatConfig)

local Fx = { Priority = 10 }

local StateColors : { [string]: Color3 } = {
	Attacking = Color3.fromRGB(255, 255, 255),
	Blocking = Color3.fromRGB(80, 140, 255),
	Parrying = Color3.fromRGB(255, 210, 60),
	Dodging = Color3.fromRGB(90, 230, 230),
	Stunned = Color3.fromRGB(255, 70, 70),
	GuardBroken = Color3.fromRGB(170, 70, 255),
}

local StateText : { [string]: string } = {
	Blocking = "BLOCK",
	Parrying = "PARRY",
	Dodging = "DODGE",
	Stunned = "STUNNED",
	GuardBroken = "GUARD BROKEN",
}

local Keys = { Front = "W", Back = "S", Left = "A", Right = "D" }

local ResultStyle : { [string]: { Text : string, Color : Color3 } } = {
	Hit = { Text = "-%d", Color = Color3.fromRGB(255, 80, 80) },
	Blocked = { Text = "BLOCKED -%d", Color = Color3.fromRGB(110, 160, 255) },
	Parried = { Text = "PARRIED!", Color = Color3.fromRGB(255, 215, 70) },
	Dodged = { Text = "DODGED", Color = Color3.fromRGB(220, 220, 220) },
	PerfectDodge = { Text = "PERFECT DODGE!", Color = Color3.fromRGB(90, 240, 240) },
	GuardBreak = { Text = "GUARD BREAK", Color = Color3.fromRGB(180, 90, 255) },
	Clash = { Text = "CLASH", Color = Color3.fromRGB(255, 255, 255) },
}

---------------------------------------------------------------- weapon poses

local function Pose(Pitch : number, Yaw : number) : CFrame
	return CFrame.new(0, -1, 0) * CFrame.Angles(math.rad(Pitch), math.rad(Yaw), 0) * CFrame.Angles(-math.pi / 2, 0, 0)
end

local Rest = WeaponModel.GripC0
local BlockPose = Pose(70, 35)
local Swings : { [string]: { CFrame } } = {
	Right = { Pose(10, -85), Pose(-10, 85) }, -- from the attacker's right to left
	Left = { Pose(10, 85), Pose(-10, -85) },
	Front = { Pose(115, 0), Pose(-35, 0) }, -- overhead chop
	Back = { Pose(-70, 0), Pose(95, 0) }, -- uppercut
}

local function TweenGrip(Model : Model, Target : CFrame, Duration : number)
	local Motor = WeaponModel.GetMotor(Model, "Handle")
	if Motor then
		TweenService:Create(Motor, TweenInfo.new(math.max(Duration, 0.03), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { C0 = Target }):Play()
	end
end

---------------------------------------------------------------- per-actor visuals

type ActorFx = {
	Highlight : Highlight,
	Label : TextLabel,
	Token : number,
	Limbs : { [string]: { Highlight } },
}

local Actors : { [Model]: ActorFx } = setmetatable({}, { __mode = "k" }) :: any

local function Get(Model : Model) : ActorFx
	local A = Actors[Model]
	if A and A.Highlight.Parent and A.Label.Parent and A.Label.Parent.Parent then
		return A
	end
	local H = Instance.new("Highlight")
	H.Name = "StateHighlight"
	H.Enabled = false
	H.DepthMode = Enum.HighlightDepthMode.Occluded
	H.FillTransparency = 0.6
	H.OutlineTransparency = 0
	H.Parent = Model

	local Gui = Instance.new("BillboardGui")
	Gui.Name = "CombatLabel"
	Gui.Size = UDim2.fromOffset(240, 26)
	Gui.StudsOffset = Vector3.new(0, 3.6, 0)
	Gui.AlwaysOnTop = true
	Gui.MaxDistance = 80
	Gui.Adornee = Model:FindFirstChild("Head") :: BasePart?
	local L = Instance.new("TextLabel")
	L.Size = UDim2.fromScale(1, 1)
	L.BackgroundTransparency = 1
	L.Font = Enum.Font.GothamBlack
	L.TextScaled = true
	L.TextStrokeTransparency = 0.2
	L.TextColor3 = Color3.new(1, 1, 1)
	L.Text = ""
	L.Visible = false
	L.Parent = Gui
	Gui.Parent = Gui.Adornee or Model -- destroyed with the character

	A = { Highlight = H, Label = L, Token = 0, Limbs = {} }
	Actors[Model] = A
	return A :: ActorFx
end

local function ParryKeyFor(Direction : string?) : string
	if Direction == nil then
		return Keys.Front -- combo M1 from the front lands on the front
	end
	if Config.Resolver.ParryRule == "Same" then
		return Keys[Direction]
	end
	return Keys[Directions.LandingSide(Direction :: any)]
end

local function Describe(Attack : any, Direction : string?) : string
	local Name = if Attack.Kind == "Combo"
		then `M1 #{Attack.Input.ComboIndex or "?"}`
		elseif Attack.Kind == "FollowUp" then "COUNTER"
		else `{string.upper(Direction or "?")} SWING`
	local Heavy = if Attack.Spec.Knockback then " !" else ""
	return `{Name}{Heavy}  [parry {ParryKeyFor(Direction)}]`
end

local function SlashFlash(Model : Model, Hitbox : any)
	local Root = Model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not Root or not Hitbox then
		return
	end
	local P = Instance.new("Part")
	P.Anchored = true
	P.CanCollide = false
	P.CanQuery = false
	P.CanTouch = false
	P.CastShadow = false
	P.Material = Enum.Material.Neon
	P.Color = Color3.fromRGB(255, 240, 220)
	P.Transparency = 0.55
	P.Size = Vector3.new(Hitbox.Size.X, 0.15, Hitbox.Size.Z)
	P.CFrame = Root.CFrame * (Hitbox.Offset or CFrame.new())
	P.Parent = workspace
	local T = TweenService:Create(P, TweenInfo.new(0.25), { Transparency = 1 })
	T.Completed:Connect(function()
		P:Destroy()
	end)
	T:Play()
end

-- Called for every state broadcast. IsLocal hides the reaction label on your own character.
function Fx.OnState(Model : Model, State : string, Direction : string?, AttackId : string, IsLocal : boolean)
	local A = Get(Model)
	A.Token += 1
	local Token = A.Token
	local H, L = A.Highlight, A.Label

	if State == "Attacking" then
		local Def = WeaponClass.Get(Model:GetAttribute("Weapon") :: string?)
		local Attack = Def and Def.Registry:Get(AttackId)
		if not Attack then
			return
		end
		local T = Timeline.ForAttack(Def.Schema, Attack.Spec, Model:GetAttribute("AttackSpeed") :: number?)
		local Swing = Swings[Attack.Spec.Swing or Direction or "Right"] or Swings.Right
		local Animated = T.AnimationId ~= nil -- a real animation moves the arm; skip the procedural swing

		-- startup: white telegraph + direction label
		H.FillColor = StateColors.Attacking
		H.OutlineColor = StateColors.Attacking
		H.FillTransparency = 0.35
		H.Enabled = true
		L.Text = Describe(Attack, Direction)
		L.TextColor3 = if Attack.Spec.Knockback then Color3.fromRGB(255, 170, 80) else Color3.new(1, 1, 1)
		L.Visible = not IsLocal
		if not Animated then
			TweenGrip(Model, Swing[1], T.Startup)
		end

		task.delay(T.Startup, function()
			if A.Token ~= Token then
				return
			end
			H.FillColor = Color3.fromRGB(255, 150, 60)
			H.FillTransparency = 0.2
			if not Animated then
				TweenGrip(Model, Swing[2], T.Active)
			end
			SlashFlash(Model, Attack.Spec.Hitbox)
		end)
		task.delay(T.Startup + T.Active, function()
			if A.Token ~= Token then
				return
			end
			H.Enabled = false
			L.Visible = false
			if not Animated then
				TweenGrip(Model, Rest, T.Recovery)
			end
		end)
		return
	end

	local Color = StateColors[State]
	if Color then
		H.FillColor = Color
		H.OutlineColor = Color
		H.FillTransparency = if State == "Dodging" then 0.8 else 0.55
		H.Enabled = true
		local Text = StateText[State] or State
		if State == "Parrying" and Direction then
			Text = `PARRY {Keys[Direction] or ""}`
		end
		L.Text = Text
		L.TextColor3 = Color
		L.Visible = not IsLocal or State == "Stunned" or State == "GuardBroken"
	else
		H.Enabled = false
		L.Visible = false
	end
	TweenGrip(Model, if State == "Blocking" or State == "Parrying" then BlockPose else Rest, 0.1)
end

local function Popup(Model : Model, Text : string, Color : Color3)
	local Head = Model:FindFirstChild("Head") :: BasePart?
	if not Head then
		return
	end
	local Gui = Instance.new("BillboardGui")
	Gui.Size = UDim2.fromOffset(200, 30)
	Gui.AlwaysOnTop = true
	Gui.Adornee = Head
	Gui.StudsOffset = Vector3.new((math.random() - 0.5) * 2, 1.5, 0)
	local L = Instance.new("TextLabel")
	L.Size = UDim2.fromScale(1, 1)
	L.BackgroundTransparency = 1
	L.Font = Enum.Font.GothamBlack
	L.TextScaled = true
	L.TextColor3 = Color
	L.TextStrokeTransparency = 0.2
	L.Text = Text
	L.Parent = Gui
	Gui.Parent = Head
	local Info = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(Gui, Info, { StudsOffset = Gui.StudsOffset + Vector3.new(0, 2.5, 0) }):Play()
	TweenService:Create(L, Info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(0.95, function()
		Gui:Destroy()
	end)
end

function Fx.OnResult(_Attacker : Model?, Defender : Model?, Outcome : string, Damage : number)
	local Style = ResultStyle[Outcome]
	if not Style or not Defender then
		return
	end
	local Text = if string.find(Style.Text, "%%d") then string.format(Style.Text, Damage) else Style.Text
	if Outcome == "Blocked" and Damage == 0 then
		Text = "BLOCKED"
	end
	Popup(Defender, Text, Style.Color)
end

function Fx.SetLimb(Model : Model, Group : string, Fill : number)
	local A = Get(Model)
	local List = A.Limbs[Group]
	if Fill <= 0 then
		if List then
			for _, H in List do
				H:Destroy()
			end
			A.Limbs[Group] = nil
		end
		return
	end
	if not List then
		List = {}
		local Cfg = Limbs.Groups[Group]
		for _, PartName in (if Cfg then Cfg.Parts else {}) do
			local Part = Model:FindFirstChild(PartName)
			if Part and Part:IsA("BasePart") then
				local H = Instance.new("Highlight")
				H.Name = "LimbHighlight"
				H.Adornee = Part
				H.FillColor = Color3.fromRGB(255, 30, 30)
				H.OutlineTransparency = 1
				H.DepthMode = Enum.HighlightDepthMode.Occluded
				H.Parent = Part
				table.insert(List, H)
			end
		end
		A.Limbs[Group] = List
	end
	for _, H in List :: { Highlight } do
		H.FillTransparency = 1 - 0.85 * math.clamp(Fill, 0, 1) -- transparent → solid red as the meter fills
	end
end

function Fx.LimbBurst(Model : Model, Group : string)
	Popup(Model, `{string.upper(Group)} BROKEN`, Color3.fromRGB(255, 40, 40))
	Fx.SetLimb(Model, Group, 0)
end

return Fx

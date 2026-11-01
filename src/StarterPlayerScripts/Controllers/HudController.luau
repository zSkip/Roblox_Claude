--!strict
-- Minimal combat HUD: posture bar, exhaustion stacks, status-effect icons (yours above the posture bar,
-- everyone else's over their head) and a controls cheat sheet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Combat.CombatConfig)

local Hud = { Priority = 10 }

local EffectController : any = nil

function Hud.Init(_self : any, Get : (string) -> any)
	EffectController = Get("EffectController")
end

local Gui = Instance.new("ScreenGui")
Gui.Name = "CombatHud"
Gui.ResetOnSpawn = false
Gui.IgnoreGuiInset = false

local function Label(Parent : Instance, Text : string, Size : UDim2, Position : UDim2) : TextLabel
	local L = Instance.new("TextLabel")
	L.BackgroundTransparency = 1
	L.Font = Enum.Font.GothamBold
	L.TextColor3 = Color3.new(1, 1, 1)
	L.TextStrokeTransparency = 0.4
	L.TextSize = 16
	L.Text = Text
	L.Size = Size
	L.Position = Position
	L.Parent = Parent
	return L
end

-- posture bar (bottom centre)
local Bar = Instance.new("Frame")
Bar.AnchorPoint = Vector2.new(0.5, 1)
Bar.Position = UDim2.new(0.5, 0, 1, -90)
Bar.Size = UDim2.fromOffset(300, 14)
Bar.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
Bar.BorderSizePixel = 0
Bar.Parent = Gui
Instance.new("UICorner").Parent = Bar

local Fill = Instance.new("Frame")
Fill.Size = UDim2.fromScale(1, 1)
Fill.BackgroundColor3 = Color3.fromRGB(240, 200, 80)
Fill.BorderSizePixel = 0
Fill.Parent = Bar
Instance.new("UICorner").Parent = Fill

local PostureText = Label(Bar, "Posture 100", UDim2.new(1, 0, 0, 18), UDim2.fromOffset(0, -20))
local ExhaustText = Label(Bar, "Exhaustion 0", UDim2.new(1, 0, 0, 18), UDim2.fromOffset(0, 16))

-- controls (top left)
local Help = Label(Gui, table.concat({
	"M1  combo (1-2-3-4, #4 knocks back)",
	"W/A/S/D tap, then M1  directional attack (S = knockback)",
	"F hold  omni block    W/A/S/D tap, then F  directional parry",
	"Q  dodge (tap a direction first)   counter-dodge = follow-up",
	"White glow = incoming attack; the label says which key parries it",
}, "\n"), UDim2.fromOffset(460, 110), UDim2.fromOffset(12, 60))
Help.TextXAlignment = Enum.TextXAlignment.Left
Help.TextYAlignment = Enum.TextYAlignment.Top
Help.TextSize = 14
Help.Font = Enum.Font.Gotham

function Hud.SetMeters(Posture : number, Stacks : number)
	Fill.Size = UDim2.fromScale(math.clamp(Posture / 100, 0, 1), 1)
	Fill.BackgroundColor3 = if Posture < 30 then Color3.fromRGB(255, 90, 60) else Color3.fromRGB(240, 200, 80)
	PostureText.Text = `Posture {Posture}`
	local Threshold = Config.Exhaustion.Threshold
	if Stacks >= Threshold then
		ExhaustText.Text = `EXHAUSTED Lv{Stacks - Threshold + 1}  ({Stacks} stacks)`
		ExhaustText.TextColor3 = Color3.fromRGB(255, 110, 90)
	else
		ExhaustText.Text = `Exhaustion {Stacks} / {Threshold}`
		ExhaustText.TextColor3 = Color3.new(1, 1, 1)
	end
end

---------------------------------------------------------------- status effect icons

local KindColors = {
	CC = Color3.fromRGB(255, 80, 80),
	Debuff = Color3.fromRGB(255, 160, 60),
	Buff = Color3.fromRGB(90, 200, 255),
}

local function Chip(Parent : Instance, Row : any, Order : number) : TextLabel
	local L = Label(Parent, "", UDim2.fromOffset(0, 18), UDim2.new())
	L.AutomaticSize = Enum.AutomaticSize.X
	L.BackgroundTransparency = 0.25
	L.BackgroundColor3 = KindColors[Row.Def.Kind] or Color3.new(0.3, 0.3, 0.3)
	L.TextSize = 13
	L.LayoutOrder = Order
	local Pad = Instance.new("UIPadding")
	Pad.PaddingLeft = UDim.new(0, 5)
	Pad.PaddingRight = UDim.new(0, 5)
	Pad.Parent = L
	Instance.new("UICorner").Parent = L
	return L
end

local function ChipText(Row : any) : string
	local Text = Row.Def.Id
	if Row.Stacks > 1 then
		Text ..= ` x{Row.Stacks}`
	end
	local Left = EffectController.Remaining(Row)
	if Left ~= math.huge then
		Text ..= string.format(" %.1fs", Left)
	end
	return Text
end

local function Row(Parent : Instance, Align : Enum.HorizontalAlignment) : Frame
	local F = Instance.new("Frame")
	F.BackgroundTransparency = 1
	F.Size = UDim2.fromScale(1, 1)
	local List = Instance.new("UIListLayout")
	List.FillDirection = Enum.FillDirection.Horizontal
	List.HorizontalAlignment = Align
	List.VerticalAlignment = Enum.VerticalAlignment.Bottom
	List.SortOrder = Enum.SortOrder.LayoutOrder
	List.Padding = UDim.new(0, 4)
	List.Parent = F
	F.Parent = Parent
	return F
end

-- yours: a row above the posture text
local OwnHolder = Instance.new("Frame")
OwnHolder.BackgroundTransparency = 1
OwnHolder.AnchorPoint = Vector2.new(0.5, 1)
OwnHolder.Position = UDim2.new(0.5, 0, 0, -24)
OwnHolder.Size = UDim2.fromOffset(420, 18)
OwnHolder.Parent = Bar
local OwnRow = Row(OwnHolder, Enum.HorizontalAlignment.Center)

-- everyone else's: a billboard over the head, above Fx's state label
local Boards : { [Model]: Frame } = {}

local function BoardFor(Model : Model) : Frame?
	local Existing = Boards[Model]
	if Existing and Existing.Parent then
		return Existing
	end
	local Head = Model:FindFirstChild("Head") :: BasePart?
	if not Head then
		return nil
	end
	local B = Instance.new("BillboardGui")
	B.Name = "EffectIcons"
	B.Size = UDim2.fromOffset(300, 18)
	B.StudsOffset = Vector3.new(0, 4.6, 0)
	B.AlwaysOnTop = true
	B.MaxDistance = 80
	B.Adornee = Head
	B.Parent = Head -- destroyed with the character
	local F = Row(B, Enum.HorizontalAlignment.Center)
	Boards[Model] = F
	return F
end

local function Redraw(Model : Model)
	local Own = Model == Players.LocalPlayer.Character
	local Holder = if Own then OwnRow else BoardFor(Model)
	if not Holder then
		return
	end
	for _, Child in Holder:GetChildren() do
		if Child:IsA("TextLabel") then
			Child:Destroy()
		end
	end
	for NetId, R in EffectController.Get(Model) do
		local L = Chip(Holder, R, NetId)
		L.Name = R.Def.Id
		L.Text = ChipText(R)
	end
end

-- countdowns tick on the shared clock
local function Refresh(Holder : Instance, Model : Model)
	local Rows = EffectController.Get(Model)
	for NetId, R in Rows do
		local L = Holder:FindFirstChild(R.Def.Id) :: TextLabel?
		if L then
			L.Text = ChipText(R)
		end
	end
end

function Hud.Start(_self : any)
	Gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	EffectController.Changed:Connect(function(Model : Model)
		Redraw(Model)
	end)
	Players.LocalPlayer.CharacterAdded:Connect(function()
		for _, Child in OwnRow:GetChildren() do
			if Child:IsA("TextLabel") then
				Child:Destroy()
			end
		end
	end)
	RunService.Heartbeat:Connect(function()
		local Character = Players.LocalPlayer.Character
		if Character then
			Refresh(OwnRow, Character)
		end
		for Model, Holder in Boards do
			if not Holder.Parent or not Model.Parent then
				Boards[Model] = nil
			else
				Refresh(Holder, Model)
			end
		end
	end)
end

return Hud

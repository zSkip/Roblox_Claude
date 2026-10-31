--!strict
-- Minimal combat HUD: posture bar, exhaustion stacks and a controls cheat sheet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("CombatConfig"))

local Hud = {}

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

function Hud.Mount()
	Gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

return Hud

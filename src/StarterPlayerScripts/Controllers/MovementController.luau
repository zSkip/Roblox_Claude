--!strict
-- Applies the tiered animation lock (Shared/Combat/LockProfile) to your own character every frame:
--   walk speed = the server's WalkCap attribute × the lock's Move share (eases to 0 over a windup)
--   outside Free, turning moves from Humanoid.AutoRotate to an AlignOrientation toward the camera's yaw,
--   capped at Lock.TurnRate × the lock's Turn share; Turn 0 holds the current facing
-- The state's sample is merged with the strongest lock among your mirrored status effects
-- (LockProfile.Combine), so a Root or stun locks you on the frame its S_Effect arrives.
-- The server integrates the same curve to reject claims from characters that slid (HitService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Combat = ReplicatedStorage.Shared.Combat
local LockProfile = require(Combat.LockProfile)
local Config = require(Combat.CombatConfig)

local MovementController = { Priority = 30 }

local CombatController : any = nil
local EffectController : any = nil

local State = "Idle"
local StateStart = 0
local CurrentTimeline : any = nil

local Character : Model? = nil
local Hum : Humanoid? = nil
local Root : BasePart? = nil
local Align : AlignOrientation? = nil
local Held : CFrame? = nil

-- latest sample, for debugging / UI
MovementController.Sample = LockProfile.States.Idle

function MovementController.Init(_self : any, Get : (string) -> any)
	CombatController = Get("CombatController")
	EffectController = Get("EffectController")
end

local function OnCharacter(Model : Model)
	if Align then
		Align:Destroy()
	end
	Character, Hum, Root, Align, Held = nil, nil, nil, nil, nil
	local H = Model:WaitForChild("Humanoid") :: Humanoid
	local R = Model:WaitForChild("HumanoidRootPart") :: BasePart
	local Attachment = R:FindFirstChild("RootAttachment") :: Attachment?
	if not Attachment then
		local New = Instance.new("Attachment")
		New.Name = "RootAttachment"
		New.Parent = R
		Attachment = New
	end
	local A = Instance.new("AlignOrientation")
	A.Name = "CombatTurn"
	A.Mode = Enum.OrientationAlignmentMode.OneAttachment
	A.Attachment0 = Attachment
	A.MaxTorque = math.huge
	A.Responsiveness = 200
	A.Enabled = false
	A.Parent = R
	Character, Hum, Root, Align = Model, H, R, A
	State, StateStart, CurrentTimeline = "Idle", os.clock(), nil
end

local function Yaw(CF : CFrame) : CFrame
	local Look = CF.LookVector * Vector3.new(1, 0, 1)
	if Look.Magnitude < 1e-3 then
		return CFrame.identity
	end
	return CFrame.lookAt(Vector3.zero, Look.Unit)
end

local function Step()
	local H, R, A = Hum, Root, Align
	if not H or not R or not A or not Character or H.Health <= 0 then
		return
	end
	local S = LockProfile.Combine(
		LockProfile.Sample(State, os.clock() - StateStart, CurrentTimeline, Config.Lock),
		EffectController.LockTier(Character)
	)
	MovementController.Sample = S

	local Cap = Character:GetAttribute("WalkCap") :: number?
	if Cap then
		H.WalkSpeed = Cap * S.Move
	end

	if S.Tier == LockProfile.Tiers.Free then
		H.AutoRotate = true
		A.Enabled = false
		Held = nil
		return
	end
	H.AutoRotate = false
	local Camera = workspace.CurrentCamera
	if S.Turn > 0 and Camera then
		Held = nil
		A.CFrame = Yaw(Camera.CFrame)
		A.MaxAngularVelocity = Config.Lock.TurnRate * S.Turn
	else
		if not Held then
			Held = Yaw(R.CFrame)
		end
		A.CFrame = Held :: CFrame
		A.MaxAngularVelocity = Config.Lock.TurnRate
	end
	A.Enabled = true
end

function MovementController.Start(_self : any)
	CombatController.CharacterChanged:Connect(OnCharacter)
	if CombatController.Character then
		task.spawn(OnCharacter, CombatController.Character)
	end
	CombatController.StateChanged:Connect(function(NewState : string, _Direction : string?, _Attack : any?, T : any?)
		State, StateStart, CurrentTimeline = NewState, os.clock(), T
		Held = nil
	end)
	RunService:BindToRenderStep("CombatMovement", Enum.RenderPriority.Character.Value + 1, Step)
end

return MovementController

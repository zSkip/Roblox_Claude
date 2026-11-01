--!strict
-- Input → intents. Taps of W/A/S/D are buffered for the next M1 / F / Q inside Timings.DirectionalWindow;
-- an M1 pressed while you are still busy is kept for Timings.InputBuffer and sent when you get back to
-- neutral (the server still decides).

local UserInputService = game:GetService("UserInputService")

local InputController = { Priority = 40 }

local CombatController : any = nil

function InputController.Init(_self : any, Get : (string) -> any)
	CombatController = Get("CombatController")
end

local function Schema() : any
	return CombatController.Weapon().Schema
end

-- latest W/A/S/D tap; consumed by the next M1 / F / Q inside DirectionalWindow
local Buffered : string? = nil
local BufferedAt = -math.huge

local function ConsumeDirection() : string?
	local Dir = Buffered
	Buffered = nil
	if Dir and os.clock() - BufferedAt <= Schema().Timings.DirectionalWindow then
		return Dir
	end
	return nil
end

-- built around shift-lock: without it, face the camera's yaw when an action starts
local function SnapToCamera()
	local Root = CombatController.Root :: BasePart?
	local Camera = workspace.CurrentCamera
	if not Root or not Camera or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		return
	end
	local Look = Camera.CFrame.LookVector * Vector3.new(1, 0, 1)
	if Look.Magnitude > 1e-3 then
		Root.CFrame = CFrame.lookAt(Root.Position, Root.Position + Look.Unit)
	end
end

local function Act(Action : string, Direction : string?)
	SnapToCamera()
	CombatController.Send(Action, Direction)
end

-- an M1 pressed during an action waits here for neutral
local Pending : { Direction : string?, Until : number }? = nil

local function Attack(Direction : string?)
	local State = CombatController.State
	if State == "Idle" then
		Pending = nil
		Act("Attack", Direction)
	else
		Pending = { Direction = Direction, Until = os.clock() + Schema().Timings.InputBuffer }
	end
end

function InputController.Start(_self : any)
	CombatController.StateChanged:Connect(function(State : string)
		if State == "Idle" then
			local P = Pending
			Pending = nil
			if P and os.clock() <= P.Until then
				Act("Attack", P.Direction)
			end
		elseif State ~= "Attacking" then
			Pending = nil -- stunned, parried, dodging...: drop the buffered swing
		end
	end)

	UserInputService.InputBegan:Connect(function(Input : InputObject, Processed : boolean)
		if Processed or not CombatController.Character then
			return
		end
		local Keys = Schema().Keybinds
		local Dir = Keys.Directions[Input.KeyCode]
		if Dir then
			Buffered, BufferedAt = Dir, os.clock()
			return
		end
		if Input.UserInputType == Keys.Attack then
			Attack(ConsumeDirection())
		elseif Input.KeyCode == Keys.Defend then
			Act("DefendStart", ConsumeDirection())
		elseif Input.KeyCode == Keys.Dodge then
			Act("Dodge", ConsumeDirection())
		end
	end)

	UserInputService.InputEnded:Connect(function(Input : InputObject)
		if CombatController.Character and Input.KeyCode == Schema().Keybinds.Defend then
			CombatController.Send("DefendEnd")
		end
	end)
end

return InputController

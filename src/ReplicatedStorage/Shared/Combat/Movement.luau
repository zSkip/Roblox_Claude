--!strict
-- Velocity bursts for dodges and knockback. Must run on the machine that owns the assembly:
-- the player's client for their own character, the server for NPCs.

local Movement = {}

local function Attach(Root : BasePart) : Attachment
	local A = Instance.new("Attachment")
	A.Name = "MoveAttachment"
	A.Parent = Root
	return A
end

-- horizontal burst (dodge): keeps gravity free on Y
function Movement.Dash(Root : BasePart, Direction : Vector3, Speed : number, Duration : number)
	local Flat = Direction * Vector3.new(1, 0, 1)
	if Flat.Magnitude < 1e-3 then
		return
	end
	local Velocity = Flat.Unit * Speed
	local A = Attach(Root)
	local LV = Instance.new("LinearVelocity")
	LV.Attachment0 = A
	LV.RelativeTo = Enum.ActuatorRelativeTo.World
	LV.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	LV.PrimaryTangentAxis = Vector3.xAxis
	LV.SecondaryTangentAxis = Vector3.zAxis
	LV.PlaneVelocity = Vector2.new(Velocity.X, Velocity.Z)
	LV.MaxForce = 1e6
	LV.Parent = Root
	task.delay(Duration, function()
		LV:Destroy()
		A:Destroy()
	end)
end

-- continuous drive for forced movement: holds a horizontal velocity and a facing against any walk input
-- until Stop. Set steers it; a zero velocity holds the root still and keeps the last facing.
function Movement.Drive(Root : BasePart) : { Set : (Vector3) -> (), Stop : () -> () }
	local A = Attach(Root)
	local LV = Instance.new("LinearVelocity")
	LV.Attachment0 = A
	LV.RelativeTo = Enum.ActuatorRelativeTo.World
	LV.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	LV.PrimaryTangentAxis = Vector3.xAxis
	LV.SecondaryTangentAxis = Vector3.zAxis
	LV.PlaneVelocity = Vector2.zero
	LV.MaxForce = 1e6
	LV.Parent = Root
	local Align = Instance.new("AlignOrientation")
	Align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	Align.Attachment0 = A
	Align.MaxTorque = 1e6
	Align.Responsiveness = 30
	Align.CFrame = CFrame.lookAt(Vector3.zero, Root.CFrame.LookVector * Vector3.new(1, 0, 1))
	Align.Parent = Root
	return {
		Set = function(Velocity : Vector3)
			LV.PlaneVelocity = Vector2.new(Velocity.X, Velocity.Z)
			local Flat = Velocity * Vector3.new(1, 0, 1)
			if Flat.Magnitude > 1e-3 then
				Align.CFrame = CFrame.lookAt(Vector3.zero, Flat)
			end
		end,
		Stop = function()
			LV:Destroy()
			Align:Destroy()
			A:Destroy()
		end,
	}
end

-- full 3D burst (knockback)
function Movement.Knockback(Root : BasePart, Velocity : Vector3, Duration : number)
	local A = Attach(Root)
	local LV = Instance.new("LinearVelocity")
	LV.Attachment0 = A
	LV.RelativeTo = Enum.ActuatorRelativeTo.World
	LV.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	LV.VectorVelocity = Velocity
	LV.MaxForce = 1e6
	LV.Parent = Root
	task.delay(Duration, function()
		LV:Destroy()
		A:Destroy()
	end)
end

-- character-relative direction label -> world vector
function Movement.DirectionVector(Root : BasePart, Direction : string?) : Vector3
	local CF = Root.CFrame
	if Direction == "Front" then
		return CF.LookVector
	elseif Direction == "Left" then
		return -CF.RightVector
	elseif Direction == "Right" then
		return CF.RightVector
	end
	return -CF.LookVector -- Back / default
end

-- velocity that pushes Defender away from Attacker
function Movement.KnockbackVelocity(AttackerPos : Vector3, DefenderPos : Vector3, Spec : { [string]: any }) : Vector3
	local Away = (DefenderPos - AttackerPos) * Vector3.new(1, 0, 1)
	if Away.Magnitude < 1e-3 then
		Away = Vector3.new(0, 0, -1)
	end
	return Away.Unit * (Spec.Speed or 50) + Vector3.new(0, Spec.Up or 0, 0)
end

return Movement

--!strict
-- Builds and attaches a weapon model with Motor6Ds (no Tool class anywhere), after Nilociety's Tool6D.
-- Uses Schema.Model (a Model with a "Handle" part) if present, else builds one from Schema.ModelSpec.
-- Schema.Motors lists the links, one Motor6D each, so animations can pose every weapon part:
--   Motors = { { Part = "Handle", Body = "Right Arm", C0 = GripC0 }, { Part = "Scabbard", Body = "Left Arm" } }
-- Motors live in Weapon/Motors as "Link_<i>" (Part0 = body part, Part1 = weapon part, C0/C1 default identity).
-- The client tweens the Handle motor's C0 for procedural swings while animations are placeholders.

local WeaponModel = {}

export type Link = { Part : string, Body : string, C0 : CFrame?, C1 : CFrame? }

-- handle +Y points forward (-Z of the arm) from the bottom of the R6 arm
WeaponModel.GripC0 = CFrame.new(0, -1, 0) * CFrame.Angles(-math.pi / 2, 0, 0)

local function Part(Name : string, Size : Vector3, Color : Color3, Material : Enum.Material) : Part
	local P = Instance.new("Part")
	P.Name = Name
	P.Size = Size
	P.Color = Color
	P.Material = Material
	P.CanCollide = false
	P.CanTouch = false
	P.CanQuery = false
	P.Massless = true
	P.CastShadow = false
	return P
end

local function Build(Schema : { [string]: any }) : Model
	if typeof(Schema.Model) == "Instance" then
		local Clone = (Schema.Model :: Model):Clone()
		for _, D in Clone:GetDescendants() do
			if D:IsA("BasePart") then
				D.CanCollide = false
				D.CanTouch = false
				D.CanQuery = false
				D.Massless = true
				D.Anchored = false
			end
		end
		return Clone
	end

	local Spec = Schema.ModelSpec or {}
	local HandleSize : Vector3 = Spec.HandleSize or Vector3.new(0.3, 1, 0.3)
	local BladeSize : Vector3 = Spec.BladeSize or Vector3.new(0.2, 3.5, 0.5)

	local Model = Instance.new("Model")
	local Handle = Part("Handle", HandleSize, Spec.HandleColor or Color3.fromRGB(90, 60, 40), Enum.Material.Wood)
	Handle.Parent = Model

	local Guard = Part("Guard", Vector3.new(0.9, 0.15, 0.3), Color3.fromRGB(60, 60, 65), Enum.Material.Metal)
	Guard.Parent = Model
	local GW = Instance.new("WeldConstraint")
	Guard.CFrame = Handle.CFrame * CFrame.new(0, HandleSize.Y / 2, 0)
	GW.Part0, GW.Part1 = Handle, Guard
	GW.Parent = Guard

	local Blade = Part("Blade", BladeSize, Spec.BladeColor or Color3.fromRGB(200, 205, 215), Enum.Material.Metal)
	Blade.CFrame = Handle.CFrame * CFrame.new(0, HandleSize.Y / 2 + BladeSize.Y / 2, 0)
	Blade.Parent = Model
	local BW = Instance.new("WeldConstraint")
	BW.Part0, BW.Part1 = Handle, Blade
	BW.Parent = Blade

	Model.PrimaryPart = Handle
	return Model
end

-- R15 names for the R6 limbs a link may ask for
local R15Fallback = { ["Right Arm"] = "RightHand", ["Left Arm"] = "LeftHand", ["Torso"] = "UpperTorso" }

local function FindBodyPart(Character : Model, Name : string) : BasePart?
	for _, Candidate in { Name, R15Fallback[Name] } do
		local P = Character:FindFirstChild(Candidate)
		if P and P:IsA("BasePart") then
			return P
		end
	end
	return nil
end

-- Schema.Motors, else the legacy ModelSpec.Grip as a single Handle link
local function Links(Schema : { [string]: any }) : { Link }
	if Schema.Motors then
		return Schema.Motors
	end
	local Grip = Schema.ModelSpec and Schema.ModelSpec.Grip or "Right Arm"
	return { { Part = "Handle", Body = Grip, C0 = WeaponModel.GripC0 } }
end

-- clears Part0 / Part1 before destroying so the joint can't snap parts on the way out
local function ClearMotors(Model : Model)
	local Folder = Model:FindFirstChild("Motors")
	if not Folder then
		return
	end
	for _, Motor in Folder:GetChildren() do
		if Motor:IsA("Motor6D") then
			Motor.Part1 = nil
			Motor.Part0 = nil
			Motor:Destroy()
		end
	end
end

-- the Motor6D driving a weapon part ("Handle" by default), for procedural C0 tweens
function WeaponModel.GetMotor(Character : Model, PartName : string?) : Motor6D?
	local Model = Character:FindFirstChild("Weapon")
	local Folder = Model and Model:FindFirstChild("Motors")
	if not Folder then
		return nil
	end
	local Wanted = PartName or "Handle"
	for _, Motor in Folder:GetChildren() do
		if Motor:IsA("Motor6D") and Motor.Part1 and Motor.Part1.Name == Wanted then
			return Motor
		end
	end
	return nil
end

function WeaponModel.Detach(Character : Model)
	local Model = Character:FindFirstChild("Weapon")
	if Model and Model:IsA("Model") then
		ClearMotors(Model)
		Model:Destroy()
	end
end

-- returns the weapon model (named "Weapon") or nil if the rig lacks a linked body part
function WeaponModel.Attach(Character : Model, Schema : { [string]: any }) : Model?
	WeaponModel.Detach(Character)

	-- a Tool's RightGrip weld fights the Motor6D on the same arm
	for _, Arm in { "Right Arm", "RightHand" } do
		local Part = Character:FindFirstChild(Arm)
		local Grip = Part and Part:FindFirstChild("RightGrip")
		if Grip then
			Grip:Destroy()
		end
	end

	local Model = Build(Schema)
	Model.Name = "Weapon"
	local Folder = Instance.new("Folder")
	Folder.Name = "Motors"
	Folder.Parent = Model

	for Index, Link in Links(Schema) do
		local Part = Model:FindFirstChild(Link.Part, true)
		if not (Part and Part:IsA("BasePart")) then
			Model:Destroy()
			error(`[WeaponModel] {Schema.Id}: weapon part "{Link.Part}" (Motors[{Index}]) doesn't exist in the model`, 0)
		end
		local Body = FindBodyPart(Character, Link.Body)
		if not Body then
			Model:Destroy()
			warn(`[WeaponModel] {Character.Name} has no "{Link.Body}" (Motors[{Index}]); is the place set to R6?`)
			return nil
		end
		local Motor = Instance.new("Motor6D")
		Motor.Name = `Link_{Index}`
		Motor.Part0 = Body
		Motor.Part1 = Part
		Motor.C0 = Link.C0 or CFrame.identity
		Motor.C1 = Link.C1 or CFrame.identity
		Motor.Parent = Folder
	end

	-- removed some other way (respawn, Destroy on the model): drop the joints with it
	Model.Destroying:Connect(function()
		ClearMotors(Model)
	end)
	Model.Parent = Character
	return Model
end

return WeaponModel

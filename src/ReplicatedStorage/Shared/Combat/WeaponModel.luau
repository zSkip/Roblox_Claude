--!strict
-- Builds and attaches a weapon model with a Motor6D (no Tool class anywhere).
-- Uses Schema.Model (a Model with a "Handle" part) if present, else builds one from Schema.ModelSpec.
-- The client animates the "WeaponGrip" Motor6D's C0 for procedural swings while animations are placeholders.

local WeaponModel = {}

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

local function FindGripPart(Character : Model, Preferred : string?) : BasePart?
	for _, Name in { Preferred or "Right Arm", "Right Arm", "RightHand" } do
		local P = Character:FindFirstChild(Name)
		if P and P:IsA("BasePart") then
			return P
		end
	end
	return nil
end

-- returns the weapon model (named "Weapon") or nil if the rig has no grip part
function WeaponModel.Attach(Character : Model, Schema : { [string]: any }) : Model?
	local Existing = Character:FindFirstChild("Weapon")
	if Existing then
		Existing:Destroy()
	end
	local Grip = FindGripPart(Character, Schema.ModelSpec and Schema.ModelSpec.Grip)
	if not Grip then
		warn(`[WeaponModel] {Character.Name} has no Right Arm; is the place set to R6?`)
		return nil
	end
	local Model = Build(Schema)
	Model.Name = "Weapon"
	local Handle = Model:FindFirstChild("Handle") :: BasePart
	assert(Handle, "weapon model needs a part named Handle")

	local Motor = Instance.new("Motor6D")
	Motor.Name = "WeaponGrip"
	Motor.Part0 = Grip
	Motor.Part1 = Handle
	Motor.C0 = if Grip.Name == "RightHand" then CFrame.Angles(-math.pi / 2, 0, 0) else WeaponModel.GripC0
	Motor.Parent = Grip

	Model.Parent = Character
	return Model
end

return WeaponModel

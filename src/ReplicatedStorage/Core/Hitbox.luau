--!strict
-- Built-in HitboxQuery (core.contracts.interfaces §3). Works on client or server, no folder setup.
--   local Box = Hitbox.new()
--   Box.Hit:Connect(function(Model) ... end)      -- once per model per Start
--   Box:Start(FollowPart, { Size, Offset, Shape?, MinDot? }, { IgnoreInstances })
--   Box:Stop() / Box:Destroy()
-- Set Hitbox.Debug = true to draw the query volume.

local RunService = game:GetService("RunService")
local Signal = require(script.Parent.Signal)

local Hitbox = {}
Hitbox.__index = Hitbox
Hitbox.Debug = false

function Hitbox.new()
	local Params = OverlapParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	return setmetatable({
		Hit = Signal.new(),
		_params = Params,
		_tagged = {} :: { [Model]: boolean },
		_conn = nil :: RBXScriptConnection?,
	}, Hitbox)
end

local function ModelOf(Part : BasePart) : (Model?, Humanoid?)
	local Model = Part:FindFirstAncestorOfClass("Model")
	while Model do
		local Hum = Model:FindFirstChildOfClass("Humanoid")
		if Hum then
			return Model, Hum
		end
		Model = Model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

local function DrawDebug(CF : CFrame, Size : Vector3)
	local P = Instance.new("Part")
	P.Anchored = true
	P.CanCollide = false
	P.CanQuery = false
	P.CanTouch = false
	P.Transparency = 0.8
	P.Color = Color3.fromRGB(255, 60, 60)
	P.Material = Enum.Material.ForceField
	P.Size = Size
	P.CFrame = CF
	P.Parent = workspace
	task.delay(0.05, P.Destroy, P)
end

function Hitbox.Start(self : any, Follow : BasePart, Spec : { [string]: any }, Ignore : { Instance })
	self:Stop()
	table.clear(self._tagged)
	self._params.FilterDescendantsInstances = Ignore
	self._conn = RunService.PostSimulation:Connect(function()
		if not Follow.Parent then
			self:Stop()
			return
		end
		local CF = Follow.CFrame * (Spec.Offset or CFrame.new())
		if Hitbox.Debug then
			DrawDebug(CF, Spec.Size)
		end
		local Parts = if Spec.Shape == "Sphere"
			then workspace:GetPartBoundsInRadius(CF.Position, Spec.Size.X / 2, self._params)
			else workspace:GetPartBoundsInBox(CF, Spec.Size, self._params)
		for _, Part in Parts do
			local Model, Hum = ModelOf(Part)
			if Model and Hum and Hum.Health > 0 and not self._tagged[Model] then
				local Ok = true
				if Spec.MinDot and Model.PrimaryPart then
					local To = (Model.PrimaryPart.Position - Follow.Position) * Vector3.new(1, 0, 1)
					Ok = To.Magnitude < 1e-3 or Follow.CFrame.LookVector:Dot(To.Unit) >= Spec.MinDot
				end
				if Ok then
					self._tagged[Model] = true
					self.Hit:Fire(Model)
				end
			end
		end
	end)
end

function Hitbox.Stop(self : any)
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

function Hitbox.Destroy(self : any)
	self:Stop()
	self.Hit:DisconnectAll()
end

return Hitbox

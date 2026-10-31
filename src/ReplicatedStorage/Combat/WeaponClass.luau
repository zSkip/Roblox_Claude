--!strict
-- WeaponClass: the single dual-context weapon constructor (plan §5, goal G1).
-- Pure logic + signals only: no RunService:IsServer(), no Animator, no damage. The server and client
-- entry scripts connect to the signals and decide what each side does.
--
--   local Sword = WeaponClass.Define(Schema)          -- validates, deep-freezes, builds the attack registry
--   Sword:CreateState({ StateName = "Idle" }):BindFunction(Fn):MaidFunction(Fn)   -- builder sugar
--   local Rt = Sword:Instantiate(CharacterModel)      -- one runtime per owner, per side
--   Rt:SetState("Attacking", Context)  Rt:MatchAttack(Direction, Now)  Rt:Destroy()

local Signal = require(script.Parent.Parent.Core.Deps).Signal
local Attacks = require(script.Parent.Attacks)
local Directions = require(script.Parent.Directions)
local CombatEnums = require(script.Parent.CombatEnums)

export type Timeline = { Startup : number, Active : number, Recovery : number, Total : number }

local WeaponClass = {}
WeaponClass.Definitions = {} :: { [string]: any }
WeaponClass.DefaultStates = CombatEnums.StateNames

-- which states may start each action
WeaponClass.Allowed = table.freeze({
	Attack = table.freeze({ Idle = true }),
	Defend = table.freeze({ Idle = true }),
	Dodge = table.freeze({ Idle = true, Blocking = true }),
})

---------------------------------------------------------------- validation

local function Fail(Id : string, Message : string) : never
	error(`[WeaponClass] {Id}: {Message}`, 0)
end

local function CheckTiming(Id : string, Path : string, Spec : any)
	if type(Spec) ~= "table" then
		Fail(Id, `{Path} must be a table`)
	end
	for _, Field in { "Startup", "Active", "Recovery" } do
		local V = Spec[Field]
		if type(V) ~= "number" or V < 0 then
			Fail(Id, `{Path}.{Field} must be a number >= 0`)
		end
	end
	if Spec.Hitbox ~= nil then
		if typeof(Spec.Hitbox.Size) ~= "Vector3" then
			Fail(Id, `{Path}.Hitbox.Size must be a Vector3`)
		end
		if Spec.Hitbox.Offset ~= nil and typeof(Spec.Hitbox.Offset) ~= "CFrame" then
			Fail(Id, `{Path}.Hitbox.Offset must be a CFrame`)
		end
	end
	if Spec.Damage ~= nil and (type(Spec.Damage.Amount) ~= "number" or type(Spec.Damage.Type) ~= "string") then
		Fail(Id, `{Path}.Damage needs Type and Amount`)
	end
end

function WeaponClass.Validate(Schema : any)
	if type(Schema) ~= "table" or type(Schema.Id) ~= "string" or Schema.Id == "" then
		error("[WeaponClass] schema needs a string Id", 0)
	end
	local Id = Schema.Id
	if type(Schema.Damage) ~= "table" or type(Schema.Damage.Amount) ~= "number" then
		Fail(Id, "Damage = { Type, Amount } is required")
	end
	if type(Schema.Combo) ~= "table" or type(Schema.Combo.Attacks) ~= "table" or #Schema.Combo.Attacks == 0 then
		Fail(Id, "Combo.Attacks needs at least one attack")
	end
	if type(Schema.Combo.ResetTime) ~= "number" then
		Fail(Id, "Combo.ResetTime must be a number")
	end
	for I, Spec in Schema.Combo.Attacks do
		CheckTiming(Id, `Combo.Attacks[{I}]`, Spec)
	end
	for Dir, Spec in Schema.Directional or {} do
		if Directions.Ids[Dir] == nil then
			Fail(Id, `Directional.{tostring(Dir)} is not a direction`)
		end
		CheckTiming(Id, `Directional.{Dir}`, Spec)
	end
	for Name, Spec in Schema.FollowUps or {} do
		CheckTiming(Id, `FollowUps.{Name}`, Spec)
	end
	local Defense = Schema.Defense
	if type(Defense) ~= "table" then
		Fail(Id, "Defense is required")
	end
	for _, Field in { "ParryWindow", "ParryCooldown", "BlockDamageMultiplier", "DodgeIFrames", "DodgeDuration", "DodgeSpeed", "DodgeCooldown" } do
		if type(Defense[Field]) ~= "number" or Defense[Field] < 0 then
			Fail(Id, `Defense.{Field} must be a number >= 0`)
		end
	end
	if type(Schema.Timings) ~= "table" or type(Schema.Timings.DirectionalWindow) ~= "number" then
		Fail(Id, "Timings.DirectionalWindow is required")
	end
	if type(Schema.Stats) ~= "table" or type(Schema.Stats.MaxPosture) ~= "number" then
		Fail(Id, "Stats.MaxPosture is required")
	end
end

local function DeepFreeze(T : any)
	if type(T) ~= "table" or table.isfrozen(T) then
		return
	end
	for _, V in T do
		DeepFreeze(V)
	end
	table.freeze(T)
end

-- schema timings scaled by attack speed (> 1 = faster)
function WeaponClass.Timeline(Spec : { [string]: any }, AttackSpeed : number?) : Timeline
	local Speed = math.max(AttackSpeed or 1, 0.05)
	local Startup = Spec.Startup / Speed
	local Active = Spec.Active / Speed
	local Recovery = Spec.Recovery / Speed
	return { Startup = Startup, Active = Active, Recovery = Recovery, Total = Startup + Active + Recovery }
end

-- "M1.2" -> Animations.M1[2], "Directional.Front" -> Animations.Directional.Front
function WeaponClass.AnimationId(Schema : { [string]: any }, Key : string?) : string?
	if Key == nil then
		return nil
	end
	local Node : any = Schema.Animations
	for Part in string.gmatch(Key, "[^%.]+") do
		if type(Node) ~= "table" then
			return nil
		end
		Node = Node[tonumber(Part) or Part]
	end
	if type(Node) ~= "string" or Node == "rbxassetid://0" or Node == "" then
		return nil -- placeholder: no animation yet
	end
	return Node
end

---------------------------------------------------------------- State (per runtime)

local State = {}
State.__index = State

function State.new(Name : string)
	return setmetatable({
		Name = Name,
		IsActive = false,
		Entered = Signal.new(), -- (Runtime, Context)
		Exited = Signal.new(), -- (Runtime, Context, Reason)
	}, State)
end

function State.SetActive(self : any, Active : boolean, Runtime : any, Context : any?, Reason : string?)
	if self.IsActive == Active then
		return
	end
	self.IsActive = Active
	if Active then
		self.Entered:Fire(Runtime, Context)
	else
		self.Exited:Fire(Runtime, Context, Reason)
	end
end

---------------------------------------------------------------- Definition (blueprint, shared, frozen)

local Definition = {}
Definition.__index = Definition

function WeaponClass.Define(Schema : { [string]: any })
	WeaponClass.Validate(Schema)
	assert(WeaponClass.Definitions[Schema.Id] == nil, `duplicate weapon {Schema.Id}`)
	DeepFreeze(Schema)
	local self = setmetatable({
		Id = Schema.Id,
		Schema = Schema,
		Registry = Attacks.FromSchema(Schema),
		StateHooks = {} :: { [string]: { Enter : { any }, Exit : { any } } },
		Instantiated = Signal.new(), -- (Runtime)
	}, Definition)
	WeaponClass.Definitions[Schema.Id] = self
	return self
end

function WeaponClass.Get(Id : string?)
	return if Id then WeaponClass.Definitions[Id] else nil
end

-- test helper: forget a definition so a spec can define it again
function WeaponClass.Undefine(Id : string)
	WeaponClass.Definitions[Id] = nil
end

-- builder sugar (keeps the original API); hooks are copied into every runtime's states
function Definition.CreateState(self : any, Data : { StateName : string })
	local Hooks = self.StateHooks[Data.StateName]
	if not Hooks then
		Hooks = { Enter = {}, Exit = {} }
		self.StateHooks[Data.StateName] = Hooks
	end
	local Builder = {}
	function Builder.BindFunction(B, Fn)
		table.insert(Hooks.Enter, Fn)
		return B
	end
	function Builder.MaidFunction(B, Fn)
		table.insert(Hooks.Exit, Fn)
		return B
	end
	return Builder
end

---------------------------------------------------------------- Runtime (per owner, per side)

local Runtime = {}
Runtime.__index = Runtime

function Definition.Instantiate(self : any, Owner : any)
	local Rt = setmetatable({
		Definition = self,
		Schema = self.Schema,
		Owner = Owner,
		States = {} :: { [string]: any },
		Current = "Idle",
		Context = nil :: any,
		ActionId = 0,
		ComboIndex = 0,
		LastComboTime = -math.huge,
		Cooldowns = {} :: { [string]: number },
		StateChanged = Signal.new(), -- (NewState, OldState, Context)
		Destroyed = Signal.new(),
		Alive = true,
	}, Runtime)

	local Names = table.clone(WeaponClass.DefaultStates) :: { string }
	for Name in self.StateHooks do
		if not table.find(Names, Name) then
			table.insert(Names, Name)
		end
	end
	for _, Name in Names do
		local S = State.new(Name)
		local Hooks = self.StateHooks[Name]
		if Hooks then
			for _, Fn in Hooks.Enter do
				S.Entered:Connect(Fn)
			end
			for _, Fn in Hooks.Exit do
				S.Exited:Connect(Fn)
			end
		end
		Rt.States[Name] = S
	end
	Rt.States.Idle.IsActive = true -- starts idle without firing enter hooks

	self.Instantiated:Fire(Rt)
	return Rt
end

-- Always bumps ActionId so delayed callbacks from the previous action can tell they're stale.
-- Re-entering the same state (e.g. a second attack) fires Exited + Entered again.
function Runtime.SetState(self : any, Name : string, Context : any?, Reason : string?) : number
	assert(self.States[Name], `unknown state {Name}`)
	local Old = self.Current
	self.ActionId += 1
	self.States[Old]:SetActive(false, self, self.Context, Reason)
	self.Current = Name
	self.Context = Context
	self.States[Name]:SetActive(true, self, Context)
	self.StateChanged:Fire(Name, Old, Context)
	return self.ActionId
end

function Runtime.Is(self : any, Name : string) : boolean
	return self.Current == Name
end

function Runtime.CanStart(self : any, Action : string, Now : number) : boolean
	if not self.Alive then
		return false
	end
	local Allowed = WeaponClass.Allowed[Action]
	if not (Allowed and Allowed[self.Current]) then
		return false
	end
	return (self.Cooldowns[Action] or -math.huge) <= Now
end

function Runtime.SetCooldown(self : any, Action : string, Until : number)
	self.Cooldowns[Action] = Until
end

function Runtime.CooldownReady(self : any, Action : string, Now : number) : boolean
	return (self.Cooldowns[Action] or -math.huge) <= Now
end

-- index the next combo M1 would use, without advancing
function Runtime.PeekComboIndex(self : any, Now : number) : number
	local Combo = self.Schema.Combo
	local Index = self.ComboIndex
	if Now - self.LastComboTime > Combo.ResetTime then
		Index = 0
	end
	return Index % #Combo.Attacks + 1
end

function Runtime.NextComboIndex(self : any, Now : number) : number
	self.ComboIndex = self:PeekComboIndex(Now)
	self.LastComboTime = Now
	return self.ComboIndex
end

-- Finds the attack for an M1 press. Advances the combo only when a combo attack is chosen
-- (directional M1s mix freely without resetting the chain). StateOverride lets the server pass
-- "FollowUp" during a perfect-dodge window.
function Runtime.MatchAttack(self : any, Direction : string?, Now : number, StateOverride : string?, Button : string?)
	local Def = self.Definition.Registry:Match({
		Button = Button or "M1",
		Direction = Direction :: any,
		State = StateOverride or self.Current,
		ComboIndex = self:PeekComboIndex(Now),
	})
	if Def and Def.Kind == "Combo" then
		self:NextComboIndex(Now)
	end
	return Def
end

function Runtime.Destroy(self : any)
	if not self.Alive then
		return
	end
	self.Alive = false
	self.States[self.Current]:SetActive(false, self, self.Context, "Destroyed")
	self.Destroyed:Fire()
	for _, S in self.States do
		S.Entered:DisconnectAll()
		S.Exited:DisconnectAll()
	end
	self.StateChanged:DisconnectAll()
end

return WeaponClass

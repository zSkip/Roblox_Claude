--!strict
-- Modular AttackDef registry. Every attack (combo M1s, directional M1s, follow-ups, future specials)
-- is data with an input pattern; matching is pure so it can be unit-tested and shared by both sides.
--
--   local Registry = Attacks.NewRegistry()
--   Registry:Register(Def)
--   Registry:Match({ Button = "M1", Direction = "Back", State = "Idle", ComboIndex = 2 }) -> AttackDef?
--   Attacks.FromSchema(Schema) -> Registry   -- builds the defs of a weapon schema
--
-- Input pattern rules:
--   Button         must be equal
--   Direction      nil = only without a direction, "Any" = with or without, otherwise equal
--   RequiresState  nil = any state, otherwise the query's State must be equal
--   ComboIndex     nil = any, otherwise the query's (next) ComboIndex must be equal
-- Highest Priority wins; equal priorities keep registration order.

local Directions = require(script.Parent.Directions)

type Direction = Directions.Direction

export type InputPattern = {
	Button : string,
	Direction : (Direction | "Any")?,
	RequiresState : string?,
	ComboIndex : number?,
}

export type AttackDef = {
	Id : string,
	Input : InputPattern,
	Target : string?,           -- limb group key, nil = no limb meter
	ExhaustionStacks : number?, -- overrides the default stack cost
	Priority : number?,
	Kind : string?,             -- "Combo" | "Directional" | "FollowUp" | ...
	Spec : { [string]: any },   -- timings, damage, posture, hitbox, knockback...
}

export type Query = {
	Button : string,
	Direction : Direction?,
	State : string?,
	ComboIndex : number?,
}

local Attacks = {}

local Registry = {}
Registry.__index = Registry

export type Registry = typeof(setmetatable({} :: {
	Defs : { AttackDef },
	ById : { [string]: AttackDef },
	Order : { [AttackDef]: number },
}, Registry))

function Attacks.NewRegistry() : Registry
	return setmetatable({ Defs = {}, ById = {}, Order = {} }, Registry)
end

local function Validate(Def : AttackDef)
	assert(type(Def.Id) == "string" and Def.Id ~= "", "AttackDef needs an Id")
	assert(type(Def.Input) == "table" and type(Def.Input.Button) == "string", `AttackDef {Def.Id} needs Input.Button`)
	local Dir = Def.Input.Direction
	assert(Dir == nil or Dir == "Any" or Directions.Ids[Dir] ~= nil, `AttackDef {Def.Id} has an unknown direction {tostring(Dir)}`)
	assert(type(Def.Spec) == "table", `AttackDef {Def.Id} needs a Spec`)
end

function Registry.Register(self : Registry, Def : AttackDef) : AttackDef
	Validate(Def)
	assert(self.ById[Def.Id] == nil, `duplicate AttackDef {Def.Id}`)
	if not table.isfrozen(Def.Input) then
		table.freeze(Def.Input)
	end
	if not table.isfrozen(Def) then
		table.freeze(Def)
	end
	self.ById[Def.Id] = Def
	table.insert(self.Defs, Def)
	self.Order[Def] = #self.Defs
	local Order = self.Order
	table.sort(self.Defs, function(A, B)
		local PA, PB = A.Priority or 0, B.Priority or 0
		if PA ~= PB then
			return PA > PB
		end
		return Order[A] < Order[B]
	end)
	return Def
end

function Registry.Get(self : Registry, Id : string) : AttackDef?
	return self.ById[Id]
end

function Attacks.Matches(Input : InputPattern, Query : Query) : boolean
	if Input.Button ~= Query.Button then
		return false
	end
	if Input.Direction ~= "Any" and Input.Direction ~= Query.Direction then
		return false
	end
	if Input.RequiresState ~= nil and Input.RequiresState ~= Query.State then
		return false
	end
	if Input.ComboIndex ~= nil and Input.ComboIndex ~= Query.ComboIndex then
		return false
	end
	return true
end

function Registry.Match(self : Registry, Query : Query) : AttackDef?
	for _, Def in self.Defs do
		if Attacks.Matches(Def.Input, Query) then
			return Def
		end
	end
	return nil
end

-- Builds the registry of a weapon schema (plan §4):
--   Combo.Attacks[i]       -> "<Id>.M1.<i>"          Button M1, no direction, ComboIndex i
--   Directional[Dir]       -> "<Id>.Directional.<Dir>" Button M1, Direction Dir, Target from LimbTargets
--   FollowUps[Name]        -> "<Id>.FollowUp.<Name>"  Input given by the spec (default M1, Any, RequiresState "FollowUp")
--   Attacks (list)         -> custom AttackDefs, registered as-is
-- Every spec without its own Damage inherits Schema.Damage.
function Attacks.FromSchema(Schema : { [string]: any }) : Registry
	local Reg = Attacks.NewRegistry()
	local Id = Schema.Id :: string
	local DefaultDamage = Schema.Damage

	local function WithDefaults(Spec : { [string]: any }) : { [string]: any }
		local Copy = table.clone(Spec)
		if Copy.Damage == nil then
			Copy.Damage = DefaultDamage
		end
		return Copy
	end

	if Schema.Combo then
		for Index, Spec in Schema.Combo.Attacks do
			Reg:Register({
				Id = `{Id}.M1.{Index}`,
				Kind = "Combo",
				Input = { Button = "M1", ComboIndex = Index },
				Target = Spec.Target,
				Spec = WithDefaults(Spec),
			})
		end
	end

	if Schema.Directional then
		for _, Dir in Directions.Names do
			local Spec = Schema.Directional[Dir]
			if Spec then
				Reg:Register({
					Id = `{Id}.Directional.{Dir}`,
					Kind = "Directional",
					Input = { Button = "M1", Direction = Dir },
					Target = Spec.Target or (Schema.LimbTargets and Schema.LimbTargets[Dir]),
					Spec = WithDefaults(Spec),
				})
			end
		end
	end

	if Schema.FollowUps then
		local Names = {}
		for Name in Schema.FollowUps do
			table.insert(Names, Name)
		end
		table.sort(Names)
		for _, Name in Names do
			local Spec = Schema.FollowUps[Name]
			Reg:Register({
				Id = `{Id}.FollowUp.{Name}`,
				Kind = "FollowUp",
				Input = Spec.Input or { Button = "M1", Direction = "Any", RequiresState = "FollowUp" },
				Target = Spec.Target,
				Priority = Spec.Priority or 10,
				Spec = WithDefaults(Spec),
			})
		end
	end

	if Schema.Attacks then
		for _, Def in Schema.Attacks do
			Reg:Register(table.clone(Def))
		end
	end

	return Reg
end

return table.freeze(Attacks)

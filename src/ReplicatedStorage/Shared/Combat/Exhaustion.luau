--!strict
-- Pure in-combat exhaustion stack math. The caller passes `Now`; no clocks or Instances inside.

export type Config = {
	M1sPerStack : number,      -- every N M1s add one regular stack (1-3)
	HeavyStack : number,       -- stacks added by a knockback attack
	Threshold : number,        -- stacks at which the Exhausted debuff starts
	MaxStacks : number,
	MaxIntensity : number,
	OutOfCombatDelay : number, -- seconds without combat before decay starts
	DecayInterval : number,    -- seconds per stack lost while out of combat
}

export type State = {
	Stacks : number,
	M1Counter : number,
	InCombatUntil : number,
	LastDecay : number,
}

local Exhaustion = {}

Exhaustion.DefaultConfig = table.freeze({
	M1sPerStack = 2,
	HeavyStack = 3,
	Threshold = 6,
	MaxStacks = 15,
	MaxIntensity = 10,
	OutOfCombatDelay = 4,
	DecayInterval = 1,
} :: Config)

function Exhaustion.New() : State
	return { Stacks = 0, M1Counter = 0, InCombatUntil = -math.huge, LastDecay = -math.huge }
end

local function MarkCombat(State : State, Config : Config, Now : number)
	State.InCombatUntil = Now + Config.OutOfCombatDelay
	State.LastDecay = State.InCombatUntil
end

-- keeps the owner in combat without adding stacks (e.g. taking a hit)
function Exhaustion.Touch(State : State, Config : Config, Now : number)
	MarkCombat(State, Config, Now)
end

function Exhaustion.Add(State : State, Config : Config, Amount : number, Now : number)
	MarkCombat(State, Config, Now)
	State.Stacks = math.clamp(State.Stacks + Amount, 0, Config.MaxStacks)
end

-- call once per M1 (combo or directional); returns true when a stack was added
function Exhaustion.OnM1(State : State, Config : Config, Now : number) : boolean
	MarkCombat(State, Config, Now)
	State.M1Counter += 1
	if State.M1Counter >= Config.M1sPerStack then
		State.M1Counter = 0
		Exhaustion.Add(State, Config, 1, Now)
		return true
	end
	return false
end

function Exhaustion.OnKnockback(State : State, Config : Config, Now : number)
	Exhaustion.Add(State, Config, Config.HeavyStack, Now)
end

-- out-of-combat decay; call from a periodic loop
function Exhaustion.Tick(State : State, Config : Config, Now : number)
	if Now < State.InCombatUntil or State.Stacks <= 0 then
		return
	end
	local Steps = math.floor((Now - State.LastDecay) / Config.DecayInterval)
	if Steps > 0 then
		State.Stacks = math.max(0, State.Stacks - Steps)
		State.LastDecay += Steps * Config.DecayInterval
		State.M1Counter = 0
	end
end

-- 0 = no debuff; otherwise the Exhausted intensity level
function Exhaustion.Intensity(State : State, Config : Config) : number
	return math.clamp(State.Stacks - Config.Threshold + 1, 0, Config.MaxIntensity)
end

return table.freeze(Exhaustion)

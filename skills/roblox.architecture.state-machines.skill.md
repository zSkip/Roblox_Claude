---
name: roblox.architecture.state-machines
description: State machines for Roblox/Luau games - vocabulary (state, event, transition, guard, action, entry/exit, self/targetless/delayed transitions, run-to-completion), flat FSM vs hierarchical (HSM/statechart) vs parallel regions vs history, five implementation styles (enum+if, allowed table, transition table, state objects, polled transitions, event-driven statechart), the RobloxStateMachine (prooheckcp) and Arch (bohraz) libraries with their real APIs and gotchas, combat patterns (action gating, timed states without stale task.delay, input buffering as its own machine, status effects as an orthogonal layer, server authority + client mirror, cancel windows), a dependency-free Luau statechart reference, testing and pitfalls. Use when designing or refactoring states, transitions, keybind/input flow, stuns, or AI behaviour.
---

# State machines in Roblox / Luau

Sources:
- DevForum "State machines // In-Depth Tutorial" (Grandpa_Cheese, 2024). Conceptual, no code.
- DevForum "How to implement / create a state machine?" (topic 452338, 2020). A combat-flowchart discussion.
- `prooheckcp/RobloxStateMachine` (GitHub, source read).
- DevForum "Arch - a powerful hierarchical state machine library" (bohraz, docs at bohraz.github.io/Arch). SCXML-inspired.

This project's own code and plan are in §8 and `docs/state-machine-refactor.md`.

## 1. Vocabulary

| Term | Meaning |
|---|---|
| **State** | A mode the object is in (`Idle`, `Attacking`). It decides which events mean something right now |
| **Event** | Something that happened (`AttackPressed`, `Hit`, `TimerElapsed`). Events are inputs. States are not set from outside |
| **Transition** | `source --event [guard] / actions--> target` |
| **Guard** | A pure predicate that must be true for the transition to be taken (`cooldownReady`, `not Disarmed`) |
| **Action** | A side effect run *during* the transition (play anim, start hitbox, send packet) |
| **Entry / exit** | Actions that always run when entering or leaving a state, whichever transition caused it. Use them for setup and teardown (connections, hitboxes, attributes) |
| **Self transition** | `A → A`: exits and re-enters (restarts timers). Arch supports it explicitly |
| **Targetless (internal)** | Only runs actions. The state doesn't change and entry/exit don't run |
| **Delayed (`after`)** | Taken automatically after N seconds unless the state is left first. Arch: `after = { target, delay }` |
| **Final state** | Terminal (`Dead`) |
| **Run-to-completion** | One event is fully processed (exits → actions → entries) before the next is handled. Events raised during processing are queued, never handled re-entrantly |
| **Macrostep / microstep** | Arch/SCXML terms: one external event (macrostep) can cause several internal transitions (microsteps) |

**Rule of thumb from the 2020 thread:** "check state before every action" is the minimum. It becomes a state machine once the *rules* (which events each state accepts, and where they lead) live in one table instead of in `if` chains spread over handlers.

## 2. Flat FSM vs hierarchy vs parallel

**Flat FSM:** exactly one active state. It's fine for <8 states. Rules then duplicate ("every disabled state ignores input", "every state goes to Dead on death").

**Hierarchical (HSM / statechart):** states nest. A compound state has exactly one active child and must name an `initial` child. A transition declared on a parent applies to every descendant, so `Died` is declared once on the root.
- Exiting a parent exits all descendants. Moving between children doesn't exit the parent (Arch reply #13: "whether you're running or walking, you'll still be grounded").
- The active configuration is a *path*: `Combat.Committed.Attacking.Windup`. Checking "am I in any Committed state" is a prefix test.

**Parallel (orthogonal) regions:** a parallel state enters *all* its children at once, and each runs its own transitions for every event. They are processed serially in a fixed order, which is not threading. Use regions for concerns that change independently: `Action` × `Stance` × `Input buffer`.
- A transition from inside a region to a target outside the parallel state exits all regions.

**History:** `history = "shallow"` re-enters the last active child, and `"deep"` re-enters the last active leaf configuration. `initial` is still needed for the first entry. Example: a stun inside `Blocking.Holding` returns to `Blocking` instead of `Idle`.

**State explosion test:** if you're about to add `AttackingWhileSlowed` or `BlockingExhausted`, you need either a parallel region or a *modifier/effect* (see §6.4), not a new state.

## 3. Implementation styles (from simplest)

### 3.1 Enum + if (the tutorial's combat example)
```luau
if State == "Idle" or State == "Walk" then Attack() end
```
This is a guard in disguise. It's OK for prototypes, but the rules end up scattered across every handler.

### 3.2 Allowed table (what this repo does today: `WeaponClass.Allowed`)
```luau
local Allowed = { Attack = { Idle = true }, Dodge = { Idle = true, Blocking = true } }
if Allowed[Action][State] then ... end
```
This centralises *who may start what*. It doesn't say where you go, when you leave or what happens on the way. Those parts stay in handlers and `task.delay`s.

### 3.3 Transition table (adjacency, reply #8b of the 2020 thread)
```luau
local T = {
	Idle      = { AttackPressed = "Attacking", DefendPressed = "Blocking", DodgePressed = "Dodging" },
	Attacking = { Recovered = "Idle", Hit = "Stunned" },
}
local Next = T[State][Event]  -- nil = event ignored in this state
```
The state graph is fully visible here, and you can unit-test it as data. Add guards and actions by making the value a table (§7).

### 3.4 State objects (OOP, reply #8a / RobloxStateMachine)
Each state is a module with `OnEnter`, `OnLeave`, `OnHeartbeat` and `CanChangeState`. It's good for NPC AI where states own per-frame behaviour. The risk is that transitions get hidden inside state code (`self:ChangeState("X")` from anywhere).

### 3.5 Polled transitions (RobloxStateMachine)
A transition object returns `true` from a per-frame predicate to fire. It's simple for AI ("player within 20 studs"), but it's wasteful and laggy for input-driven combat. Every combatant pays a cost per transition per frame.

### 3.6 Event-driven statechart (Arch / SCXML / XState)
A declarative definition table with `events`, `guards`, `actions`, `after`, nested `states`, `parallel` and `history`. Events are sent with `Send`. This is the best fit for combat: input, hits and timers are all *events*, and the definition table is data you can validate, test and extend per weapon.

## 4. RobloxStateMachine (prooheckcp)

Install: Wally `prooheckcp/robloxstatemachine`, or the model asset. Exports `State`, `Transition` and the `RobloxStateMachine` type.

```luau
local SM = require(ReplicatedStorage.RobloxStateMachine)
local States = SM:LoadDirectory(script.States)          -- requires every ModuleScript descendant, cached per folder
local Machine = SM.new("Idle", States, { Target = nil }) -- (initialState, {State}, initialData?); also SM(...)
```

| Machine API | Notes |
|---|---|
| `GetCurrentState()`, `GetPreviousState()` | Names. Previous is `""` until the first change |
| `ChangeState(name)` | Forced, but still asks the current state's `CanChangeState(name)` |
| `GetData()` / `ChangeData(key, value)` | Only `ChangeData` fires `DataChanged` and the state's `OnDataChanged`. Direct writes are silent |
| `StateChanged(new, prev)`, `DataChanged(data, key, new, old)` | Signals. `StateChanged` does **not** fire for the initial state |
| `Destroy()` | Calls `OnLeave` on the current state, `OnDestroy` on every state/transition, and disconnects Heartbeat |

**State** (`State.new("Name")`, or `Parent:Extend("Name")` for inheritance): `Transitions = { ... }`. The hooks are `OnInit(data)`, `OnEnter(data)` (deferred), `OnLeave(data)` (spawned), `OnHeartbeat(data, dt)`, `OnDataChanged(...)`, `CanChangeState(target) -> bool` (gates every change *away* from the state) and `OnDestroy()`. A state can call `self:ChangeState`, `self:ChangeData` and `self:GetState`.

**Transition** (`Transition.new("TargetState")`): `OnDataChanged(data) -> bool` is **polled every Heartbeat**, despite its name. Returning true moves to `TargetState`. It also has `OnEnter` / `OnLeave` (when the owning state is entered or left). `CanChangeState(data)` is deprecated but still checked first.

Gotchas:
- Each frame the **first matching transition wins**, but transitions are iterated as a name-keyed dictionary, so the **order is undefined**. There are no priorities, cooldowns or timed transitions.
- Hooks run in `task.spawn` / `task.defer`. `OnEnter` happens a frame later, and errors don't stop the loop, but they also don't surface where you expect them.
- `LoadDirectory` returns States **and** Transitions in one array, and `new` doesn't filter by `.Type`. Keep transitions in a separate folder, or filter on `Type == "State"`.
- There's no hierarchy or parallel states. One machine per concern.
- A new state's `OnHeartbeat` starts the frame after the transition.

Best for: NPC/boss AI with per-frame behaviour (chase, strafe, flee) on a handful of NPCs. Not for: authoritative player combat with many actors and input events.

## 5. Arch (bohraz), a hierarchical state machine

Install: Wally `bohraz/arch`, or the `.rbxm` on the DevForum post. The Creator Store model was moderated in Jan 2025. The lifecycle and API docs pages are mostly empty, so verify any ordering against the source.

```luau
local Machine = Arch.createMachine({
	id = "Combat",
	initial = "Neutral",
	states = {
		Neutral = {
			initial = "Idle",
			states = {
				Idle = { events = { Attack = { { target = "Attacking", guards = { "canAttack" }, actions = { "startSwing" } } } } },
				Blocking = { events = { DefendUp = "Idle" } },        -- shorthand form
			},
			events = { DefendDown = "Neutral.Blocking" },
		},
		Attacking = {
			janitor = true,                                       -- context.janitor, cleaned on exit
			OnEntry = function(context) end,
			OnExit = function(context) end,
			events = { after = { target = "Neutral", delay = 0.6 } },
		},
		Stunned = { events = { after = { target = "Neutral", delay = 0.4 } } },
	},
	events = { Hit = "Stunned" },                                 -- root-level: applies everywhere
}, {
	context = { },                                                -- passed to guards/actions/OnEntry/OnExit
	guards = { canAttack = function(context) return true end },
	actions = { startSwing = function(context) end },
	debugMode = false, maxLogs = 30, logTime = false,
})
Machine:Send("Attack")
```

| Feature | Arch |
|---|---|
| Transition forms | `Event = "Target"`, `{ target = ... }`, or a list of `{ target, guards, actions }` (tried in order, first whose guards pass wins) |
| Targetless / self | No `target` means only actions run. `target = <self>` exits and re-enters |
| Delayed | `after = { target, delay }`, cancelled if another transition fires first |
| Parallel | `parallel = true` (no `initial`). Children process each event in a fixed serial order |
| History | `history = "shallow" | "deep"`, plus `initial` |
| Context | 1st argument to guards/actions/hooks: `context.Send(event)` (the right way to raise events from inside), `context.event`, `context.janitor` |
| Inspect | `machine.configuration` (active states, `[1]` = deepest, `.id`), `machine.value` (active leaf per region), `machine.history` (last microstep), `machine.onTransition:Connect(function(data) end)`, `Arch.getMachine(id)` |

Gotchas from the thread:
- There's no built-in per-frame "activity". Connect Heartbeat in `OnEntry` and add it to `context.janitor`.
- `janitor = true` only cleans when *that* state exits. A child needing cleanup sets its own `janitor = true`.
- Guards go on transitions, not on `OnEntry`/`OnExit`. The author prefers transition actions over entry/exit when you need control.
- One state per ModuleScript, imported into the definition, is the recommended way to scale.
- There's no built-in "is state X active?" helper. Scan `configuration` for the id.

## 6. Combat patterns

### 6.1 Gate actions through the machine, not through handlers
Input handlers only **send events**. The machine decides. An event with no transition in the current configuration is ignored, which *is* the gate. Replace `if State == "Idle" then Attack()` with `Machine:Send("AttackPressed", Dir)`, and ask `Machine:Can("AttackPressed")` when the UI needs to know.

### 6.2 Timed states without stale callbacks
`task.delay(d, function() if Runtime.ActionId == Id then ... end end)` works but spreads lifetimes everywhere. Prefer `after` transitions owned by the state: leaving the state cancels the timer (store the `task.delay` thread and `task.cancel` it on exit, or use a token the exit invalidates). With a single scheduler (one Heartbeat checking deadlines), attack speed can also change mid-swing.

### 6.3 Sub-phases as child states
`Attacking.{Windup, Active, Recovery}` turns frame data into states. Cancel windows and feints become transitions on the right child (`Windup: Feint → Neutral`, `Recovery: Dodge → Dodging [cancelWindow]`). Hitboxes start in `Active` entry and stop on `Active` exit, so interruptions clean up for free.

### 6.4 Status effects are an orthogonal layer, not states
Effects overlap (slowed + exhausted + disarmed), so modelling them as action states explodes. Keep them in a `StatusController` (set semantics, durations, stacks). Connect it to the action chart in two ways:
- **Guards:** `canAttack = not Status:Has("Disarm")`, `canMove = Status:Can("Move")`.
- **Events:** the first lock-tier effect raises `Disabled` (chart → `Disabled.Hitstun`, ...). The last one ending raises `Recovered`.

The chart owns *what you are doing*. Effects own *what is modifying you*.

### 6.5 Input is its own small machine
Keep these off the combat chart: the directional tap buffer, the M1 pressed while busy, and tap-vs-hold on F. Model them as a client `InputChart`:
- `Ready ⇄ DirectionBuffered (after DirectionalWindow → Ready)`
- `Ready → AttackQueued (after InputBuffer → Ready)`
- `DefendHeld`

It emits intent events only when the mirrored combat state can accept them.

Keybinds are a table: `KeyCode/UserInputType → InputEvent`. The chart never sees a KeyCode. That makes rebinding and gamepad support data-only. ContextActionService bind/unbind per state (reply #12 of the 2020 thread) is the engine-level version of the same idea.

### 6.6 Server authority, client mirror
- **Server:** runs the authoritative chart per combatant and broadcasts the leaf state id + context.
- **Client:** for its own character, runs the *same* chart definition, but with server events applied as forced sync (`Sync(stateId)`). Locally it only uses `Can(event)` to decide whether to send or buffer, and entry actions for animation and FX. Never trust the client's chart for damage.
- **Shared definition:** one table, side-specific actions bound at construction (server: hitbox validation, broadcast; client: animation, camera). That keeps shared code free of `IsServer`.

### 6.7 Forced transitions
`Hit`, `Parried`, `GuardBreak`, `Knockback` and `Died` are declared on the root (or on a `Vulnerable` parent), so every state handles them without per-state code. Invulnerability is a guard on those transitions (`not Status:Has("Invulnerable")`).

## 7. Dependency-free Luau statechart (reference)

Small enough to own (fits `core.contracts.interfaces`: no third-party). It supports nesting, guards, actions, entry/exit, `after`, run-to-completion and `Can`. Leave parallel regions to separate machines unless needed.

```luau
--!strict
export type Transition = { Target : string?, Guard : ((Ctx : any, Payload : any) -> boolean)?, Actions : { (Ctx : any, Payload : any) -> () }? }
export type StateDef = {
	Initial : string?, States : { [string]: StateDef }?,
	On : { [string]: string | Transition | { Transition } }?,
	After : { Delay : number | (Ctx : any) -> number, Target : string }?,
	Entry : ((Ctx : any, Payload : any) -> ())?, Exit : ((Ctx : any) -> ())?,
}

local Chart = {} ; Chart.__index = Chart

-- Flatten "A.B.C" paths: Index[path] = { Def, Parent }
local function Index(Def : StateDef, Path : string, Parent : string?, Out : { [string]: any })
	Out[Path] = { Def = Def, Parent = Parent }
	for Name, Child in Def.States or {} do Index(Child, `{Path}.{Name}`, Path, Out) end
	return Out
end

function Chart.new(Root : StateDef, Ctx : any, Now : () -> number)
	local self = setmetatable({ Nodes = Index(Root, "Root", nil, {}), Ctx = Ctx, Now = Now,
		Active = {} :: { string }, Queue = {} :: { any }, Busy = false, Deadline = nil :: number?, DeadlineTarget = nil :: string?,
		Changed = nil :: ((Leaf : string, Old : string) -> ())? }, Chart)
	self:_EnterDown("Root", nil)
	return self
end

function Chart:Leaf() : string return self.Active[#self.Active] end
function Chart:In(Path : string) : boolean return table.find(self.Active, "Root." .. Path) ~= nil end

-- first transition for Event from the deepest active state upwards
function Chart:_Find(Event : string, Payload : any) : (Transition?, string?)
	for I = #self.Active, 1, -1 do
		local On = self.Nodes[self.Active[I]].Def.On
		local Entry = On and On[Event]
		if Entry then
			local List = if type(Entry) == "string" then { { Target = Entry } } elseif Entry[1] then Entry else { Entry }
			for _, T in List :: { Transition } do
				if not T.Guard or T.Guard(self.Ctx, Payload) then return T, self.Active[I] end
			end
		end
	end
	return nil, nil
end

function Chart:Can(Event : string, Payload : any?) : boolean
	return (self:_Find(Event, Payload)) ~= nil
end

function Chart:Send(Event : string, Payload : any?)
	table.insert(self.Queue, { Event, Payload })
	if self.Busy then return end                    -- run-to-completion: queued, handled after the current one
	self.Busy = true
	while #self.Queue > 0 do
		local Item = table.remove(self.Queue, 1)
		local T, Source = self:_Find(Item[1], Item[2])
		if T then self:_Take(T, Source :: string, Item[2]) end
	end
	self.Busy = false
end

function Chart:_Take(T : Transition, Source : string, Payload : any)
	local Old = self:Leaf()
	if T.Target then
		local Target = "Root." .. T.Target
		-- exit up to the common ancestor (exclusive); a self transition exits Source too
		local Common = self.Nodes[Source].Parent
		local Walk : string? = Target
		while Walk do
			if table.find(self.Active, Walk) and Walk ~= Target then Common = Walk ; break end
			Walk = self.Nodes[Walk].Parent
		end
		while #self.Active > 0 and self:Leaf() ~= Common do
			local Exiting = table.remove(self.Active) :: string
			local Exit = self.Nodes[Exiting].Def.Exit
			if Exit then Exit(self.Ctx) end
		end
		self.Deadline = nil
		for _, A in T.Actions or {} do A(self.Ctx, Payload) end
		-- enter from below Common down to Target, then Target's initial children
		local Chain, Node = {}, Target
		while Node and Node ~= Common do table.insert(Chain, 1, Node) ; Node = self.Nodes[Node].Parent end
		for I, Path in Chain do
			if I < #Chain then self:_EnterOne(Path, Payload) else self:_EnterDown(Path, Payload) end
		end
	else
		for _, A in T.Actions or {} do A(self.Ctx, Payload) end  -- targetless
	end
	if self.Changed and self:Leaf() ~= Old then self.Changed(self:Leaf(), Old) end
end

function Chart:_EnterOne(Path : string, Payload : any)
	table.insert(self.Active, Path)
	local Def = self.Nodes[Path].Def
	if Def.Entry then Def.Entry(self.Ctx, Payload) end
	if Def.After then
		local D = Def.After.Delay
		self.Deadline = self.Now() + (if type(D) == "function" then D(self.Ctx) else D)
		self.DeadlineTarget = Def.After.Target
	end
end

function Chart:_EnterDown(Path : string, Payload : any)
	self:_EnterOne(Path, Payload)
	local Def = self.Nodes[Path].Def
	if Def.Initial then self:_EnterDown(`{Path}.{Def.Initial}`, nil) end
end

-- one scheduler calls this for every chart (Heartbeat), instead of task.delay per action
function Chart:Step()
	if self.Deadline and self.Now() >= self.Deadline then
		local Target = self.DeadlineTarget :: string
		self.Deadline = nil
		self:_Take({ Target = Target }, self:Leaf(), nil)
	end
end

return Chart
```

Notes on this sketch:
- It keeps one deadline, owned by the deepest state with `After`. Leaving that state clears it (`self.Deadline = nil` on any targeted transition). Nested timers need a deadline per active state.
- `Step` takes the `after` transition directly. Call it from one Heartbeat loop, never re-entrantly inside `Send`.
- In tests, pass `Now` as a fake clock, call `Step()` manually and assert on `Leaf()`.

## 8. This repo today (V2)

| Concern | Where | Style |
|---|---|---|
| Action state | `WeaponClass` Runtime: `Current`, `SetState(Name, Context)`, `States[Name].Entered/Exited`, `ActionId` | Flat FSM. Anyone may `SetState` anything |
| Who may start what | `WeaponClass.Allowed` + `Runtime:CanStart(Action, Now)` + cooldowns | Allowed table (§3.2) |
| Timing / exits | `CombatService.After(C, Id, Delay, Fn)` → `ToNeutral` | `task.delay` + ActionId staleness check |
| Neutral choice | `ToNeutral`: Blocking if `C.Holding`, else Idle | Implicit history |
| Hidden sub-states | `C.FollowUpUntil`, `C.IFramesUntil`, `C.ParryStart`, `C.Holding`, combo index/time | Timestamps and flags beside the FSM |
| Attack phases | `Timeline` numbers, used by `LockProfile`, client hitbox `task.delay`s | Not states |
| Client input | `InputController`: `Buffered`, `Pending`, `CombatController.State == "Idle"` checks | if/else + module locals |
| Lock | `LockProfile.States[state]` + timeline sampling | Table per state (good: data) |

The refactor plan that moves this onto a statechart is in `docs/state-machine-refactor.md`.

## 9. Testing state machines

- **Table-driven transition tests:** for each `(state, event, guardContext)`, assert the resulting leaf. Generate them from the definition so new states can't go untested.
- **Fake clock + manual `Step()`:** never `task.wait` in specs.
- **Invariants:** exactly one leaf per region; `Dead` has no outgoing transitions; every compound has a valid `Initial`; every `Target` resolves; every event name used by input/net exists somewhere in the chart.
- **Interruptions:** enter `Attacking.Active`, send `Hit`, and assert that `Active.Exit` ran (hitbox stopped) and the timer was cancelled.

## 10. Pitfalls

| Pitfall | Fix |
|---|---|
| `SetState` called from anywhere, so the graph only exists in your head | Only events from outside. `SetState` is private to the machine |
| Re-entrant `Send` from inside an action (stack grows, half-entered states) | Queue events (run-to-completion) |
| Stale `task.delay` firing after an interrupt | State-owned timers cancelled on exit, or one scheduler |
| Flags beside the FSM (`IsStunned`, `CanAttack`, `Holding`) drifting out of sync | Make them states, regions, or effects that guards read |
| A state per combination (`BlockingExhausted`) | Parallel region or StatModifier/effect |
| Per-frame polled transitions for input | Event-driven transitions. Poll only real continuous conditions (AI distance) |
| Logic in `OnEnter` that depends on *why* you entered | Put it in the transition's actions, or read `Payload` |
| Client and server running diverging copies | Shared definition. Server is authoritative and the client syncs on broadcast |
| Undefined transition order (RobloxStateMachine dictionary iteration) | Ordered lists, first passing guard wins |
| Value-object states read once at startup (2020 thread, reply #5) | Read live state from the machine. Never cache it |

See also: `game.combat.architecture-patterns` (§4 action states), `luau.metatables.oop-classes` (§7 minimal class), `roblox.input.userinput-contextaction` (bindings), `game.status-effects.lol-stats-cc` (the effect layer).

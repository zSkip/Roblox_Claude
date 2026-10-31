--!strict
-- Single-script architecture (SSA) loader. Each side has exactly one entry script
-- (ServerScriptService.Main, StarterPlayerScripts.Main) that hands its module folders to Loader.Run;
-- everything else is a ModuleScript.
--
--   local MyService = { Priority = 50 }        -- optional; lower runs first (default 100)
--   function MyService.Init(self, Get) end     -- synchronous, must not yield: look up other modules
--                                              -- with Get("Name"), create signals and state
--   function MyService.Start(self) end         -- own thread, after every Init returned: connect
--                                              -- events, start loops; may yield
--   return MyService
--
-- A module's name is its ModuleScript's name. Equal priorities run in name order, so the order never
-- depends on instance order. Shared ReplicatedStorage modules are plain requires, not lifecycle modules.

export type Lifecycle = {
	Priority : number?,
	Init : ((self : any, Get : (Name : string) -> any) -> ())?,
	Start : ((self : any) -> ())?,
}

export type Named = { Name : string, Module : Lifecycle }

local Loader = {}

-- runs Init on every module in order, then Start on each in its own thread; returns { [Name]: Module }
function Loader.RunModules(List : { Named }) : { [string]: any }
	local Entries = table.clone(List)
	local ByName : { [string]: any } = {}
	for _, E in Entries do
		if ByName[E.Name] ~= nil then
			error(`[Loader] two modules named {E.Name}`, 0)
		end
		ByName[E.Name] = E.Module
	end
	table.sort(Entries, function(A, B)
		local PA, PB = A.Module.Priority or 100, B.Module.Priority or 100
		if PA ~= PB then
			return PA < PB
		end
		return A.Name < B.Name
	end)

	local function Get(Name : string) : any
		local Module = ByName[Name]
		if Module == nil then
			error(`[Loader] no module named {Name}`, 2)
		end
		return Module
	end

	for _, E in Entries do
		local Init = E.Module.Init
		if Init then
			local Thread = coroutine.create(Init)
			local Ok, Err = coroutine.resume(Thread, E.Module, Get)
			if not Ok then
				error(`[Loader] {E.Name}.Init failed: {Err}\n{debug.traceback(Thread)}`, 0)
			end
			if coroutine.status(Thread) ~= "dead" then
				error(`[Loader] {E.Name}.Init yielded; move waits and connections into Start`, 0)
			end
		end
	end
	for _, E in Entries do
		local Start = E.Module.Start
		if Start then
			task.spawn(Start, E.Module)
		end
	end
	return ByName
end

-- requires every ModuleScript directly inside the folders and runs them as lifecycle modules
function Loader.Run(Folders : { Instance }) : { [string]: any }
	local List : { Named } = {}
	for _, Folder in Folders do
		for _, Child in Folder:GetChildren() do
			if Child:IsA("ModuleScript") then
				local Module = (require :: any)(Child)
				if type(Module) ~= "table" then
					error(`[Loader] {Child:GetFullName()} must return a table`, 0)
				end
				table.insert(List, { Name = Child.Name, Module = Module })
			end
		end
	end
	return Loader.RunModules(List)
end

return table.freeze(Loader)

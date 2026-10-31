--!strict
--[[

TestKit - zero-dependency unit testing for Luau / Roblox

	A spec is a ModuleScript whose name ends in ".spec" and returns a function :

		return function(Describe, It, Expect)
			Describe("Directions", function()
				It("mirrors left and right", function()
					Expect(Directions.Mirror.Left).ToBe("Right")
				end)
			end)
		end

	TestKit.Run({ModuleScript}) -> Results
	TestKit.RunIn(Root : Instance) -> Results   -- finds every *.spec ModuleScript under Root

	Expect(Value) matchers :
		ToBe(Expected)               -- ==
		ToEqual(Expected)            -- deep equality for tables
		ToBeNear(Expected, Epsilon?) -- numbers, default epsilon 1e-6
		ToBeTruthy() / ToBeFalsy()
		ToBeNil()
		ToThrow(Pattern?)            -- Value must be a function that errors
	Prefix with .Never to invert : Expect(x).Never.ToBe(y)

]]

export type Results = {
	Passed : number,
	Failed : number,
	Failures : { { Name : string, Message : string } },
}

local TestKit = {}

local function Format(Value : any) : string
	if type(Value) == "string" then
		return `"{Value}"`
	end
	return tostring(Value)
end

local function DeepEqual(A : any, B : any) : boolean
	if A == B then
		return true
	end
	if type(A) ~= "table" or type(B) ~= "table" then
		return false
	end
	for Key, Value in A do
		if not DeepEqual(Value, B[Key]) then
			return false
		end
	end
	for Key in B do
		if A[Key] == nil then
			return false
		end
	end
	return true
end

local function MakeExpect(Value : any, Negate : boolean)
	local Matchers = {}

	local function Check(Passed : boolean, Message : string)
		if Passed == Negate then
			error((if Negate then "expected NOT: " else "expected: ") .. Message, 3)
		end
	end

	function Matchers.ToBe(Expected : any)
		Check(Value == Expected, `{Format(Value)} to be {Format(Expected)}`)
	end

	function Matchers.ToEqual(Expected : any)
		Check(DeepEqual(Value, Expected), `{Format(Value)} to deep-equal {Format(Expected)}`)
	end

	function Matchers.ToBeNear(Expected : number, Epsilon : number?)
		local Eps = Epsilon or 1e-6
		Check(type(Value) == "number" and math.abs(Value - Expected) <= Eps, `{Format(Value)} to be within {Eps} of {Expected}`)
	end

	function Matchers.ToBeTruthy()
		Check(Value ~= nil and Value ~= false, `{Format(Value)} to be truthy`)
	end

	function Matchers.ToBeFalsy()
		Check(Value == nil or Value == false, `{Format(Value)} to be falsy`)
	end

	function Matchers.ToBeNil()
		Check(Value == nil, `{Format(Value)} to be nil`)
	end

	function Matchers.ToThrow(Pattern : string?)
		assert(type(Value) == "function", "ToThrow expects a function")
		local Ok, Err = pcall(Value)
		local Matched = not Ok and (Pattern == nil or string.find(tostring(Err), Pattern, 1, true) ~= nil)
		Check(Matched, `function to throw{if Pattern then " matching " .. Format(Pattern) else ""} (got {if Ok then "no error" else Format(Err)})`)
	end

	return Matchers
end

local function Expect(Value : any)
	local Matchers = MakeExpect(Value, false) :: any
	Matchers.Never = MakeExpect(Value, true)
	return Matchers
end

function TestKit.Run(Specs : { ModuleScript }) : Results
	local Results : Results = { Passed = 0, Failed = 0, Failures = {} }
	local Prefix : { string } = {}

	local function Describe(Name : string, Body : () -> ())
		table.insert(Prefix, Name)
		Body()
		table.remove(Prefix)
	end

	local function It(Name : string, Body : () -> ())
		local FullName = table.concat(Prefix, " > ") .. " > " .. Name
		local Ok, Err = pcall(Body)
		if Ok then
			Results.Passed += 1
		else
			Results.Failed += 1
			table.insert(Results.Failures, { Name = FullName, Message = tostring(Err) })
		end
	end

	for _, Spec in Specs do
		local Ok, Err = pcall(function()
			local Body = (require :: any)(Spec)
			assert(type(Body) == "function", `{Spec:GetFullName()} must return a function`)
			Describe(Spec.Name, function()
				Body(Describe, It, Expect)
			end)
		end)
		if not Ok then
			Results.Failed += 1
			table.insert(Results.Failures, { Name = Spec:GetFullName(), Message = "spec failed to load: " .. tostring(Err) })
		end
	end

	return Results
end

function TestKit.RunIn(Root : Instance) : Results
	local Specs : { ModuleScript } = {}
	for _, Descendant in Root:GetDescendants() do
		if Descendant:IsA("ModuleScript") and string.sub(Descendant.Name, -5) == ".spec" then
			table.insert(Specs, Descendant)
		end
	end
	table.sort(Specs, function(A, B)
		return A:GetFullName() < B:GetFullName()
	end)
	return TestKit.Run(Specs)
end

function TestKit.Report(Results : Results)
	for _, Failure in Results.Failures do
		warn(`[TestKit] FAIL {Failure.Name}\n    {Failure.Message}`)
	end
	print(`[TestKit] {Results.Passed} passed, {Results.Failed} failed`)
end

return TestKit

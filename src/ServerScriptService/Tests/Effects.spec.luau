local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local LockProfile = require(Shared:WaitForChild("Combat"):WaitForChild("LockProfile"))
local Effects = require(Shared:WaitForChild("StatusEffects"):WaitForChild("Effects"))

return function(Describe, It, Expect)
	local function Def(Overrides : { [string]: any })
		local D = { Id = "Test", NetId = 200, Kind = "CC", Tags = {}, Duration = 1, StackMode = "Refresh" }
		for K, V in Overrides do
			D[K] = V
		end
		return D
	end

	Describe("registry", function()
		It("every NetId fits U8 and maps back", function()
			for _, D in Effects.List do
				Expect(D.NetId >= 1 and D.NetId <= 255).ToBe(true)
				Expect(Effects.FromNetId(D.NetId)).ToBe(D)
				Expect(Effects.Get(D.Id)).ToBe(D)
			end
		end)
		It("every Lock is a LockProfile tier", function()
			local Values = {}
			for _, V in LockProfile.Tiers do
				Values[V] = true
			end
			for _, D in Effects.List do
				if D.Lock ~= nil then
					Expect(Values[D.Lock]).ToBe(true)
				end
			end
		end)
		It("is frozen", function()
			Expect(function()
				(Effects.ById :: any).New = {}
			end).ToThrow()
		end)
	end)

	Describe("validation", function()
		It("accepts a good definition", function()
			Effects.Validate({ Def({}) })
		end)
		It("rejects duplicate Ids and NetIds", function()
			Expect(function() Effects.Validate({ Def({}), Def({ NetId = 201 }) }) end).ToThrow("duplicate Id")
			Expect(function() Effects.Validate({ Def({}), Def({ Id = "Other" }) }) end).ToThrow("already used")
		end)
		It("rejects NetIds outside U8", function()
			Expect(function() Effects.Validate({ Def({ NetId = 256 }) }) end).ToThrow("NetId")
			Expect(function() Effects.Validate({ Def({ NetId = 0 }) }) end).ToThrow("NetId")
		end)
		It("rejects unknown tags, actions and tiers", function()
			Expect(function() Effects.Validate({ Def({ Tags = { Sleepy = true } }) }) end).ToThrow("unknown tag")
			Expect(function() Effects.Validate({ Def({ Blocks = { Fly = true } }) }) end).ToThrow("unknown action")
			Expect(function() Effects.Validate({ Def({ Lock = 9 }) }) end).ToThrow("Lock")
		end)
		It("Intensity needs MaxStacks", function()
			Expect(function() Effects.Validate({ Def({ StackMode = "Intensity" }) }) end).ToThrow("MaxStacks")
		end)
	end)
end

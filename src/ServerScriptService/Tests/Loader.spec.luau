local Loader = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Loader"))

return function(Describe, It, Expect)
	Describe("Loader", function()
		It("inits by priority then name, then starts in the same order", function()
			local Log = {}
			local function Module(Name, Priority)
				return {
					Name = Name,
					Module = {
						Priority = Priority,
						Init = function(_self, Get)
							table.insert(Log, `init {Name}`)
						end,
						Start = function()
							table.insert(Log, `start {Name}`)
						end,
					},
				}
			end
			Loader.RunModules({ Module("B", 10), Module("C", nil), Module("A", 10), Module("Z", 1) })
			Expect(table.concat(Log, ",")).ToBe("init Z,init A,init B,init C,start Z,start A,start B,start C")
		end)

		It("hands out other modules through Get during Init", function()
			local Seen
			local Other = { Value = 7 }
			Loader.RunModules({
				{ Name = "Other", Module = Other },
				{ Name = "User", Module = { Init = function(_self, Get) Seen = Get("Other").Value end } },
			})
			Expect(Seen).ToBe(7)
		end)

		It("rejects a yielding Init, unknown names and duplicates", function()
			Expect(function()
				Loader.RunModules({ { Name = "Slow", Module = { Init = function() task.wait() end } } })
			end).ToThrow("yielded")
			Expect(function()
				Loader.RunModules({ { Name = "Lost", Module = { Init = function(_self, Get) Get("Nope") end } } })
			end).ToThrow("no module named Nope")
			Expect(function()
				Loader.RunModules({ { Name = "X", Module = {} }, { Name = "X", Module = {} } })
			end).ToThrow("two modules")
		end)
	end)
end

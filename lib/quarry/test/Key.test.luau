--!strict
local Testing = require("../../../.lune/testing")

local Key = require("../src/Key")

local suite: Testing.Suite = function(test, expect)
	test("keys with the same contents hash alike, whatever order a table's fields were written in", function()
		expect.equal(Key.hash({ "item", { id = 3, kind = "pet" } }), Key.hash({ "item", { kind = "pet", id = 3 } }))
		expect.truthy(Key.hash({ "a", "b" }) ~= Key.hash({ "b", "a" }))
		expect.truthy(Key.hash({ "count", 1 }) ~= Key.hash({ "count", "1" }))
	end)

	test("a filter key selects the keys it is a prefix of, tables by the fields it names", function()
		local key: Key.QueryKey = { "player", { id = 7, view = "store" } }
		expect.truthy(Key.matches(key, { "player" }))
		expect.truthy(Key.matches(key, { "player", { id = 7 } }))
		expect.truthy(not Key.matches(key, { "player", { id = 8 } }))
		expect.truthy(not Key.matches(key, { "store" }))
	end)

	test("structural sharing keeps every part that did not change", function()
		local before = { coins = 10, items = { Trail = 1 }, flags = { a = true } }
		local after = Key.replaceEqualDeep(before, { coins = 20, items = { Trail = 1 }, flags = { a = true } })
		local fields = after :: { [string]: unknown }
		expect.equal(fields.coins, 20)
		expect.equal(fields.items, before.items)
		expect.equal(fields.flags, before.flags)
		expect.equal(Key.replaceEqualDeep(before, { coins = 10, items = { Trail = 1 }, flags = { a = true } }), before)
	end)

	test("a removed field is a change", function()
		local before = { a = 1, b = 2 }
		expect.deepEqual(Key.replaceEqualDeep(before, { a = 1 }), { a = 1 })
	end)
end

return suite

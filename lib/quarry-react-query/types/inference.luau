--!strict
-- What the hooks infer, checked by lune run types: each `never` below is a
-- deliberate error whose message names the inferred type, which must be the
-- one after `expect:`. A free generic ('a) there means inference was lost.

local Query = require("../../quarry-query/src")
local ReactQuery = require("../src")

local function count(): number
	return 1
end

local result =
	ReactQuery.useQuery({ queryKey = { "item", 1 }, queryFn = count })
local data: never = result.data -- expect: number?

local picked = ReactQuery.useQuerySelect({
	queryKey = { "item", 1 },
	queryFn = function(): { total: number }
		return { total = 1 }
	end,
}, function(value: { total: number }): string
	return tostring(value.total)
end)
local pick: never = picked.data -- expect: string?

local mutation = ReactQuery.useMutation({
	mutationFn = function(_: string) end,
	onMutate = function(_: string) end,
})
local mutate: never = mutation.mutate -- expect: (string) -> ()

type Player = { coins: number }

local player = Query.queryOptions({
	queryKey = { "player" },
	queryFn = function(): Player
		return { coins = 0 }
	end,
})
local defined: never = ReactQuery.useQuery(player).data -- expect: Player?

return { data, pick, mutate, defined }

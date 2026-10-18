--!strict
-- What a definition's cache entry infers, checked by lune run types: each
-- `never` below is a deliberate error whose message names the inferred
-- type, which must be the one after `expect:`.

local Query = require("../src")

type Player = { coins: number }

local player = Query.queryOptions({
	queryKey = { "player" },
	queryFn = function(): Player
		return { coins = 0 }
	end,
})
local client = Query.QueryClient.new()
local data = client:data(player)

local got: never = data:get() -- expect: Player?
local written: never = data:set({ coins = 1 }) -- expect: Player?
data:update(function(old)
	local _given: never = old -- expect: Player?
	return old
end)

return { got, written }

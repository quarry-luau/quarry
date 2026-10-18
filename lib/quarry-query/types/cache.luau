--!strict
-- What the typed cache calls infer, checked by lune run types: each `never`
-- below is a deliberate error whose message names the inferred type, which
-- must be the one after `expect:`.

local Query = require("../src")

type Player = { coins: number }

local player = Query.queryOptions({
	queryKey = { "player" },
	queryFn = function(): Player
		return { coins = 0 }
	end,
})
local client = Query.QueryClient.new()

local function spend(old: Player?): Player?
	return if old then { coins = old.coins - 1 } else nil
end

local saved: never = client:getTypedData(player) -- expect: Player?
local written: never = client:updateTypedData(player, spend) -- expect: Player?

return { saved, written }

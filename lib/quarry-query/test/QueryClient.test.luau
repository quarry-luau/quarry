--!strict
local Testing = require("../../../.lune/testing")

local Fake = require("./Fake")
local Observer = require("../src/Observer")
local QueryClient = require("../src/QueryClient")

type Advance = (seconds: number) -> ()

-- A client on a fake clock, and what moves the clock.
local function setup(): (QueryClient.QueryClient, Advance)
	local clock = Fake.clock()
	return QueryClient.new({ scheduler = clock.scheduler }), clock.advance
end

-- A query the server only pushes to: no fetching of its own.
local function pushed(
	key: { unknown },
	gcTime: number?,
	select: ((data: unknown) -> unknown)?
): Observer.Options
	return {
		queryKey = key,
		enabled = false,
		gcTime = gcTime,
		select = select,
	}
end

local gate = Fake.gate

local suite: Testing.Suite = function(test, expect)
	test("subscribing fetches: loading first, then the data", function()
		local client = setup()
		local answer = gate()
		local observer = client:observe({
			queryKey = { "player" },
			queryFn = answer.wait,
		})
		local told = 0
		observer:subscribe(function()
			told += 1
		end)
		local loading = observer:getCurrentResult()
		expect.truthy(
			loading.isLoading
				and loading.isPending
				and loading.data == nil
		)
		answer.open({ coins = 5 })
		local done = observer:getCurrentResult()
		expect.truthy(
			done.isSuccess
				and not done.isFetching
				and done.isFetched
		)
		expect.deepEqual(done.data, { coins = 5 })
		-- Once as the fetch starts, once as it ends.
		expect.equal(told, 2)
	end)

	test("the first render shows the fetch mounting starts", function()
		local client = setup()
		local options: Observer.Options = {
			queryKey = { "player" },
			queryFn = gate().wait,
		}
		local result = client:observe(options)
			:getOptimisticResult(options)
		expect.truthy(result.isLoading)
	end)

	test("every asker of a key in flight shares one fetch", function()
		local client = setup()
		local calls = 0
		local answer = gate()
		local function fetch(): unknown
			calls += 1
			return answer.wait()
		end
		client:observe({
			queryKey = { "player" },
			queryFn = fetch,
		}):subscribe(function() end)
		client:observe({
			queryKey = { "player" },
			queryFn = fetch,
		}):subscribe(function() end)
		client:prefetchQuery({
			queryKey = { "player" },
			queryFn = fetch,
		})
		client:refetchQueries()
		expect.equal(calls, 1)
		answer.open(1)
		expect.equal(client:getQueryData({ "player" }), 1)
	end)

	test("a failure retries after 1, 2 and 4 s, then errors", function()
		local client, advance = setup()
		local calls = 0
		local observer = client:observe({
			queryKey = { "player" },
			queryFn = function(): unknown
				calls += 1
				error("Unavailable", 0)
			end,
		})
		observer:subscribe(function() end)
		expect.equal(calls, 1)
		advance(0.99)
		expect.equal(calls, 1)
		advance(0.01)
		expect.equal(calls, 2)
		-- Both attempts so far have failed.
		expect.equal(observer:getCurrentResult().failureCount, 2)
		advance(2)
		expect.equal(calls, 3)
		expect.truthy(observer:getCurrentResult().isFetching)
		advance(4)
		expect.equal(calls, 4)
		local failed = observer:getCurrentResult()
		expect.truthy(
			failed.isError
				and failed.isLoadingError
				and not failed.isFetching
		)
		expect.equal(failed.error, "Unavailable")
		expect.equal(failed.failureCount, 4)
		local state = client:getQueryState({ "player" })
		expect.truthy(state and state.isInvalidated)
	end)

	test("retry = false fails at the first error", function()
		local client = setup()
		local observer = client:observe({
			queryKey = { "player" },
			retry = false,
			queryFn = function(): unknown
				error("Unavailable", 0)
			end,
		})
		observer:subscribe(function() end)
		expect.truthy(observer:getCurrentResult().isError)
	end)

	test("retries stop once the last observer leaves", function()
		local client, advance = setup()
		local calls = 0
		local unsubscribe = client:observe({
			queryKey = { "player" },
			queryFn = function(): unknown
				calls += 1
				error("Unavailable", 0)
			end,
		}):subscribe(function() end)
		unsubscribe()
		advance(60)
		expect.equal(calls, 1)
	end)

	test("a query function that returns nothing fails", function()
		local client = setup()
		local observer = client:observe({
			queryKey = { "player" },
			retry = false,
			queryFn = function(): unknown
				return nil
			end,
		})
		observer:subscribe(function() end)
		expect.contains(
			tostring(observer:getCurrentResult().error),
			"data is nil"
		)
	end)

	test("setQueryData writes; an updater gets the old data", function()
		local client = setup()
		local observer = client:observe(pushed({ "player" }))
		local told = 0
		observer:subscribe(function()
			told += 1
		end)
		client:setQueryData({ "player" }, { coins = 1 })
		client:setQueryData(
			{ "player" },
			function(old: unknown): unknown
				local fields = old :: { coins: number }
				return { coins = fields.coins + 1 }
			end
		)
		expect.equal(
			client:setQueryData({ "player" }, function(): unknown
				return nil
			end),
			nil
		)
		expect.deepEqual(
			observer:getCurrentResult().data,
			{ coins = 2 }
		)
		expect.equal(told, 2)
	end)

	test("invalidating refetches active queries, marks others", function()
		local client = setup()
		local fetched: { string } = {}
		local function fetcher(name: string): () -> unknown
			return function(): unknown
				table.insert(fetched, name)
				return name
			end
		end
		client:observe({
			queryKey = { "player", "coins" },
			queryFn = fetcher("coins"),
		}):subscribe(function() end)
		client:prefetchQuery({
			queryKey = { "player", "items" },
			queryFn = fetcher("items"),
		})
		client:prefetchQuery({
			queryKey = { "store" },
			queryFn = fetcher("store"),
		})
		table.clear(fetched)
		client:invalidateQueries({ queryKey = { "player" } })
		expect.deepEqual(fetched, { "coins" })
		local items = client:getQueryState({ "player", "items" })
		local store = client:getQueryState({ "store" })
		expect.truthy(items and items.isInvalidated)
		expect.truthy(store and not store.isInvalidated)
	end)

	test("invalidating makes never-stale data stale", function()
		local client = setup()
		local calls = 0
		local options: Observer.Options = {
			queryKey = { "player" },
			staleTime = math.huge,
			queryFn = function(): unknown
				calls += 1
				return calls
			end,
		}
		client:observe(options):subscribe(function() end)
		client:observe(options):subscribe(function() end)
		expect.equal(calls, 1)
		client:invalidateQueries({
			queryKey = { "player" },
			refetchType = "none",
		})
		expect.equal(calls, 1)
		client:observe(options):subscribe(function() end)
		expect.equal(calls, 2)
	end)

	test("invalidating replaces a fetch out", function()
		local client = setup()
		local first, second = gate(), gate()
		local answers = { first, second }
		local calls = 0
		client:observe({
			queryKey = { "player" },
			queryFn = function(): unknown
				calls += 1
				return answers[calls].wait()
			end,
		}):subscribe(function() end)
		first.open("before")
		client:invalidateQueries({ queryKey = { "player" } })
		local replaced = gate()
		answers[3] = replaced
		client:invalidateQueries({ queryKey = { "player" } })
		second.open("too early")
		replaced.open("after")
		expect.equal(client:getQueryData({ "player" }), "after")
	end)

	test("cancelling reverts, and an old answer cannot land", function()
		local client = setup()
		local answer = gate()
		local observer = client:observe({
			queryKey = { "player" },
			queryFn = answer.wait,
		})
		observer:subscribe(function() end)
		client:cancelQueries({ queryKey = { "player" } })
		local reverted = observer:getCurrentResult()
		expect.truthy(
			reverted.isPending and reverted.fetchStatus == "idle"
		)
		client:setQueryData({ "player" }, "optimistic")
		answer.open("stale answer")
		expect.equal(client:getQueryData({ "player" }), "optimistic")
	end)

	test("fresh data is not fetched again on another mount", function()
		local client, advance = setup()
		local calls = 0
		local options: Observer.Options = {
			queryKey = { "player" },
			staleTime = 10,
			queryFn = function(): unknown
				calls += 1
				return calls
			end,
		}
		client:observe(options):subscribe(function() end)
		advance(5)
		client:observe(options):subscribe(function() end)
		expect.equal(calls, 1)
		advance(5)
		client:observe(options):subscribe(function() end)
		expect.equal(calls, 2)
	end)

	test("a query is removed gcTime after its last observer", function()
		local client, advance = setup()
		local unsubscribe = client:observe(pushed({ "player" }, 60))
			:subscribe(function() end)
		client:setQueryData({ "player" }, 1)
		advance(120)
		expect.equal(client:getQueryData({ "player" }), 1)
		unsubscribe()
		advance(59)
		expect.equal(client:getQueryData({ "player" }), 1)
		advance(1)
		expect.equal(client:getQueryData({ "player" }), nil)
	end)

	test("an unchanged pick keeps its identity, tells nobody", function()
		local client = setup()
		local observer = client:observe(
			pushed(
				{ "player" },
				nil,
				function(data: unknown): unknown
					local fields = data :: {
						items: {
							[string]: number,
						},
					}
					return {
						trail = fields.items.Trail,
					}
				end
			)
		)
		local told = 0
		observer:subscribe(function()
			told += 1
		end)
		client:setQueryData(
			{ "player" },
			{ coins = 1, items = { Trail = 1 } }
		)
		local first = observer:getCurrentResult().data
		client:setQueryData(
			{ "player" },
			{ coins = 2, items = { Trail = 1 } }
		)
		expect.equal(observer:getCurrentResult().data, first)
		expect.equal(told, 1)
	end)

	test("a listener hears only of fields it read", function()
		local client, advance = setup()
		local observer = client:observe(pushed({ "player" }))
		local told = 0
		observer:subscribe(function()
			told += 1
		end)
		client:setQueryData({ "player" }, { coins = 1 })
		local before = told
		local tracked =
			observer:trackResult(observer:getCurrentResult())
		local _ = tracked.data
		-- Equal data later: only the unread dataUpdatedAt moves.
		advance(1)
		client:setQueryData({ "player" }, { coins = 1 })
		expect.equal(told, before)
		client:setQueryData({ "player" }, { coins = 2 })
		expect.equal(told, before + 1)
	end)

	test("a select that raises makes the result an error", function()
		local client = setup()
		local observer = client:observe(
			pushed({ "player" }, nil, function(): unknown
				error("bad pick", 0)
			end)
		)
		observer:subscribe(function() end)
		client:setQueryData({ "player" }, 1)
		local result = observer:getCurrentResult()
		expect.truthy(result.isError)
		expect.equal(result.error, "bad pick")
	end)

	test("fetchQuery yields the data, raises without retrying", function()
		local client = setup()
		local answer = gate()
		local got: unknown = nil
		local thread = coroutine.create(function()
			got = client:fetchQuery({
				queryKey = { "player" },
				queryFn = answer.wait,
			})
		end)
		coroutine.resume(thread)
		expect.equal(got, nil)
		answer.open(42)
		expect.equal(got, 42)
		local calls = 0
		local outcome: { ok: boolean, problem: unknown }? = nil
		coroutine.resume(coroutine.create(function()
			local ok, problem = pcall(function()
				client:fetchQuery({
					queryKey = { "broken" },
					queryFn = function(): unknown
						calls += 1
						error("Unavailable", 0)
					end,
				})
			end)
			outcome = { ok = ok, problem = problem }
		end))
		expect.deepEqual(
			outcome,
			{ ok = false, problem = "Unavailable" }
		)
		expect.equal(calls, 1)
	end)

	test("isFetching counts the queries out", function()
		local client = setup()
		client:prefetchQuery({
			queryKey = { "a" },
			queryFn = gate().wait,
		})
		client:prefetchQuery({
			queryKey = { "b" },
			queryFn = gate().wait,
		})
		expect.equal(client:isFetching(), 2)
		expect.equal(client:isFetching({ queryKey = { "a" } }), 1)
	end)

	test("a disabled query does not fetch until it is enabled", function()
		local client = setup()
		local calls = 0
		local function options(enabled: boolean): Observer.Options
			return {
				queryKey = { "player" },
				enabled = enabled,
				queryFn = function(): unknown
					calls += 1
					return calls
				end,
			}
		end
		local observer = client:observe(options(false))
		observer:subscribe(function() end)
		observer:setOptions(options(false))
		expect.equal(calls, 0)
		observer:setOptions(options(true))
		expect.equal(calls, 1)
		observer:setOptions(options(true))
		expect.equal(calls, 1)
	end)

	test(
		"a definition's data reads, sets and updates as its type",
		function()
			local client = setup()
			local player = client:data({
				queryKey = { "player" },
				queryFn = function(): { coins: number }
					return { coins = 0 }
				end,
			})
			expect.equal(player:get(), nil)
			expect.deepEqual(
				player:set({ coins = 10 }),
				{ coins = 10 }
			)
			local written = player:update(function(old)
				return if old
					then { coins = old.coins - 4 }
					else nil
			end)
			expect.deepEqual(written, { coins = 6 })
			expect.deepEqual(player:get(), { coins = 6 })
			expect.deepEqual(
				client:getQueryData({ "player" }),
				{ coins = 6 }
			)
		end
	)

	test("nil from set or an update writes nothing", function()
		local client = setup()
		local coins = client:data({
			queryKey = { "coins" },
			queryFn = function(): number
				return 0
			end,
		})
		coins:set(5)
		expect.equal(coins:set(nil), nil)
		expect.equal(
			coins:update(function()
				return nil
			end),
			nil
		)
		expect.equal(coins:get(), 5)
	end)

	test("data that is a function is set, not called", function()
		local client = setup()
		local function handler(): number
			return 1
		end
		local callback = client:data({
			queryKey = { "callback" },
			queryFn = function(): () -> number
				return handler
			end,
		})
		callback:set(handler)
		expect.equal(callback:get(), handler)
	end)

	test("switching keys fetches the new one, drops the old", function()
		local client = setup()
		local observer = client:observe({
			queryKey = { "item", 1 },
			queryFn = function(): unknown
				return "one"
			end,
		})
		local told = 0
		observer:subscribe(function()
			told += 1
		end)
		observer:setOptions({
			queryKey = { "item", 2 },
			queryFn = function(): unknown
				return "two"
			end,
		})
		expect.equal(observer:getCurrentResult().data, "two")
		local before = told
		client:setQueryData({ "item", 1 }, "changed")
		expect.equal(told, before)
	end)
end

return suite

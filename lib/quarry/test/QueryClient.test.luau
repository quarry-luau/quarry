--!strict
local Testing = require("../../../.lune/testing")

local Observer = require("../src/Observer")
local QueryClient = require("../src/QueryClient")
local Scheduler = require("../src/Scheduler")

type Timer = { at: number, work: () -> (), cancelled: boolean }

-- A scheduler whose clock moves only when the test calls `advance`.
local function fakeScheduler(): (Scheduler.Scheduler, (seconds: number) -> ())
	local time = 0
	local timers: { Timer } = {}
	local function run(thread: thread, ...: unknown)
		local ok, problem = coroutine.resume(thread, ...)
		if not ok then
			error(problem, 0)
		end
	end
	local scheduler: Scheduler.Scheduler = {
		spawn = function(work: () -> ())
			run(coroutine.create(work))
		end,
		delay = function(seconds: number, work: () -> ()): () -> ()
			local timer: Timer = { at = time + seconds, work = work, cancelled = false }
			table.insert(timers, timer)
			return function()
				timer.cancelled = true
			end
		end,
		resume = function(thread: thread, ok: boolean, value: unknown)
			run(thread, ok, value)
		end,
		now = function(): number
			return time
		end,
	}
	local function advance(seconds: number)
		local target = time + seconds
		while true do
			local due: Timer? = nil
			for _, timer in timers do
				if not timer.cancelled and timer.at <= target and (due == nil or timer.at < due.at) then
					due = timer
				end
			end
			if due == nil then
				break
			end
			due.cancelled = true
			time = due.at
			run(coroutine.create(due.work))
		end
		time = target
	end
	return scheduler, advance
end

type Gate = { wait: () -> unknown, open: (value: unknown) -> (), waiting: () -> number }

-- What a query function waits on, as a remote call yields for its answer.
local function gate(): Gate
	local waiting: { thread } = {}
	return {
		wait = function(): unknown
			table.insert(waiting, coroutine.running())
			return coroutine.yield()
		end,
		open = function(value: unknown)
			local threads = waiting
			waiting = {}
			for _, thread in threads do
				local ok, problem = coroutine.resume(thread, value)
				if not ok then
					error(problem, 0)
				end
			end
		end,
		waiting = function(): number
			return #waiting
		end,
	}
end

local suite: Testing.Suite = function(test, expect)
	local function setup(): (QueryClient.QueryClient, (seconds: number) -> ())
		local scheduler, advance = fakeScheduler()
		return QueryClient.new({ scheduler = scheduler }), advance
	end
	-- A query the server only pushes to: no fetching of its own.
	local function pushed(key: { unknown }, gcTime: number?, select: ((data: unknown) -> unknown)?): Observer.Options
		return { queryKey = key, enabled = false, gcTime = gcTime, select = select }
	end

	test("subscribing fetches: loading first, then the data", function()
		local client = setup()
		local answer = gate()
		local observer = client:observe({ queryKey = { "player" }, queryFn = answer.wait })
		local told = 0
		observer:subscribe(function()
			told += 1
		end)
		local loading = observer:getCurrentResult()
		expect.truthy(loading.isLoading and loading.isPending and loading.data == nil)
		answer.open({ coins = 5 })
		local done = observer:getCurrentResult()
		expect.truthy(done.isSuccess and not done.isFetching and done.isFetched)
		expect.deepEqual(done.data, { coins = 5 })
		-- Once as the fetch starts, once as it ends.
		expect.equal(told, 2)
	end)

	test("the first render already shows the fetch that subscribing will start", function()
		local client = setup()
		local options: Observer.Options = { queryKey = { "player" }, queryFn = gate().wait }
		local result = client:observe(options):getOptimisticResult(options)
		expect.truthy(result.isLoading)
	end)

	test("everything asking for one key while it is fetched shares the one fetch", function()
		local client = setup()
		local calls = 0
		local answer = gate()
		local function fetch(): unknown
			calls += 1
			return answer.wait()
		end
		client:observe({ queryKey = { "player" }, queryFn = fetch }):subscribe(function() end)
		client:observe({ queryKey = { "player" }, queryFn = fetch }):subscribe(function() end)
		client:prefetchQuery({ queryKey = { "player" }, queryFn = fetch })
		client:refetchQueries()
		expect.equal(calls, 1)
		answer.open(1)
		expect.equal(client:getQueryData({ "player" }), 1)
	end)

	test("a failure is tried again after 1, 2 and 4 seconds, then is an error", function()
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
		expect.truthy(failed.isError and failed.isLoadingError and not failed.isFetching)
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
		local unsubscribe = client
			:observe({
				queryKey = { "player" },
				queryFn = function(): unknown
					calls += 1
					error("Unavailable", 0)
				end,
			})
			:subscribe(function() end)
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
		expect.contains(tostring(observer:getCurrentResult().error), "data is nil")
	end)

	test("setQueryData writes what observers read; an updater gets the old data, nil writes nothing", function()
		local client = setup()
		local observer = client:observe(pushed({ "player" }))
		local told = 0
		observer:subscribe(function()
			told += 1
		end)
		client:setQueryData({ "player" }, { coins = 1 })
		client:setQueryData({ "player" }, function(old: unknown): unknown
			local fields = old :: { coins: number }
			return { coins = fields.coins + 1 }
		end)
		expect.equal(
			client:setQueryData({ "player" }, function(): unknown
				return nil
			end),
			nil
		)
		expect.deepEqual(observer:getCurrentResult().data, { coins = 2 })
		expect.equal(told, 2)
	end)

	test("invalidating refetches the active queries under a key and only marks the others", function()
		local client = setup()
		local fetched: { string } = {}
		local function fetcher(name: string): () -> unknown
			return function(): unknown
				table.insert(fetched, name)
				return name
			end
		end
		client:observe({ queryKey = { "player", "coins" }, queryFn = fetcher("coins") }):subscribe(function() end)
		client:prefetchQuery({ queryKey = { "player", "items" }, queryFn = fetcher("items") })
		client:prefetchQuery({ queryKey = { "store" }, queryFn = fetcher("store") })
		table.clear(fetched)
		client:invalidateQueries({ queryKey = { "player" } })
		expect.deepEqual(fetched, { "coins" })
		local items = client:getQueryState({ "player", "items" })
		local store = client:getQueryState({ "store" })
		expect.truthy(items and items.isInvalidated)
		expect.truthy(store and not store.isInvalidated)
	end)

	test("data that never goes stale is stale once invalidated, and fetched on the next mount", function()
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
		client:invalidateQueries({ queryKey = { "player" }, refetchType = "none" })
		expect.equal(calls, 1)
		client:observe(options):subscribe(function() end)
		expect.equal(calls, 2)
	end)

	test("invalidating during a fetch replaces it, so an answer from before cannot land after", function()
		local client = setup()
		local first, second = gate(), gate()
		local answers = { first, second }
		local calls = 0
		client
			:observe({
				queryKey = { "player" },
				queryFn = function(): unknown
					calls += 1
					return answers[calls].wait()
				end,
			})
			:subscribe(function() end)
		first.open("before")
		client:invalidateQueries({ queryKey = { "player" } })
		local replaced = gate()
		answers[3] = replaced
		client:invalidateQueries({ queryKey = { "player" } })
		second.open("too early")
		replaced.open("after")
		expect.equal(client:getQueryData({ "player" }), "after")
	end)

	test("a cancelled fetch goes back to the state before it, and cannot overwrite data set after", function()
		local client = setup()
		local answer = gate()
		local observer = client:observe({ queryKey = { "player" }, queryFn = answer.wait })
		observer:subscribe(function() end)
		client:cancelQueries({ queryKey = { "player" } })
		local reverted = observer:getCurrentResult()
		expect.truthy(reverted.isPending and reverted.fetchStatus == "idle")
		client:setQueryData({ "player" }, "optimistic")
		answer.open("stale answer")
		expect.equal(client:getQueryData({ "player" }), "optimistic")
	end)

	test("fresh data is not fetched again when another observer subscribes", function()
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

	test("a query is removed gcTime after its last observer leaves, not while one watches", function()
		local client, advance = setup()
		local unsubscribe = client:observe(pushed({ "player" }, 60)):subscribe(function() end)
		client:setQueryData({ "player" }, 1)
		advance(120)
		expect.equal(client:getQueryData({ "player" }), 1)
		unsubscribe()
		advance(59)
		expect.equal(client:getQueryData({ "player" }), 1)
		advance(1)
		expect.equal(client:getQueryData({ "player" }), nil)
	end)

	test("a selected part that did not change keeps its identity and tells nobody", function()
		local client = setup()
		local observer = client:observe(pushed({ "player" }, nil, function(data: unknown): unknown
			local fields = data :: { items: { [string]: number } }
			return { trail = fields.items.Trail }
		end))
		local told = 0
		observer:subscribe(function()
			told += 1
		end)
		client:setQueryData({ "player" }, { coins = 1, items = { Trail = 1 } })
		local first = observer:getCurrentResult().data
		client:setQueryData({ "player" }, { coins = 2, items = { Trail = 1 } })
		expect.equal(observer:getCurrentResult().data, first)
		expect.equal(told, 1)
	end)

	test("once a field is read through trackResult, only changes to read fields tell the listener", function()
		local client, advance = setup()
		local observer = client:observe(pushed({ "player" }))
		local told = 0
		observer:subscribe(function()
			told += 1
		end)
		client:setQueryData({ "player" }, { coins = 1 })
		local before = told
		local tracked = observer:trackResult(observer:getCurrentResult())
		local _ = tracked.data
		-- Equal data written later: only dataUpdatedAt, which nothing read, changes.
		advance(1)
		client:setQueryData({ "player" }, { coins = 1 })
		expect.equal(told, before)
		client:setQueryData({ "player" }, { coins = 2 })
		expect.equal(told, before + 1)
	end)

	test("a select that raises makes the result an error", function()
		local client = setup()
		local observer = client:observe(pushed({ "player" }, nil, function(): unknown
			error("bad pick", 0)
		end))
		observer:subscribe(function() end)
		client:setQueryData({ "player" }, 1)
		local result = observer:getCurrentResult()
		expect.truthy(result.isError)
		expect.equal(result.error, "bad pick")
	end)

	test("fetchQuery yields for the data, and raises a failure without retrying", function()
		local client = setup()
		local answer = gate()
		local got: unknown = nil
		local thread = coroutine.create(function()
			got = client:fetchQuery({ queryKey = { "player" }, queryFn = answer.wait })
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
		expect.deepEqual(outcome, { ok = false, problem = "Unavailable" })
		expect.equal(calls, 1)
	end)

	test("isFetching counts the queries out", function()
		local client = setup()
		client:prefetchQuery({ queryKey = { "a" }, queryFn = gate().wait })
		client:prefetchQuery({ queryKey = { "b" }, queryFn = gate().wait })
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

	test("switching to another key fetches it and stops listening to the old one", function()
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

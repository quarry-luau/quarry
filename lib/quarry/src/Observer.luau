--!strict
-- A port of TanStack Query's QueryObserver (query-core/src/queryObserver.ts, v5.104): what a
-- component holds to read one query. Subscribing fetches when there is no data, or when it is stale
-- and `refetchOnMount` allows; changing to another key, or enabling the query, fetches when the
-- data is stale. `getOptimisticResult` is the result for the next render, already showing a fetch
-- that subscribing will start. `select` picks part of the data, shared with the last pick where it
-- is equal, so the result keeps its identity when that part did not change; a `select` that raises
-- makes the result an error. Listeners hear only results that differ in a field read through
-- `trackResult` (every field, until one is read that way), as TanStack's tracked props.
--
-- Not ported: refetchInterval, refetchOnWindowFocus and refetchOnReconnect (a Roblox client has no
-- focus or connection events of that kind), placeholderData, suspense, "static" stale times and
-- notifyOnChangeProps.

local Key = require("./Key")
local Query = require("./Query")
local Retryer = require("./Retryer")

export type Options = {
	queryKey: Key.QueryKey,
	queryFn: Query.QueryFunction?,
	retry: Retryer.RetryValue?,
	retryDelay: Retryer.RetryDelayValue?,
	gcTime: number?,
	initialData: unknown,
	-- Whether the query fetches by itself (true).
	enabled: boolean?,
	-- Seconds data stays fresh (0); math.huge for data that only changes when invalidated or set.
	staleTime: number?,
	-- Whether subscribing fetches stale data again: true, false or "always".
	refetchOnMount: (boolean | "always")?,
	-- Whether subscribing fetches again after an error (true).
	retryOnMount: boolean?,
	-- Picks what the result holds from the data.
	select: ((data: unknown) -> unknown)?,
}
export type Result = {
	data: unknown,
	dataUpdatedAt: number,
	error: unknown,
	errorUpdatedAt: number,
	errorUpdateCount: number,
	failureCount: number,
	failureReason: unknown,
	status: Query.Status,
	fetchStatus: Query.FetchStatus,
	isPending: boolean,
	isSuccess: boolean,
	isError: boolean,
	isFetching: boolean,
	-- Fetching with no data yet.
	isLoading: boolean,
	-- Fetching again, with data already shown.
	isRefetching: boolean,
	isLoadingError: boolean,
	isRefetchError: boolean,
	isFetched: boolean,
	isStale: boolean,
	isEnabled: boolean,
	refetch: () -> (),
}
-- What an observer needs of its client.
export type Client = {
	build: (options: Options) -> Query.Query,
	defaultQueryOptions: (options: Options) -> Options,
}
export type Observer = {
	setOptions: (self: Observer, options: Options) -> (),
	getOptimisticResult: (self: Observer, options: Options) -> Result,
	getCurrentResult: (self: Observer) -> Result,
	subscribe: (self: Observer, listener: () -> ()) -> () -> (),
	refetch: (self: Observer, cancelRefetch: boolean?) -> (),
	-- `result` as a view that records which of its fields are read.
	trackResult: (self: Observer, result: Result) -> Result,
}

local ObserverModule = {}

local function enabled(options: Options): boolean
	return options.enabled ~= false
end

local function isStale(query: Query.Query, options: Options): boolean
	return enabled(options) and query:isStaleByTime(options.staleTime)
end

local function shouldLoadOnMount(query: Query.Query, options: Options): boolean
	return enabled(options)
		and query.state.data == nil
		and not (query.state.status == "error" and options.retryOnMount == false)
end

local function shouldFetchOnMount(query: Query.Query, options: Options): boolean
	if shouldLoadOnMount(query, options) then
		return true
	elseif query.state.data == nil or not enabled(options) then
		return false
	end
	local refetch = options.refetchOnMount
	return refetch == "always" or (refetch ~= false and isStale(query, options))
end

local function shouldFetchOptionally(
	query: Query.Query,
	previousQuery: Query.Query,
	options: Options,
	previousOptions: Options
): boolean
	return (query ~= previousQuery or not enabled(previousOptions)) and isStale(query, options)
end

local RESULT_KEYS = {
	"data",
	"dataUpdatedAt",
	"error",
	"errorUpdatedAt",
	"errorUpdateCount",
	"failureCount",
	"failureReason",
	"status",
	"fetchStatus",
	"isPending",
	"isSuccess",
	"isError",
	"isFetching",
	"isLoading",
	"isRefetching",
	"isLoadingError",
	"isRefetchError",
	"isFetched",
	"isStale",
	"isEnabled",
	"refetch",
}

-- Invariant: a Result is a table whose fields are RESULT_KEYS; reading one by name is reading it.
local function fieldsOf(result: Result): { [string]: unknown }
	return result :: any
end

-- Whether `current` differs from `previous` in a field `tracked` names, or in any field when it names
-- none.
local function changed(previous: Result, current: Result, tracked: { [string]: boolean }): boolean
	local before, after = fieldsOf(previous), fieldsOf(current)
	local trackingAny = next(tracked) ~= nil
	for _, key in RESULT_KEYS do
		if before[key] ~= after[key] and (not trackingAny or tracked[key]) then
			return true
		end
	end
	return false
end

function ObserverModule.new(client: Client, initial: Options): Observer
	local options = client.defaultQueryOptions(initial)
	local query = client.build(options)
	local listener: (() -> ())? = nil
	local currentResult: Result? = nil
	local selectFrom: unknown = nil
	local selectFn: ((data: unknown) -> unknown)? = nil
	local selectResult: unknown = nil

	local trackedProps: { [string]: boolean } = {}

	local self: Observer
	local handle: Query.Observer
	local function refetchResult()
		self:refetch()
	end

	-- The data `given.select` picks, reused while the data and the function stay the same.
	local function select(data: unknown, given: Options): (boolean, unknown)
		local picker = given.select
		if picker == nil or data == nil then
			return true, data
		elseif data == selectFrom and picker == selectFn then
			return true, selectResult
		end
		local ok, picked = pcall(picker, data)
		if not ok then
			return false, picked
		end
		selectFrom, selectFn = data, picker
		selectResult = Key.replaceEqualDeep(if currentResult then currentResult.data else nil, picked)
		return true, selectResult
	end

	local function createResult(entry: Query.Query, given: Options, optimistic: boolean): Result
		local state = entry.state
		local fetchStatus: Query.FetchStatus = state.fetchStatus
		local status: Query.Status = state.status
		local problem = state.error
		if optimistic then
			local willFetch = if listener ~= nil
				then shouldFetchOptionally(entry, query, given, options)
				else shouldFetchOnMount(entry, given)
			if willFetch then
				fetchStatus = "fetching"
				if state.data == nil then
					status, problem = "pending", nil
				end
			end
		end
		local picked, data = select(state.data, given)
		if not picked then
			status, problem = "error", data
			data = if currentResult then currentResult.data else nil
		end
		local fetching = fetchStatus == "fetching"
		local pending = status == "pending"
		local failed = status == "error"
		return {
			data = data,
			dataUpdatedAt = state.dataUpdatedAt,
			error = problem,
			errorUpdatedAt = state.errorUpdatedAt,
			errorUpdateCount = state.errorUpdateCount,
			failureCount = state.fetchFailureCount,
			failureReason = state.fetchFailureReason,
			status = status,
			fetchStatus = fetchStatus,
			isPending = pending,
			isSuccess = status == "success",
			isError = failed,
			isFetching = fetching,
			isLoading = pending and fetching,
			isRefetching = fetching and not pending,
			isLoadingError = failed and state.data == nil,
			isRefetchError = failed and state.data ~= nil,
			isFetched = entry:isFetched(),
			isStale = isStale(entry, given),
			isEnabled = enabled(given),
			refetch = refetchResult,
		}
	end

	local function updateResult()
		local next = createResult(query, options, false)
		local previous = currentResult
		currentResult = next
		if listener and (previous == nil or changed(previous, next, trackedProps)) then
			listener()
		end
	end

	local function executeFetch(cancelRefetch: boolean?)
		query:fetch(options, { cancelRefetch = cancelRefetch })
	end

	handle = {
		onQueryUpdate = updateResult,
		options = function()
			return options
		end,
		isStale = function(): boolean
			return currentResult ~= nil and currentResult.isStale
		end,
	}

	self = {
		setOptions = function(_: Observer, given: Options)
			local previousOptions, previousQuery = options, query
			options = client.defaultQueryOptions(given)
			query = client.build(options)
			if query ~= previousQuery and listener then
				previousQuery:removeObserver(handle)
				query:addObserver(handle)
			end
			query:setOptions(options)
			if listener and shouldFetchOptionally(query, previousQuery, options, previousOptions) then
				executeFetch()
			end
			updateResult()
		end,
		getOptimisticResult = function(_: Observer, given: Options): Result
			local defaulted = client.defaultQueryOptions(given)
			return createResult(client.build(defaulted), defaulted, true)
		end,
		getCurrentResult = function(_: Observer): Result
			local result = currentResult or createResult(query, options, false)
			currentResult = result
			return result
		end,
		subscribe = function(_: Observer, callback: () -> ()): () -> ()
			listener = callback
			query:addObserver(handle)
			currentResult = createResult(query, options, false)
			if shouldFetchOnMount(query, options) then
				executeFetch()
			end
			return function()
				if listener == callback then
					listener = nil
					query:removeObserver(handle)
				end
			end
		end,
		refetch = function(_: Observer, cancelRefetch: boolean?)
			executeFetch(cancelRefetch ~= false)
		end,
		trackResult = function(_: Observer, result: Result): Result
			local fields = fieldsOf(result)
			local view = setmetatable({}, {
				__index = function(_: unknown, key: string): unknown
					trackedProps[key] = true
					return fields[key]
				end,
			})
			-- Invariant: every field read of the view is read from `result`.
			return (view :: any) :: Result
		end,
	}
	return self
end

return ObserverModule

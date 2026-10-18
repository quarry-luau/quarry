--!strict
-- A port of TanStack Query's QueryClient and QueryCache (query-core/src/queryClient.ts and
-- queryCache.ts, v5.104). Filters select queries by a key prefix (`{ queryKey = { "player" } }`,
-- or one key with `exact = true`), by whether observers use them (`type`), by staleness, fetch
-- status or a predicate; no filter selects every query. Data the server pushes goes in with
-- `setQueryData`, as a TanStack app writes what a websocket brings; an optimistic update does the
-- same after `cancelQueries`, and rolls back with what `getQueryData` gave before it.
--
-- Where TanStack returns a promise, `fetchQuery` and `ensureQueryData` yield for the data and raise
-- the failure; the others return at once. Notifications are told at once, not batched to the next
-- tick. Mutations live in the React bindings' useMutation, not in a cache here.

local Key = require("./Key")
local Observer = require("./Observer")
local Query = require("./Query")
local Retryer = require("./Retryer")
local Scheduler = require("./Scheduler")
local Unknown = require("./Unknown")

export type QueryType = "all" | "active" | "inactive"
export type Filters = {
	queryKey: Key.QueryKey?,
	exact: boolean?,
	type: QueryType?,
	stale: boolean?,
	fetchStatus: Query.FetchStatus?,
	predicate: ((query: Query.Query) -> boolean)?,
}
-- Filters, and which of the chosen queries invalidating refetches: active ones by default.
export type InvalidateFilters = {
	queryKey: Key.QueryKey?,
	exact: boolean?,
	type: QueryType?,
	stale: boolean?,
	fetchStatus: Query.FetchStatus?,
	predicate: ((query: Query.Query) -> boolean)?,
	refetchType: (QueryType | "none")?,
}
-- Options every query starts from, under its own.
export type Defaults = {
	retry: Retryer.RetryValue?,
	retryDelay: Retryer.RetryDelayValue?,
	gcTime: number?,
	staleTime: number?,
	refetchOnMount: (boolean | "always")?,
	retryOnMount: boolean?,
}
export type Config = { scheduler: Scheduler.Scheduler?, defaultOptions: { queries: Defaults? }? }
export type EnsureOptions = Observer.Options & { revalidateIfStale: boolean? }
export type QueryClient = {
	getQueryData: (self: QueryClient, queryKey: Key.QueryKey) -> unknown,
	getQueryState: (self: QueryClient, queryKey: Key.QueryKey) -> Query.State?,
	-- Writes data (or what `updater(old)` returns) under the key; nil writes nothing.
	setQueryData: (self: QueryClient, queryKey: Key.QueryKey, updater: unknown) -> unknown,
	invalidateQueries: (self: QueryClient, filters: InvalidateFilters?, options: Query.FetchOptions?) -> (),
	refetchQueries: (self: QueryClient, filters: Filters?, options: Query.FetchOptions?) -> (),
	cancelQueries: (self: QueryClient, filters: Filters?, options: Retryer.CancelOptions?) -> (),
	removeQueries: (self: QueryClient, filters: Filters?) -> (),
	isFetching: (self: QueryClient, filters: Filters?) -> number,
	fetchQuery: (self: QueryClient, options: Observer.Options) -> unknown,
	prefetchQuery: (self: QueryClient, options: Observer.Options) -> (),
	ensureQueryData: (self: QueryClient, options: EnsureOptions) -> unknown,
	clear: (self: QueryClient) -> (),
	observe: (self: QueryClient, options: Observer.Options) -> Observer.Observer,
}

local QueryClientModule = {}

-- React-style string unions widen to `string` when read back; this reads a query type back.
local QUERY_TYPES: { [string]: QueryType } = { all = "all", active = "active", inactive = "inactive" }

local function matches(query: Query.Query, filters: Filters?): boolean
	if filters == nil then
		return true
	end
	local key = filters.queryKey
	if key and filters.exact and query.queryHash ~= Key.hash(key) then
		return false
	elseif key and not filters.exact and not Key.matches(query.queryKey, key) then
		return false
	end
	local kind = filters.type or "all"
	if kind ~= "all" and query:isActive() ~= (kind == "active") then
		return false
	elseif filters.stale ~= nil and query:isStale() ~= filters.stale then
		return false
	elseif filters.fetchStatus ~= nil and filters.fetchStatus ~= query.state.fetchStatus then
		return false
	end
	return filters.predicate == nil or filters.predicate(query)
end

-- `options` under `defaults`: each field the options leave out takes the default's.
local function defaulted(defaults: Defaults, options: Observer.Options): Observer.Options
	local result = table.clone(options)
	if result.retry == nil then
		result.retry = defaults.retry
	end
	if result.retryDelay == nil then
		result.retryDelay = defaults.retryDelay
	end
	if result.gcTime == nil then
		result.gcTime = defaults.gcTime
	end
	if result.staleTime == nil then
		result.staleTime = defaults.staleTime
	end
	if result.refetchOnMount == nil then
		result.refetchOnMount = defaults.refetchOnMount
	end
	if result.retryOnMount == nil then
		result.retryOnMount = defaults.retryOnMount
	end
	return result
end

function QueryClientModule.new(config: Config?): QueryClient
	local scheduler = if config and config.scheduler then config.scheduler else Scheduler.task()
	local defaults: Defaults = if config
			and config.defaultOptions
			and config.defaultOptions.queries
		then config.defaultOptions.queries
		else {}
	local queries: { [string]: Query.Query } = {}

	local function remove(query: Query.Query)
		if queries[query.queryHash] == query then
			query:destroy()
			queries[query.queryHash] = nil
		end
	end
	local function build(options: Observer.Options): Query.Query
		local hash = Key.hash(options.queryKey)
		local query = queries[hash]
		if query == nil then
			query = Query.new(options.queryKey, options, scheduler, remove)
			queries[hash] = query
		end
		return query
	end
	local function findAll(filters: Filters?): { Query.Query }
		local found: { Query.Query } = {}
		for _, query in queries do
			if matches(query, filters) then
				table.insert(found, query)
			end
		end
		return found
	end
	local function find(queryKey: Key.QueryKey): Query.Query?
		return queries[Key.hash(queryKey)]
	end
	local function defaultQueryOptions(options: Observer.Options): Observer.Options
		return defaulted(defaults, options)
	end
	local observerClient: Observer.Client = { build = build, defaultQueryOptions = defaultQueryOptions }

	local self: QueryClient
	self = {
		getQueryData = function(_: QueryClient, queryKey: Key.QueryKey): unknown
			local query = find(queryKey)
			return if query then query.state.data else nil
		end,
		getQueryState = function(_: QueryClient, queryKey: Key.QueryKey): Query.State?
			local query = find(queryKey)
			return if query then query.state else nil
		end,
		setQueryData = function(_: QueryClient, queryKey: Key.QueryKey, updater: unknown): unknown
			local query = find(queryKey)
			local previous = if query then query.state.data else nil
			local update = Unknown.callable(updater)
			local data = if update then update(previous) else updater
			if data == nil then
				return nil
			end
			return build(defaultQueryOptions({ queryKey = queryKey })):setData(data, { manual = true })
		end,
		invalidateQueries = function(client: QueryClient, filters: InvalidateFilters?, options: Query.FetchOptions?)
			for _, query in findAll(filters) do
				query:invalidate()
			end
			local refetchType = if filters then filters.refetchType else nil
			if refetchType == "none" then
				return
			end
			local refetch: Filters = {}
			if filters then
				refetch.queryKey = filters.queryKey
				refetch.exact = filters.exact
				refetch.stale = filters.stale
				refetch.fetchStatus = filters.fetchStatus
				refetch.predicate = filters.predicate
			end
			refetch.type = QUERY_TYPES[refetchType or ""] or (if filters then filters.type else nil) or "active"
			client:refetchQueries(refetch, options)
		end,
		refetchQueries = function(_: QueryClient, filters: Filters?, options: Query.FetchOptions?)
			local cancelRefetch = if options and options.cancelRefetch ~= nil then options.cancelRefetch else true
			for _, query in findAll(filters) do
				if not query:isDisabled() then
					query:fetch(nil, { cancelRefetch = cancelRefetch })
				end
			end
		end,
		cancelQueries = function(_: QueryClient, filters: Filters?, options: Retryer.CancelOptions?)
			local given: Retryer.CancelOptions = { revert = true, silent = false }
			if options then
				given.revert = if options.revert ~= nil then options.revert else true
				given.silent = options.silent
			end
			for _, query in findAll(filters) do
				query:cancel(given)
			end
		end,
		removeQueries = function(_: QueryClient, filters: Filters?)
			for _, query in findAll(filters) do
				remove(query)
			end
		end,
		isFetching = function(_: QueryClient, filters: Filters?): number
			local given: Filters = if filters then table.clone(filters) else {}
			given.fetchStatus = "fetching"
			return #findAll(given)
		end,
		fetchQuery = function(_: QueryClient, options: Observer.Options): unknown
			local given = defaultQueryOptions(options)
			if given.retry == nil then
				given.retry = false
			end
			local query = build(given)
			if not query:isStaleByTime(given.staleTime) then
				return query.state.data
			end
			query:fetch(given)
			local ok, value = query:await()
			if not ok then
				error(value, 0)
			end
			return value
		end,
		prefetchQuery = function(_: QueryClient, options: Observer.Options)
			local given = defaultQueryOptions(options)
			if given.retry == nil then
				given.retry = false
			end
			local query = build(given)
			if query:isStaleByTime(given.staleTime) then
				query:fetch(given)
			end
		end,
		ensureQueryData = function(client: QueryClient, options: EnsureOptions): unknown
			local query = build(defaultQueryOptions(options))
			local cached = query.state.data
			if cached == nil then
				return client:fetchQuery(options)
			elseif options.revalidateIfStale and query:isStaleByTime(options.staleTime or defaults.staleTime) then
				client:prefetchQuery(options)
			end
			return cached
		end,
		clear = function(_: QueryClient)
			for _, query in findAll(nil) do
				remove(query)
			end
		end,
		observe = function(_: QueryClient, options: Observer.Options): Observer.Observer
			return Observer.new(observerClient, options)
		end,
	}
	return self
end

return QueryClientModule

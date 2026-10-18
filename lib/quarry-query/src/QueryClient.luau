--!strict
-- A port of TanStack Query's QueryClient and QueryCache
-- (query-core/src/queryClient.ts and queryCache.ts). Filters select queries
-- by a key prefix ({ queryKey = { "player" } }, or one key with exact), by
-- whether observers use them (type), by staleness, fetch status or a
-- predicate; no filter selects every query. Data a server pushes goes in with
-- setQueryData, as a TanStack app writes what a websocket brings.
--
-- Where TanStack returns a promise, fetchQuery and ensureQueryData yield for
-- the data and raise the failure; the rest return at once. Observers are told
-- of changes at once, not batched to the next tick. Mutations live in
-- quarry-react-query's useMutation, not in a cache here.

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
-- Filters, and which chosen queries invalidating refetches (active ones).
export type InvalidateFilters = {
	queryKey: Key.QueryKey?,
	exact: boolean?,
	type: QueryType?,
	stale: boolean?,
	fetchStatus: Query.FetchStatus?,
	predicate: ((query: Query.Query) -> boolean)?,
	refetchType: (QueryType | "none")?,
}
-- What every query starts from, under its own options.
export type Defaults = {
	retry: Retryer.RetryValue?,
	retryDelay: Retryer.RetryDelayValue?,
	gcTime: number?,
	staleTime: number?,
	refetchOnMount: (boolean | "always")?,
	retryOnMount: boolean?,
}
export type Config = {
	scheduler: Scheduler.Scheduler?,
	defaultOptions: { queries: Defaults? }?,
}
export type EnsureOptions = Observer.Options & { revalidateIfStale: boolean? }

-- A query type read back from a wider string.
local QUERY_TYPES: { [string]: QueryType } = {
	all = "all",
	active = "active",
	inactive = "inactive",
}

local QueryClient = {}
QueryClient.__index = QueryClient

-- A query's cache entry, typed by its definition (QueryClient.data).
export type Data<T> = {
	get: (self: Data<T>) -> T?,
	set: (self: Data<T>, value: T?) -> T?,
	update: (self: Data<T>, updater: (old: T?) -> T?) -> T?,
}

type QueryClientData = {
	_scheduler: Scheduler.Scheduler,
	_defaults: Defaults,
	_queries: { [string]: Query.Query },
	-- Hashes of the keys read typed, which only client:data may write.
	_claimed: { [string]: boolean },
	_observerClient: Observer.Client,
}

export type QueryClient = typeof(setmetatable(
	{} :: QueryClientData,
	QueryClient
))

local function matchesKey(query: Query.Query, filters: Filters): boolean
	local key = filters.queryKey
	if key == nil then
		return true
	elseif filters.exact then
		return query.queryHash == Key.hash(key)
	end
	return Key.matches(query.queryKey, key)
end

local function matches(query: Query.Query, filters: Filters?): boolean
	if filters == nil then
		return true
	elseif not matchesKey(query, filters) then
		return false
	end
	local kind = filters.type or "all"
	if kind ~= "all" and query:isActive() ~= (kind == "active") then
		return false
	elseif filters.stale ~= nil and query:isStale() ~= filters.stale then
		return false
	elseif
		filters.fetchStatus
		and filters.fetchStatus ~= query.state.fetchStatus
	then
		return false
	end
	return filters.predicate == nil or filters.predicate(query)
end

-- options, with each field it leaves out taken from defaults.
local function defaulted(defaults: Defaults, options: Observer.Options)
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

local function defaultsOf(config: Config?): Defaults
	local options = if config then config.defaultOptions else nil
	return if options and options.queries then options.queries else {}
end

function QueryClient.new(config: Config?): QueryClient
	local self: QueryClient
	local data: QueryClientData = {
		_scheduler = if config and config.scheduler
			then config.scheduler
			else Scheduler.task(),
		_defaults = defaultsOf(config),
		_queries = {},
		_claimed = {},
		_observerClient = {
			build = function(
				options: Observer.Options
			): Query.Query
				return self:_build(options)
			end,
			defaultQueryOptions = function(
				options: Observer.Options
			)
				return self:defaultQueryOptions(options)
			end,
		},
	}
	self = setmetatable(data, QueryClient)
	return self
end

function QueryClient.defaultQueryOptions(
	self: QueryClient,
	options: Observer.Options
): Observer.Options
	return defaulted(self._defaults, options)
end

-- The query for options' key, made when there is none.
function QueryClient._build(
	self: QueryClient,
	options: Observer.Options
): Query.Query
	local hash = Key.hash(options.queryKey)
	local existing: Query.Query? = self._queries[hash]
	if existing then
		return existing
	end
	local function remove(query: Query.Query)
		self:_remove(query)
	end
	local query =
		Query.new(options.queryKey, options, self._scheduler, remove)
	self._queries[hash] = query
	return query
end

function QueryClient._remove(self: QueryClient, query: Query.Query)
	if self._queries[query.queryHash] == query then
		query:destroy()
		self._queries[query.queryHash] = nil
	end
end

function QueryClient._find(self: QueryClient, queryKey: Key.QueryKey)
	return self._queries[Key.hash(queryKey)]
end

function QueryClient._findAll(self: QueryClient, filters: Filters?)
	local found: { Query.Query } = {}
	for _, query in self._queries do
		if matches(query, filters) then
			table.insert(found, query)
		end
	end
	return found
end

function QueryClient.getQueryData(self: QueryClient, key: Key.QueryKey): unknown
	local query = self:_find(key)
	return if query then query.state.data else nil
end

function QueryClient.getQueryState(self: QueryClient, key: Key.QueryKey)
	local query = self:_find(key)
	return if query then query.state else nil
end

-- Writes data, or what updater(old) returns, under key; nil writes nothing.
-- A key read typed (client:data, useQuery) is written only through
-- client:data, so its typed readers get its type: writing it here raises.
function QueryClient.setQueryData(
	self: QueryClient,
	key: Key.QueryKey,
	updater: unknown
): unknown
	local hash = Key.hash(key)
	if self._claimed[hash] then
		error(
			`{hash} is read typed (client:data, useQuery); `
				.. "write it with client:data(definition)",
			2
		)
	end
	return self:_write(key, updater)
end

function QueryClient._write(
	self: QueryClient,
	key: Key.QueryKey,
	updater: unknown
): unknown
	local update = Unknown.callable(updater)
	local data = if update then update(self:getQueryData(key)) else updater
	if data == nil then
		return nil
	end
	local options = self:defaultQueryOptions({ queryKey = key })
	return self:_build(options):setData(data, { manual = true })
end

-- Invariant: data under a key defined with queryOptions is what its queryFn
-- returned, initialData, or what its Data handle wrote, all its T, as long
-- as the key is not also written untyped with something else.
local function asData<T>(data: unknown): T?
	return data :: any
end

-- The cache entry of the query `definition` defines, read and written as
-- its data type: get() the data, set(value) it, or update(updater) it from
-- the data there. set and update write nothing for nil, and return what
-- they wrote. The key is claimed: setQueryData no longer writes it.
function QueryClient.data<T>(
	self: QueryClient,
	definition: Query.QueryOptions<T>
): Data<T>
	local client, key = self, definition.queryKey
	self._claimed[Key.hash(key)] = true
	-- Always an updater: setQueryData would take data that is a function
	-- for one.
	local function write(value: unknown): T?
		return asData(client:_write(key, function(): unknown
			return value
		end))
	end
	return {
		get = function(_: Data<T>): T?
			return asData(client:getQueryData(key))
		end,
		set = function(_: Data<T>, value: T?): T?
			return write(value)
		end,
		update = function(_: Data<T>, updater: (old: T?) -> T?): T?
			return write(updater(asData(client:getQueryData(key))))
		end,
	}
end

-- Marks the chosen queries stale and refetches those refetchType names.
function QueryClient.invalidateQueries(
	self: QueryClient,
	filters: InvalidateFilters?,
	options: Query.FetchOptions?
)
	for _, query in self:_findAll(filters) do
		query:invalidate()
	end
	local refetchType = if filters then filters.refetchType else nil
	if refetchType == "none" then
		return
	end
	local given: InvalidateFilters = filters or {}
	self:refetchQueries({
		queryKey = given.queryKey,
		exact = given.exact,
		stale = given.stale,
		fetchStatus = given.fetchStatus,
		predicate = given.predicate,
		type = QUERY_TYPES[refetchType or ""] or given.type or "active",
	}, options)
end

-- Fetches the chosen queries again, replacing a fetch out unless told not.
function QueryClient.refetchQueries(
	self: QueryClient,
	filters: Filters?,
	options: Query.FetchOptions?
)
	local cancelRefetch = options == nil or options.cancelRefetch ~= false
	for _, query in self:_findAll(filters) do
		if not query:isDisabled() then
			query:fetch(nil, { cancelRefetch = cancelRefetch })
		end
	end
end

-- Drops the fetches out, restoring the state from before them unless
-- options.revert is false.
function QueryClient.cancelQueries(
	self: QueryClient,
	filters: Filters?,
	options: Retryer.CancelOptions?
)
	local cancel: Retryer.CancelOptions = {
		revert = options == nil or options.revert ~= false,
		silent = options ~= nil and options.silent == true,
	}
	for _, query in self:_findAll(filters) do
		query:cancel(cancel)
	end
end

function QueryClient.removeQueries(self: QueryClient, filters: Filters?)
	for _, query in self:_findAll(filters) do
		self:_remove(query)
	end
end

function QueryClient.isFetching(self: QueryClient, filters: Filters?): number
	local count = 0
	for _, query in self:_findAll(filters) do
		if query.state.fetchStatus == "fetching" then
			count += 1
		end
	end
	return count
end

-- options under the defaults, without retries unless they ask for some.
function QueryClient._fetchOptions(self: QueryClient, options: Observer.Options)
	local given = self:defaultQueryOptions(options)
	if given.retry == nil then
		given.retry = false
	end
	return given
end

-- Yields for the data, fetching it when stale; raises the failure.
function QueryClient.fetchQuery(self: QueryClient, options: Observer.Options)
	local given = self:_fetchOptions(options)
	local query = self:_build(given)
	if not query:isStaleByTime(given.staleTime) then
		return query.state.data
	end
	query:fetch(given)
	local ok, value = query:await()
	if not ok then
		error(value, 0)
	end
	return value
end

-- Fetches the data when stale, without waiting for it or raising.
function QueryClient.prefetchQuery(self: QueryClient, options: Observer.Options)
	local given = self:_fetchOptions(options)
	local query = self:_build(given)
	if query:isStaleByTime(given.staleTime) then
		query:fetch(given)
	end
end

-- The cached data, or fetchQuery's when there is none.
function QueryClient.ensureQueryData(self: QueryClient, options: EnsureOptions)
	local given = self:defaultQueryOptions(options)
	local cached = self:_build(given).state.data
	if cached == nil then
		return self:fetchQuery(options)
	end
	local query = self:_build(given)
	if
		options.revalidateIfStale
		and query:isStaleByTime(given.staleTime)
	then
		self:prefetchQuery(options)
	end
	return cached
end

function QueryClient.clear(self: QueryClient)
	for _, query in self:_findAll(nil) do
		self:_remove(query)
	end
end

-- An observer of one query, as the React hooks use.
function QueryClient.observe(self: QueryClient, options: Observer.Options)
	return Observer.new(self._observerClient, options)
end

return QueryClient

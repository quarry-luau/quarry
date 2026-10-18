--!strict
-- A port of TanStack Query's QueryObserver (query-core/src/queryObserver.ts):
-- what a component holds to read one query. Subscribing fetches when there
-- is no data, or when it is stale and refetchOnMount allows; changing to
-- another key, or enabling the query, fetches stale data. getOptimisticResult
-- is the result for the next render, already showing a fetch subscribing will
-- start. select picks part of the data, shared with the last pick where it is
-- equal; a select that raises makes the result an error. A listener hears
-- only of changes to fields read through trackResult (to any field, until
-- one is read that way).
--
-- Not ported: refetchInterval, refetchOnWindowFocus, refetchOnReconnect (a
-- Roblox client has no such events), placeholderData, suspense, "static"
-- stale times and notifyOnChangeProps.

local Key = require("./Key")
local Query = require("./Query")

export type Options<T = unknown> = Query.Options<T>
-- What an observer reports, its data of type T.
export type Result<T = unknown> = {
	data: T?,
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

local RESULT_FIELDS = {
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

local Observer = {}
Observer.__index = Observer

type ObserverData = {
	_client: Client,
	_options: Options,
	_query: Query.Query,
	_listener: (() -> ())?,
	_result: Result?,
	_selectFrom: unknown,
	_selectFn: ((data: unknown) -> unknown)?,
	_selected: unknown,
	_tracked: { [string]: boolean },
	_handle: Query.Observer,
	_refetch: () -> (),
}

export type Observer = typeof(setmetatable({} :: ObserverData, Observer))

local function enabled(options: Options): boolean
	return options.enabled ~= false
end

local function isStale(query: Query.Query, options: Options): boolean
	return enabled(options) and query:isStaleByTime(options.staleTime)
end

local function shouldLoadOnMount(query: Query.Query, options: Options): boolean
	local state = query.state
	return enabled(options)
		and state.data == nil
		and not (
			state.status == "error"
			and options.retryOnMount == false
		)
end

local function shouldFetchOnMount(query: Query.Query, options: Options): boolean
	if shouldLoadOnMount(query, options) then
		return true
	elseif query.state.data == nil or not enabled(options) then
		return false
	end
	local refetch = options.refetchOnMount
	return refetch == "always"
		or (refetch ~= false and isStale(query, options))
end

local function shouldFetchOptionally(
	query: Query.Query,
	previousQuery: Query.Query,
	options: Options,
	previousOptions: Options
): boolean
	local changed = query ~= previousQuery or not enabled(previousOptions)
	return changed and isStale(query, options)
end

-- Invariant: a Result is a table whose fields are RESULT_FIELDS; reading one
-- by name is reading that field.
local function fieldsOf(result: Result): { [string]: unknown }
	return result :: any
end

-- Whether current differs from previous in a field tracked names, or in any
-- field when it names none.
local function changed(
	previous: Result,
	current: Result,
	tracked: { [string]: boolean }
): boolean
	local before, after = fieldsOf(previous), fieldsOf(current)
	local tracking = next(tracked) ~= nil
	for _, field in RESULT_FIELDS do
		if
			before[field] ~= after[field]
			and (not tracking or tracked[field])
		then
			return true
		end
	end
	return false
end

function Observer.new(client: Client, options: Options): Observer
	local defaulted = client.defaultQueryOptions(options)
	local self: Observer
	local handle: Query.Observer = {
		onQueryUpdate = function()
			self:_updateResult()
		end,
		options = function()
			return self._options
		end,
		isStale = function(): boolean
			return self._result ~= nil and self._result.isStale
		end,
	}
	local data: ObserverData = {
		_client = client,
		_options = defaulted,
		_query = client.build(defaulted),
		_listener = nil,
		_result = nil,
		_selectFrom = nil,
		_selectFn = nil,
		_selected = nil,
		_tracked = {},
		_handle = handle,
		_refetch = function()
			self:refetch()
		end,
	}
	self = setmetatable(data, Observer)
	return self
end

-- The data options.select picks, reused while data and select stay the same.
function Observer._select(
	self: Observer,
	data: unknown,
	options: Options
): (boolean, unknown)
	local select = options.select
	if select == nil or data == nil then
		return true, data
	elseif data == self._selectFrom and select == self._selectFn then
		return true, self._selected
	end
	local ok, picked = pcall(select, data)
	if not ok then
		return false, picked
	end
	local previous = if self._result then self._result.data else nil
	self._selectFrom, self._selectFn = data, select
	self._selected = Key.replaceEqualDeep(previous, picked)
	return true, self._selected
end

-- The status and error to show: the query's, or, for an optimistic result,
-- what they will be once the fetch subscribing starts is out.
function Observer._statusOf(
	self: Observer,
	query: Query.Query,
	options: Options,
	optimistic: boolean
): (Query.FetchStatus, Query.Status, unknown)
	local state = query.state
	if not optimistic then
		return state.fetchStatus, state.status, state.error
	end
	local fetches = if self._listener
		then shouldFetchOptionally(
			query,
			self._query,
			options,
			self._options
		)
		else shouldFetchOnMount(query, options)
	if not fetches then
		return state.fetchStatus, state.status, state.error
	elseif state.data == nil then
		return "fetching", "pending", nil
	end
	return "fetching", state.status, state.error
end

function Observer._createResult(
	self: Observer,
	query: Query.Query,
	options: Options,
	optimistic: boolean
): Result
	local state = query.state
	local fetchStatus: Query.FetchStatus, status: Query.Status, problem
	fetchStatus, status, problem =
		self:_statusOf(query, options, optimistic)
	local picked, data = self:_select(state.data, options)
	if not picked then
		status, problem = "error", data
		data = if self._result then self._result.data else nil
	end
	local fetching, pending = fetchStatus == "fetching", status == "pending"
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
		isError = status == "error",
		isFetching = fetching,
		isLoading = pending and fetching,
		isRefetching = fetching and not pending,
		isLoadingError = status == "error" and state.data == nil,
		isRefetchError = status == "error" and state.data ~= nil,
		isFetched = query:isFetched(),
		isStale = isStale(query, options),
		isEnabled = enabled(options),
		refetch = self._refetch,
	}
end

-- Rebuilds the result and tells the listener when it changed.
function Observer._updateResult(self: Observer)
	local previous = self._result
	local current = self:_createResult(self._query, self._options, false)
	self._result = current
	if not self._listener then
		return
	elseif previous == nil or changed(previous, current, self._tracked) then
		self._listener()
	end
end

function Observer._executeFetch(self: Observer, cancelRefetch: boolean?)
	self._query:fetch(self._options, { cancelRefetch = cancelRefetch })
end

-- Takes new options: moves to the query of a new key, and fetches when the
-- key changed or the query was enabled and its data is stale.
function Observer.setOptions(self: Observer, options: Options)
	local previousOptions, previousQuery = self._options, self._query
	self._options = self._client.defaultQueryOptions(options)
	self._query = self._client.build(self._options)
	if self._query ~= previousQuery and self._listener then
		previousQuery:removeObserver(self._handle)
		self._query:addObserver(self._handle)
	end
	self._query:setOptions(self._options)
	local mounted = self._listener ~= nil
	if
		mounted
		and shouldFetchOptionally(
			self._query,
			previousQuery,
			self._options,
			previousOptions
		)
	then
		self:_executeFetch()
	end
	self:_updateResult()
end

-- The result the next render shows, for options it is about to be given.
function Observer.getOptimisticResult(self: Observer, options: Options): Result
	local defaulted = self._client.defaultQueryOptions(options)
	local query = self._client.build(defaulted)
	return self:_createResult(query, defaulted, true)
end

function Observer.getCurrentResult(self: Observer): Result
	local result = self._result
		or self:_createResult(self._query, self._options, false)
	self._result = result
	return result
end

-- Calls listener on every change; fetches if the query should on mount.
-- Returns what unsubscribes.
function Observer.subscribe(self: Observer, listener: () -> ()): () -> ()
	self._listener = listener
	self._query:addObserver(self._handle)
	self._result = self:_createResult(self._query, self._options, false)
	if shouldFetchOnMount(self._query, self._options) then
		self:_executeFetch()
	end
	return function()
		if self._listener == listener then
			self._listener = nil
			self._query:removeObserver(self._handle)
		end
	end
end

function Observer.refetch(self: Observer, cancelRefetch: boolean?)
	self:_executeFetch(cancelRefetch ~= false)
end

-- result, as a view that records which of its fields are read.
function Observer.trackResult(self: Observer, result: Result): Result
	local fields = fieldsOf(result)
	local tracked = self._tracked
	local view = setmetatable({}, {
		__index = function(_: unknown, field: string): unknown
			tracked[field] = true
			return fields[field]
		end,
	})
	-- Invariant: every field read of the view is read from result.
	return (view :: any) :: Result
end

return Observer

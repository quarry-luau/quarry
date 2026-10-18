--!strict
-- A port of TanStack Query's Query (query-core/src/query.ts, v5.104): one cache entry, the data
-- under one key and how it was got. State changes go through one reducer and every change is told
-- to the observers. `fetch` runs the query function through a Retryer, once at a time: a second
-- fetch joins the one out, or, with `cancelRefetch` while data is shown, replaces it. `cancel` with
-- `revert` restores the state from before the fetch. Once nothing observes it, the entry is removed
-- after `gcTime` seconds (the longest any observer asked for; never with math.huge). Data cannot be
-- nil: a query function that returns nothing fails.

local Key = require("./Key")
local Retryer = require("./Retryer")
local Scheduler = require("./Scheduler")

export type Status = "pending" | "error" | "success"
export type FetchStatus = "fetching" | "idle"
export type State = {
	data: unknown,
	dataUpdateCount: number,
	-- When the data last changed, on the scheduler's clock; 0 before.
	dataUpdatedAt: number,
	error: unknown,
	errorUpdateCount: number,
	errorUpdatedAt: number,
	fetchFailureCount: number,
	fetchFailureReason: unknown,
	isInvalidated: boolean,
	status: Status,
	fetchStatus: FetchStatus,
}
export type QueryFunction = (context: { queryKey: Key.QueryKey }) -> unknown
export type Options = {
	queryKey: Key.QueryKey,
	queryFn: QueryFunction?,
	retry: Retryer.RetryValue?,
	retryDelay: Retryer.RetryDelayValue?,
	gcTime: number?,
	initialData: unknown,
}
export type FetchOptions = { cancelRefetch: boolean? }
export type SetDataOptions = { updatedAt: number?, manual: boolean? }
-- What the entry needs of an observer.
export type Observer = {
	onQueryUpdate: () -> (),
	options: () -> { enabled: boolean?, queryFn: QueryFunction? },
	isStale: () -> boolean,
}
export type Action =
	{ type: "failed", failureCount: number, error: unknown }
	| { type: "fetch" }
	| { type: "success", data: unknown, dataUpdatedAt: number?, manual: boolean? }
	| { type: "error", error: unknown }
	| { type: "invalidate" }
	| { type: "revert", state: State }
export type Query = {
	queryKey: Key.QueryKey,
	queryHash: string,
	state: State,
	options: Options,
	observers: { Observer },
	setOptions: (self: Query, options: Options) -> (),
	setData: (self: Query, data: unknown, options: SetDataOptions?) -> unknown,
	cancel: (self: Query, options: Retryer.CancelOptions?) -> (),
	destroy: (self: Query) -> (),
	isActive: (self: Query) -> boolean,
	isDisabled: (self: Query) -> boolean,
	isFetched: (self: Query) -> boolean,
	isStale: (self: Query) -> boolean,
	isStaleByTime: (self: Query, staleTime: number?) -> boolean,
	addObserver: (self: Query, observer: Observer) -> (),
	removeObserver: (self: Query, observer: Observer) -> (),
	invalidate: (self: Query) -> (),
	fetch: (self: Query, options: Options?, fetchOptions: FetchOptions?) -> (),
	-- Yields until the fetch out settles: true and the data, or false and the error.
	await: (self: Query) -> (boolean, unknown),
}

local DEFAULT_GC_SECONDS = 300

local QueryModule = {}

-- Invariant: `changes` names only fields of State, each with a value of that field's type, so the
-- merged table is a State.
local function merged(state: State, changes: { [string]: unknown }): State
	local result: any = table.clone(state)
	for field, value in changes do
		result[field] = value
	end
	return result
end

local function defaultState(options: Options, now: number): State
	local data = options.initialData
	local hasData = data ~= nil
	return {
		data = data,
		dataUpdateCount = 0,
		dataUpdatedAt = if hasData then now else 0,
		error = nil,
		errorUpdateCount = 0,
		errorUpdatedAt = 0,
		fetchFailureCount = 0,
		fetchFailureReason = nil,
		isInvalidated = false,
		status = if hasData then "success" else "pending",
		fetchStatus = "idle",
	}
end

local function fetchState(state: State): State
	local changes: { [string]: unknown } = { fetchFailureCount = 0, fetchFailureReason = nil, fetchStatus = "fetching" }
	if state.data == nil then
		changes.error = nil
		changes.status = "pending"
	end
	return merged(state, changes)
end

local function successState(state: State, data: unknown, dataUpdatedAt: number, manual: boolean): State
	local changes: { [string]: unknown } = {
		data = data,
		dataUpdatedAt = dataUpdatedAt,
		error = nil,
		isInvalidated = false,
		status = "success",
		dataUpdateCount = state.dataUpdateCount + 1,
	}
	if not manual then
		changes.fetchStatus = "idle"
		changes.fetchFailureCount = 0
		changes.fetchFailureReason = nil
	end
	return merged(state, changes)
end

-- The state after `action`, `now` being the scheduler's clock.
local function reduce(state: State, action: Action, now: number): State
	if action.type == "failed" then
		return merged(state, { fetchFailureCount = action.failureCount, fetchFailureReason = action.error })
	elseif action.type == "fetch" then
		return fetchState(state)
	elseif action.type == "success" then
		return successState(state, action.data, action.dataUpdatedAt or now, action.manual == true)
	elseif action.type == "error" then
		return merged(state, {
			error = action.error,
			errorUpdateCount = state.errorUpdateCount + 1,
			errorUpdatedAt = now,
			fetchFailureCount = state.fetchFailureCount + 1,
			fetchFailureReason = action.error,
			fetchStatus = "idle",
			status = "error",
			-- Data kept through a background error is stale; no data always is.
			isInvalidated = true,
		})
	elseif action.type == "invalidate" then
		return merged(state, { isInvalidated = true })
	end
	return merged(action.state, { fetchStatus = "idle" })
end

function QueryModule.new(
	queryKey: Key.QueryKey,
	options: Options,
	scheduler: Scheduler.Scheduler,
	remove: (query: Query) -> ()
): Query
	local retryer: Retryer.Retryer? = nil
	local revertState: State? = nil
	local gcTime = 0
	local cancelGc: (() -> ())? = nil

	local self: Query
	local function dispatch(action: Action)
		self.state = reduce(self.state, action, scheduler.now())
		if action.type == "success" then
			revertState = if action.manual then self.state else nil
		end
		for _, observer in table.clone(self.observers) do
			observer.onQueryUpdate()
		end
	end
	local function clearGc()
		if cancelGc then
			cancelGc()
			cancelGc = nil
		end
	end
	local function scheduleGc()
		clearGc()
		if gcTime ~= math.huge then
			cancelGc = scheduler.delay(gcTime, function()
				cancelGc = nil
				if #self.observers == 0 and self.state.fetchStatus == "idle" then
					remove(self)
				end
			end)
		end
	end
	-- Waits for `current`, the fetch's retryer, and settles the state as it ends.
	local function settle(current: Retryer.Retryer)
		local ok, value = current.await()
		if ok and value == nil then
			ok, value = false, `{self.queryHash} data is nil`
		end
		local cancelled = if ok then nil else Retryer.cancelled(value)
		if ok then
			self:setData(value)
		elseif cancelled == nil or not (cancelled.silent or cancelled.revert) then
			dispatch({ type = "error", error = value })
		end
		if retryer == current then
			retryer = nil
		end
		scheduleGc()
	end
	-- The fetch out, unless it can be joined: then nil, after letting its retries go on.
	local function replaceable(query: Query, fetchOptions: FetchOptions?): (boolean, Retryer.Retryer?)
		local previous = retryer
		if query.state.fetchStatus == "idle" or previous == nil or previous.status() == "rejected" then
			return true, nil
		elseif query.state.data ~= nil and fetchOptions ~= nil and fetchOptions.cancelRefetch == true then
			return true, previous
		end
		previous.continueRetry()
		return false, nil
	end
	local function borrowQueryFn(query: Query)
		if query.options.queryFn ~= nil then
			return
		end
		for _, observer in query.observers do
			local borrowed = observer.options().queryFn
			if borrowed then
				local given = table.clone(query.options)
				given.queryFn = borrowed
				query.options = given
				return
			end
		end
	end
	local function start(query: Query): Retryer.Retryer
		return Retryer.new({
			fn = function(): unknown
				local queryFn = query.options.queryFn
				if queryFn == nil then
					error(`Missing queryFn: '{query.queryHash}'`, 0)
				end
				return queryFn({ queryKey = query.queryKey })
			end,
			onCancel = function(cancelled: Retryer.CancelledError)
				if cancelled.revert and revertState then
					dispatch({ type = "revert", state = revertState })
				end
			end,
			onFail = function(failureCount: number, problem: unknown)
				dispatch({ type = "failed", failureCount = failureCount, error = problem })
			end,
			retry = query.options.retry,
			retryDelay = query.options.retryDelay,
		}, scheduler)
	end

	self = {
		queryKey = queryKey,
		queryHash = Key.hash(queryKey),
		state = defaultState(options, scheduler.now()),
		options = options,
		observers = {},
		setOptions = function(query: Query, given: Options)
			query.options = given
			gcTime = math.max(gcTime, given.gcTime or DEFAULT_GC_SECONDS)
			if query.state.data == nil and given.initialData ~= nil then
				dispatch({ type = "success", data = given.initialData, manual = true })
			end
		end,
		setData = function(query: Query, data: unknown, given: SetDataOptions?): unknown
			local shared = Key.replaceEqualDeep(query.state.data, data)
			dispatch({
				type = "success",
				data = shared,
				dataUpdatedAt = if given then given.updatedAt else nil,
				manual = given ~= nil and given.manual == true,
			})
			return shared
		end,
		cancel = function(_: Query, given: Retryer.CancelOptions?)
			if retryer then
				retryer.cancel(given)
			end
		end,
		destroy = function(query: Query)
			clearGc()
			query:cancel({ silent = true })
		end,
		isActive = function(query: Query): boolean
			for _, observer in query.observers do
				if observer.options().enabled ~= false then
					return true
				end
			end
			return false
		end,
		isDisabled = function(query: Query): boolean
			if #query.observers > 0 then
				return not query:isActive()
			end
			return not query:isFetched()
		end,
		isFetched = function(query: Query): boolean
			return query.state.dataUpdateCount + query.state.errorUpdateCount > 0
		end,
		isStale = function(query: Query): boolean
			if #query.observers == 0 then
				return query.state.data == nil or query.state.isInvalidated
			end
			for _, observer in query.observers do
				if observer.isStale() then
					return true
				end
			end
			return false
		end,
		isStaleByTime = function(query: Query, staleTime: number?): boolean
			local state = query.state
			if state.data == nil then
				return true
			elseif state.isInvalidated then
				return true
			end
			return scheduler.now() - state.dataUpdatedAt >= (staleTime or 0)
		end,
		addObserver = function(query: Query, observer: Observer)
			if table.find(query.observers, observer) == nil then
				table.insert(query.observers, observer)
				clearGc()
			end
		end,
		removeObserver = function(query: Query, observer: Observer)
			local index = table.find(query.observers, observer)
			if index == nil then
				return
			end
			table.remove(query.observers, index)
			if #query.observers == 0 then
				if retryer then
					retryer.cancelRetry()
				end
				scheduleGc()
			end
		end,
		invalidate = function(query: Query)
			if not query.state.isInvalidated then
				dispatch({ type = "invalidate" })
			end
		end,
		fetch = function(query: Query, given: Options?, fetchOptions: FetchOptions?)
			local fresh, previous = replaceable(query, fetchOptions)
			if not fresh then
				return
			end
			if given then
				query:setOptions(given)
			end
			borrowQueryFn(query)
			revertState = query.state
			if query.state.fetchStatus == "idle" then
				dispatch({ type = "fetch" })
			end
			local current = start(query)
			retryer = current
			if previous then
				previous.cancel({ silent = true })
			end
			current.start()
			scheduler.spawn(function()
				settle(current)
			end)
		end,
		await = function(query: Query): (boolean, unknown)
			while true do
				local current = retryer
				if current == nil then
					local failed = query.state.status == "error"
					return not failed, if failed then query.state.error else query.state.data
				end
				local ok, value = current.await()
				local cancelled = if ok then nil else Retryer.cancelled(value)
				if ok then
					return true, query.state.data
				elseif cancelled == nil then
					return false, value
				elseif not (cancelled.silent and retryer ~= current) then
					local kept = cancelled.revert and query.state.data ~= nil
					return kept, if kept then query.state.data else value
				end
			end
		end,
	}
	self:setOptions(options)
	scheduleGc()
	return self
end

return QueryModule

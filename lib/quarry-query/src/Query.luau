--!strict
-- A port of TanStack Query's Query (query-core/src/query.ts and removable.ts):
-- one cache entry, the data under one key and how it was got. State changes
-- go through one reducer and every change is told to the observers. fetch
-- runs the query function through a Retryer, once at a time: a second fetch
-- joins the one out, or, with cancelRefetch while data is shown, replaces it.
-- cancel with revert restores the state from before the fetch. Once nothing
-- observes it, the entry is removed after gcTime seconds (the longest any
-- observer asked for; never with math.huge). A query function that returns
-- nothing fails: data cannot be nil.

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
-- What fetches a query's data, T.
export type QueryFunction<T = unknown> = (
	context: { queryKey: Key.QueryKey }
) -> T
-- A query's options, as TanStack's QueryObserverOptions holds them: what the
-- query is (key, queryFn whose data is T, retries, gcTime, initialData) and
-- how an observer reads it. A query reads only the first part.
export type Options<T = unknown> = {
	queryKey: Key.QueryKey,
	queryFn: QueryFunction<T>?,
	retry: Retryer.RetryValue?,
	retryDelay: Retryer.RetryDelayValue?,
	gcTime: number?,
	initialData: T?,
	-- Whether the query fetches by itself (true).
	enabled: boolean?,
	-- Seconds data stays fresh (0); math.huge until invalidated or set.
	staleTime: number?,
	-- Whether subscribing fetches stale data: true, false or "always".
	refetchOnMount: (boolean | "always")?,
	-- Whether subscribing fetches again after an error (true).
	retryOnMount: boolean?,
	-- Picks what the result holds from the data.
	select: ((data: unknown) -> unknown)?,
}
export type FetchOptions = { cancelRefetch: boolean? }
export type SetDataOptions = { updatedAt: number?, manual: boolean? }
-- What an entry needs of an observer.
export type Observer = {
	onQueryUpdate: () -> (),
	options: () -> { enabled: boolean?, queryFn: QueryFunction? },
	isStale: () -> boolean,
}
export type Action =
	{ type: "failed", failureCount: number, error: unknown }
	| { type: "fetch" }
	| {
		type: "success",
		data: unknown,
		dataUpdatedAt: number?,
		manual: boolean?,
	}
	| { type: "error", error: unknown }
	| { type: "invalidate" }
	| { type: "revert", state: State }

local DEFAULT_GC_SECONDS = 300

local Query = {}
Query.__index = Query

type QueryData = {
	queryKey: Key.QueryKey,
	queryHash: string,
	state: State,
	options: Options,
	observers: { Observer },
	_scheduler: Scheduler.Scheduler,
	_remove: (query: Query) -> (),
	_retryer: Retryer.Retryer?,
	_revertState: State?,
	_gcTime: number,
	_cancelGc: (() -> ())?,
}

export type Query = typeof(setmetatable({} :: QueryData, Query))

local function defaultState(options: Options, now: number): State
	local data = options.initialData
	return {
		data = data,
		dataUpdateCount = 0,
		dataUpdatedAt = if data ~= nil then now else 0,
		error = nil,
		errorUpdateCount = 0,
		errorUpdatedAt = 0,
		fetchFailureCount = 0,
		fetchFailureReason = nil,
		isInvalidated = false,
		status = if data ~= nil then "success" else "pending",
		fetchStatus = "idle",
	}
end

local function fetchState(state: State): State
	local next = table.clone(state)
	next.fetchFailureCount = 0
	next.fetchFailureReason = nil
	next.fetchStatus = "fetching"
	if state.data == nil then
		next.error = nil
		next.status = "pending"
	end
	return next
end

local function successState(
	state: State,
	data: unknown,
	at: number,
	manual: boolean
): State
	local next = table.clone(state)
	next.data = data
	next.dataUpdatedAt = at
	next.dataUpdateCount = state.dataUpdateCount + 1
	next.error = nil
	next.isInvalidated = false
	next.status = "success"
	if not manual then
		next.fetchStatus = "idle"
		next.fetchFailureCount = 0
		next.fetchFailureReason = nil
	end
	return next
end

-- Data kept through an error is stale; no data always is.
local function errorState(state: State, problem: unknown, now: number): State
	local next = table.clone(state)
	next.error = problem
	next.errorUpdateCount = state.errorUpdateCount + 1
	next.errorUpdatedAt = now
	next.fetchFailureCount = state.fetchFailureCount + 1
	next.fetchFailureReason = problem
	next.fetchStatus = "idle"
	next.status = "error"
	next.isInvalidated = true
	return next
end

local function failedState(state: State, count: number, problem: unknown): State
	local next = table.clone(state)
	next.fetchFailureCount = count
	next.fetchFailureReason = problem
	return next
end

local function invalidatedState(state: State): State
	local next = table.clone(state)
	next.isInvalidated = true
	return next
end

local function revertedState(state: State): State
	local next = table.clone(state)
	next.fetchStatus = "idle"
	return next
end

-- The state after action, now being the scheduler's clock.
local function reduce(state: State, action: Action, now: number): State
	if action.type == "failed" then
		return failedState(state, action.failureCount, action.error)
	elseif action.type == "fetch" then
		return fetchState(state)
	elseif action.type == "success" then
		local at = action.dataUpdatedAt or now
		return successState(
			state,
			action.data,
			at,
			action.manual == true
		)
	elseif action.type == "error" then
		return errorState(state, action.error, now)
	elseif action.type == "invalidate" then
		return invalidatedState(state)
	end
	return revertedState(action.state)
end

function Query.new(
	queryKey: Key.QueryKey,
	options: Options,
	scheduler: Scheduler.Scheduler,
	remove: (query: Query) -> ()
): Query
	local data: QueryData = {
		queryKey = queryKey,
		queryHash = Key.hash(queryKey),
		state = defaultState(options, scheduler.now()),
		options = options,
		observers = {},
		_scheduler = scheduler,
		_remove = remove,
		_retryer = nil,
		_revertState = nil,
		_gcTime = 0,
		_cancelGc = nil,
	}
	local self = setmetatable(data, Query)
	self:setOptions(options)
	self:_scheduleGc()
	return self
end

function Query._dispatch(self: Query, action: Action)
	self.state = reduce(self.state, action, self._scheduler.now())
	if action.type == "success" then
		self._revertState = if action.manual then self.state else nil
	end
	for _, observer in table.clone(self.observers) do
		observer.onQueryUpdate()
	end
end

function Query._clearGc(self: Query)
	if self._cancelGc then
		self._cancelGc()
		self._cancelGc = nil
	end
end

-- Removes the entry after gcTime, if nothing observes or fetches it then.
function Query._scheduleGc(self: Query)
	self:_clearGc()
	if self._gcTime == math.huge then
		return
	end
	self._cancelGc = self._scheduler.delay(self._gcTime, function()
		self._cancelGc = nil
		if
			#self.observers == 0
			and self.state.fetchStatus == "idle"
		then
			self._remove(self)
		end
	end)
end

function Query.setOptions(self: Query, options: Options)
	self.options = options
	self._gcTime =
		math.max(self._gcTime, options.gcTime or DEFAULT_GC_SECONDS)
	if self.state.data == nil and options.initialData ~= nil then
		self:_dispatch({
			type = "success",
			data = options.initialData,
			manual = true,
		})
	end
end

-- Writes data, sharing what is equal with the data before; returns it.
function Query.setData(self: Query, data: unknown, options: SetDataOptions?)
	local shared = Key.replaceEqualDeep(self.state.data, data)
	self:_dispatch({
		type = "success",
		data = shared,
		dataUpdatedAt = if options then options.updatedAt else nil,
		manual = options ~= nil and options.manual == true,
	})
	return shared
end

function Query.cancel(self: Query, options: Retryer.CancelOptions?)
	if self._retryer then
		self._retryer:cancel(options)
	end
end

function Query.destroy(self: Query)
	self:_clearGc()
	self:cancel({ silent = true })
end

function Query.isActive(self: Query): boolean
	for _, observer in self.observers do
		if observer.options().enabled ~= false then
			return true
		end
	end
	return false
end

function Query.isFetched(self: Query): boolean
	return self.state.dataUpdateCount + self.state.errorUpdateCount > 0
end

function Query.isDisabled(self: Query): boolean
	if #self.observers > 0 then
		return not self:isActive()
	end
	return not self:isFetched()
end

function Query.isStale(self: Query): boolean
	if #self.observers == 0 then
		return self.state.data == nil or self.state.isInvalidated
	end
	for _, observer in self.observers do
		if observer.isStale() then
			return true
		end
	end
	return false
end

function Query.isStaleByTime(self: Query, staleTime: number?): boolean
	local state = self.state
	if state.data == nil or state.isInvalidated then
		return true
	end
	local age = self._scheduler.now() - state.dataUpdatedAt
	return age >= (staleTime or 0)
end

function Query.addObserver(self: Query, observer: Observer)
	if table.find(self.observers, observer) == nil then
		table.insert(self.observers, observer)
		self:_clearGc()
	end
end

-- Forgets observer; once none is left, retries stop and removal is due.
function Query.removeObserver(self: Query, observer: Observer)
	local index = table.find(self.observers, observer)
	if index == nil then
		return
	end
	table.remove(self.observers, index)
	if #self.observers > 0 then
		return
	end
	if self._retryer then
		self._retryer:cancelRetry()
	end
	self:_scheduleGc()
end

function Query.invalidate(self: Query)
	if not self.state.isInvalidated then
		self:_dispatch({ type = "invalidate" })
	end
end

-- Whether a new fetch should start, and the one out it replaces, if any; a
-- joined fetch is told to keep retrying.
function Query._replaces(
	self: Query,
	options: FetchOptions?
): (boolean, Retryer.Retryer?)
	local out = self._retryer
	if self.state.fetchStatus == "idle" or out == nil then
		return true, nil
	elseif out:status() == "rejected" then
		return true, nil
	elseif self.state.data ~= nil and options and options.cancelRefetch then
		return true, out
	end
	out:continueRetry()
	return false, nil
end

-- Takes the query function of the first observer that has one, when the
-- entry has none (set with setQueryData, then observed).
function Query._borrowQueryFn(self: Query)
	if self.options.queryFn ~= nil then
		return
	end
	for _, observer in self.observers do
		local borrowed = observer.options().queryFn
		if borrowed then
			local options = table.clone(self.options)
			options.queryFn = borrowed
			self.options = options
			return
		end
	end
end

function Query._call(self: Query): unknown
	local queryFn = self.options.queryFn
	if queryFn == nil then
		error(`Missing queryFn: '{self.queryHash}'`, 0)
	end
	return queryFn({ queryKey = self.queryKey })
end

function Query._newRetryer(self: Query): Retryer.Retryer
	return Retryer.new({
		fn = function(): unknown
			return self:_call()
		end,
		onCancel = function(cancelled: Retryer.CancelledError)
			if cancelled.revert and self._revertState then
				self:_dispatch({
					type = "revert",
					state = self._revertState,
				})
			end
		end,
		onFail = function(count: number, problem: unknown)
			self:_dispatch({
				type = "failed",
				failureCount = count,
				error = problem,
			})
		end,
		retry = self.options.retry,
		retryDelay = self.options.retryDelay,
	}, self._scheduler)
end

-- Waits for retryer to settle and writes what it ended with.
function Query._settle(self: Query, retryer: Retryer.Retryer)
	local ok, value = retryer:await()
	if ok and value == nil then
		ok, value = false, `{self.queryHash} data is nil`
	end
	local cancelled = if ok then nil else Retryer.cancelled(value)
	if ok then
		self:setData(value)
	elseif not (cancelled and (cancelled.silent or cancelled.revert)) then
		self:_dispatch({ type = "error", error = value })
	end
	if self._retryer == retryer then
		self._retryer = nil
	end
	self:_scheduleGc()
end

-- Fetches the data, unless a fetch out can be joined.
function Query.fetch(self: Query, options: Options?, fetch: FetchOptions?)
	local starts, replaced = self:_replaces(fetch)
	if not starts then
		return
	end
	if options then
		self:setOptions(options)
	end
	self:_borrowQueryFn()
	self._revertState = self.state
	if self.state.fetchStatus == "idle" then
		self:_dispatch({ type = "fetch" })
	end
	local retryer = self:_newRetryer()
	self._retryer = retryer
	if replaced then
		replaced:cancel({ silent = true })
	end
	retryer:start()
	self._scheduler.spawn(function()
		self:_settle(retryer)
	end)
end

-- Yields until the fetch out settles: true and the data, or false and the
-- error. A fetch replaced by another is waited through.
function Query.await(self: Query): (boolean, unknown)
	while true do
		local retryer = self._retryer
		if retryer == nil then
			local failed = self.state.status == "error"
			local value = if failed
				then self.state.error
				else self.state.data
			return not failed, value
		end
		local ok, value = retryer:await()
		local cancelled = if ok then nil else Retryer.cancelled(value)
		if ok then
			return true, self.state.data
		elseif cancelled == nil then
			return false, value
		elseif not (cancelled.silent and self._retryer ~= retryer) then
			local kept = cancelled.revert and self.state.data ~= nil
			return kept, if kept then self.state.data else value
		end
	end
end

return Query

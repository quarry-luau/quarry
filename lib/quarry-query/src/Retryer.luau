--!strict
-- A port of TanStack Query's retryer (query-core/src/retryer.ts): runs a
-- function that may yield, tries a failure again after retryDelay while
-- retry allows, and can be cancelled. Where TanStack returns a promise,
-- await yields until the run settles. Pausing while offline or unfocused is
-- left out: a Roblox client has neither state.

local Scheduler = require("./Scheduler")
local Unknown = require("./Unknown")

export type RetryValue =
	boolean
	| number
	| (failureCount: number, error: unknown) -> boolean
export type RetryDelayValue =
	number
	| (failureCount: number, error: unknown) -> number
export type CancelOptions = { revert: boolean?, silent: boolean? }
-- What a cancelled run fails with: revert asks the caller to restore the
-- state from before the run, silent to wait for the run that replaced it.
export type CancelledError = {
	name: "CancelledError",
	revert: boolean,
	silent: boolean,
}
export type Status = "pending" | "resolved" | "rejected"
export type Config = {
	fn: () -> unknown,
	onCancel: ((error: CancelledError) -> ())?,
	onFail: ((failureCount: number, error: unknown) -> ())?,
	retry: RetryValue?,
	retryDelay: RetryDelayValue?,
}

local DEFAULT_RETRY = 3
local MAX_RETRY_DELAY = 30

local Retryer = {}
Retryer.__index = Retryer

type RetryerData = {
	_config: Config,
	_scheduler: Scheduler.Scheduler,
	_status: Status,
	_result: unknown,
	_failureCount: number,
	_isRetryCancelled: boolean,
	_waiting: { thread },
}

export type Retryer = typeof(setmetatable({} :: RetryerData, Retryer))

function Retryer.cancelledError(options: CancelOptions?): CancelledError
	return {
		name = "CancelledError",
		revert = options ~= nil and options.revert == true,
		silent = options ~= nil and options.silent == true,
	}
end

-- Invariant: cancelledError builds every table named "CancelledError" a
-- retryer fails with, so a failure carrying that name is one.
local function asCancelled(value: Unknown.Fields): CancelledError
	return value :: any
end

-- The failure as a CancelledError, or nil when it is another failure.
function Retryer.cancelled(value: unknown): CancelledError?
	local fields = Unknown.fields(value)
	if fields == nil or fields.name ~= "CancelledError" then
		return nil
	end
	return asCancelled(fields)
end

-- 1 second, doubling with every failure, up to 30.
function Retryer.defaultRetryDelay(failureCount: number): number
	return math.min(2 ^ failureCount, MAX_RETRY_DELAY)
end

local function shouldRetry(retry: RetryValue?, count: number, problem: unknown)
	local given = if retry == nil then DEFAULT_RETRY else retry
	if type(given) == "boolean" then
		return given
	elseif type(given) == "number" then
		return count < given
	end
	return given(count, problem)
end

local function delayFor(
	delay: RetryDelayValue?,
	count: number,
	problem: unknown
)
	if delay == nil then
		return Retryer.defaultRetryDelay(count)
	elseif type(delay) == "number" then
		return delay
	end
	return delay(count, problem)
end

function Retryer.new(config: Config, scheduler: Scheduler.Scheduler): Retryer
	local data: RetryerData = {
		_config = config,
		_scheduler = scheduler,
		_status = "pending",
		_result = nil,
		_failureCount = 0,
		_isRetryCancelled = false,
		_waiting = {},
	}
	return setmetatable(data, Retryer)
end

-- Ends the run as settled with value, resuming whoever waits for it.
function Retryer._settle(self: Retryer, settled: Status, value: unknown)
	if self._status ~= "pending" then
		return
	end
	self._status = settled
	self._result = value
	local waiting = self._waiting
	self._waiting = {}
	for _, thread in waiting do
		self._scheduler.resume(thread, settled == "resolved", value)
	end
end

-- Schedules another attempt after a failure, or ends the run with it.
function Retryer._retry(self: Retryer, problem: unknown)
	local config = self._config
	local count = self._failureCount
	if
		self._isRetryCancelled
		or not shouldRetry(config.retry, count, problem)
	then
		self:_settle("rejected", problem)
		return
	end
	local seconds = delayFor(config.retryDelay, count, problem)
	self._failureCount = count + 1
	if config.onFail then
		config.onFail(self._failureCount, problem)
	end
	self._scheduler.delay(seconds, function()
		if self._isRetryCancelled then
			self:_settle("rejected", problem)
		else
			self:_run()
		end
	end)
end

-- Makes one attempt.
function Retryer._run(self: Retryer)
	if self._status ~= "pending" then
		return
	end
	local ok, value = pcall(self._config.fn)
	if self._status ~= "pending" then
		return
	elseif ok then
		self:_settle("resolved", value)
	else
		self:_retry(value)
	end
end

-- Fails the run with a CancelledError, unless it has already settled.
function Retryer.cancel(self: Retryer, options: CancelOptions?)
	if self._status ~= "pending" then
		return
	end
	local cancelled = Retryer.cancelledError(options)
	self:_settle("rejected", cancelled)
	if self._config.onCancel then
		self._config.onCancel(cancelled)
	end
end

-- Stops further retries; the attempt out still finishes.
function Retryer.cancelRetry(self: Retryer)
	self._isRetryCancelled = true
end

function Retryer.continueRetry(self: Retryer)
	self._isRetryCancelled = false
end

function Retryer.start(self: Retryer)
	self._scheduler.spawn(function()
		self:_run()
	end)
end

function Retryer.status(self: Retryer): Status
	return self._status
end

-- Yields until the run settles: true and the data, or false and the error.
function Retryer.await(self: Retryer): (boolean, unknown)
	if self._status ~= "pending" then
		return self._status == "resolved", self._result
	end
	table.insert(self._waiting, coroutine.running())
	return coroutine.yield()
end

return Retryer

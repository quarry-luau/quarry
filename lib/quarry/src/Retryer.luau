--!strict
-- A port of TanStack Query's retryer (query-core/src/retryer.ts, v5.104): runs a function that may
-- yield, retries a failure after `retryDelay` while `retry` allows, and can be cancelled. Where
-- TanStack returns a promise, `await` yields until the run settles. Pausing while offline or
-- unfocused is left out: a Roblox client has neither state.

local Scheduler = require("./Scheduler")
local Unknown = require("./Unknown")

export type RetryValue = boolean | number | (failureCount: number, error: unknown) -> boolean
export type RetryDelayValue = number | (failureCount: number, error: unknown) -> number
export type CancelOptions = { revert: boolean?, silent: boolean? }
-- What a cancelled run fails with: `revert` asks the caller to restore the state from before the
-- run, `silent` to wait for the run that replaced it instead.
export type CancelledError = { name: "CancelledError", revert: boolean, silent: boolean }
export type Status = "pending" | "resolved" | "rejected"
export type Config = {
	fn: () -> unknown,
	onCancel: ((error: CancelledError) -> ())?,
	onFail: ((failureCount: number, error: unknown) -> ())?,
	retry: RetryValue?,
	retryDelay: RetryDelayValue?,
}
export type Retryer = {
	cancel: (options: CancelOptions?) -> (),
	-- Stops further retries; the attempt out still finishes.
	cancelRetry: () -> (),
	continueRetry: () -> (),
	start: () -> (),
	status: () -> Status,
	-- Yields until the run settles: true and the data, or false and the error.
	await: () -> (boolean, unknown),
}

local DEFAULT_RETRY = 3
local MAX_RETRY_DELAY = 30

local Retryer = {}

function Retryer.cancelledError(options: CancelOptions?): CancelledError
	return {
		name = "CancelledError",
		revert = options ~= nil and options.revert == true,
		silent = options ~= nil and options.silent == true,
	}
end

-- Invariant: `cancelledError` builds every table whose `name` is "CancelledError" the retryer
-- fails with, so a failure carrying that name is one.
local function asCancelled(value: Unknown.Fields): CancelledError
	return value :: any
end

-- The failure as a CancelledError, or nil when it is another failure.
function Retryer.cancelled(value: unknown): CancelledError?
	local fields = Unknown.fields(value)
	return if fields ~= nil and fields.name == "CancelledError" then asCancelled(fields) else nil
end

-- 1 second, doubling with every failure, up to 30.
function Retryer.defaultRetryDelay(failureCount: number): number
	return math.min(2 ^ failureCount, MAX_RETRY_DELAY)
end

local function shouldRetry(retry: RetryValue?, failureCount: number, problem: unknown): boolean
	local given = if retry == nil then DEFAULT_RETRY else retry
	if type(given) == "boolean" then
		return given
	elseif type(given) == "number" then
		return failureCount < given
	end
	return given(failureCount, problem)
end

local function delayFor(retryDelay: RetryDelayValue?, failureCount: number, problem: unknown): number
	if retryDelay == nil then
		return Retryer.defaultRetryDelay(failureCount)
	elseif type(retryDelay) == "number" then
		return retryDelay
	end
	return retryDelay(failureCount, problem)
end

function Retryer.new(config: Config, scheduler: Scheduler.Scheduler): Retryer
	local status: Status = "pending"
	local result: unknown = nil
	local failureCount = 0
	local isRetryCancelled = false
	local waiting: { thread } = {}

	local function settle(settled: Status, value: unknown)
		if status ~= "pending" then
			return
		end
		status = settled
		result = value
		local threads = waiting
		waiting = {}
		for _, thread in threads do
			scheduler.resume(thread, settled == "resolved", value)
		end
	end

	local function run()
		if status ~= "pending" then
			return
		end
		local ok, value = pcall(config.fn)
		if status ~= "pending" then
			return
		elseif ok then
			settle("resolved", value)
			return
		end
		if isRetryCancelled or not shouldRetry(config.retry, failureCount, value) then
			settle("rejected", value)
			return
		end
		local delay = delayFor(config.retryDelay, failureCount, value)
		failureCount += 1
		if config.onFail then
			config.onFail(failureCount, value)
		end
		scheduler.delay(delay, function()
			if isRetryCancelled then
				settle("rejected", value)
			else
				run()
			end
		end)
	end

	return {
		cancel = function(options: CancelOptions?)
			if status ~= "pending" then
				return
			end
			local cancelled = Retryer.cancelledError(options)
			settle("rejected", cancelled)
			if config.onCancel then
				config.onCancel(cancelled)
			end
		end,
		cancelRetry = function()
			isRetryCancelled = true
		end,
		continueRetry = function()
			isRetryCancelled = false
		end,
		start = function()
			scheduler.spawn(run)
		end,
		status = function(): Status
			return status
		end,
		await = function(): (boolean, unknown)
			if status ~= "pending" then
				return status == "resolved", result
			end
			table.insert(waiting, coroutine.running())
			return coroutine.yield()
		end,
	}
end

return Retryer

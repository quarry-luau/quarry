--!strict
-- Test doubles for the core: a scheduler whose clock moves only when the test
-- advances it, and a gate a query function waits on, as a remote call yields
-- for its answer.

local Scheduler = require("../src/Scheduler")

type Timer = { at: number, work: () -> (), cancelled: boolean }

export type Clock = {
	scheduler: Scheduler.Scheduler,
	-- Moves the clock on, running each timer that comes due, in order.
	advance: (seconds: number) -> (),
}
export type Gate = {
	wait: () -> unknown,
	open: (value: unknown) -> (),
}

local Fake = {}

-- Resumes thread with the arguments, raising what it raised.
local function run(thread: thread, ...: unknown)
	local ok, problem = coroutine.resume(thread, ...)
	if not ok then
		error(problem, 0)
	end
end

-- The earliest timer not cancelled and due by target, or nil.
local function nextDue(timers: { Timer }, target: number): Timer?
	local due: Timer? = nil
	for _, timer in timers do
		local ready = not timer.cancelled and timer.at <= target
		if ready and (due == nil or timer.at < due.at) then
			due = timer
		end
	end
	return due
end

function Fake.clock(): Clock
	local time = 0
	local timers: { Timer } = {}
	local function delay(seconds: number, work: () -> ()): () -> ()
		local timer =
			{ at = time + seconds, work = work, cancelled = false }
		table.insert(timers, timer)
		return function()
			timer.cancelled = true
		end
	end
	local function advance(seconds: number)
		local target = time + seconds
		local due = nextDue(timers, target)
		while due do
			due.cancelled = true
			time = due.at
			run(coroutine.create(due.work))
			due = nextDue(timers, target)
		end
		time = target
	end
	local scheduler: Scheduler.Scheduler = {
		spawn = function(work: () -> ())
			run(coroutine.create(work))
		end,
		delay = delay,
		resume = run,
		now = function(): number
			return time
		end,
	}
	return { scheduler = scheduler, advance = advance }
end

function Fake.gate(): Gate
	local waiting: { thread } = {}
	local function open(value: unknown)
		local threads = waiting
		waiting = {}
		for _, thread in threads do
			run(thread, value)
		end
	end
	local function wait(): unknown
		table.insert(waiting, coroutine.running())
		return coroutine.yield()
	end
	return { wait = wait, open = open }
end

return Fake

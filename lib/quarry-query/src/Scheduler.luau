--!strict
-- How the query client runs work: in threads, after delays, on a clock. In a
-- game it is Luau's task library (Scheduler.task); a test passes one whose
-- time it moves itself.

export type Scheduler = {
	-- Runs work in a new thread at once; it may yield.
	spawn: (work: () -> ()) -> (),
	-- Runs work after a delay in seconds; returns what cancels it.
	delay: (seconds: number, work: () -> ()) -> () -> (),
	-- Resumes a thread that yielded to wait, with what it waited for.
	resume: (thread: thread, ok: boolean, value: unknown) -> (),
	-- Seconds on a steady clock.
	now: () -> number,
}

local Scheduler = {}

local function spawn(work: () -> ())
	task.spawn(work)
end

local function delay(seconds: number, work: () -> ()): () -> ()
	local thread = task.delay(seconds, work)
	return function()
		if coroutine.status(thread) == "suspended" then
			task.cancel(thread)
		end
	end
end

local function resume(thread: thread, ok: boolean, value: unknown)
	task.spawn(thread, ok, value)
end

-- The scheduler of Luau's task library and os.clock.
function Scheduler.task(): Scheduler
	return {
		spawn = spawn,
		delay = delay,
		resume = resume,
		now = os.clock,
	}
end

return Scheduler

--!strict
-- How the query client runs work: in threads, after delays, on a clock. In a game it is Luau's task
-- library (`Scheduler.task`); a test passes one whose time it moves itself.

export type Scheduler = {
	-- Runs `work` in a new thread at once; it may yield.
	spawn: (work: () -> ()) -> (),
	-- Runs `work` after `seconds`; returns the function that cancels it.
	delay: (seconds: number, work: () -> ()) -> () -> (),
	-- Resumes a thread that yielded to wait, with `ok` and the value it waited for.
	resume: (thread: thread, ok: boolean, value: unknown) -> (),
	-- Seconds on a steady clock.
	now: () -> number,
}

local Scheduler = {}

-- Luau's task library and os.clock.
function Scheduler.task(): Scheduler
	return {
		spawn = function(work: () -> ())
			task.spawn(work)
		end,
		delay = function(seconds: number, work: () -> ()): () -> ()
			local thread = task.delay(seconds, work)
			return function()
				if coroutine.status(thread) == "suspended" then
					task.cancel(thread)
				end
			end
		end,
		resume = function(thread: thread, ok: boolean, value: unknown)
			task.spawn(thread, ok, value)
		end,
		now = os.clock,
	}
end

return Scheduler

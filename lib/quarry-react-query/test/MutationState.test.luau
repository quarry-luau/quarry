--!strict
local Testing = require("../../../.lune/testing")

local MutationState = require("../src/MutationState")

local suite: Testing.Suite = function(test, expect)
	local IDLE = MutationState.IDLE
	local reduce = MutationState.reduce

	test("a mutation is pending while out, then succeeds", function()
		local pending =
			reduce(IDLE, { kind = "start", optimistic = false })
		expect.deepEqual(pending, {
			status = "pending",
			error = nil,
			retry = false,
			sent = true,
		})
		expect.deepEqual(reduce(pending, { kind = "succeed" }), {
			status = "success",
			retry = false,
			sent = false,
		})
	end)

	test("an optimistic mutation shows success while out", function()
		local shown =
			reduce(IDLE, { kind = "start", optimistic = true })
		expect.deepEqual(shown, {
			status = "success",
			retry = false,
			sent = true,
		})
	end)

	test("a failed request offers a retry, even after success", function()
		local shown =
			reduce(IDLE, { kind = "start", optimistic = true })
		expect.deepEqual(
			reduce(shown, { kind = "fail", error = "Short" }),
			{
				status = "error",
				error = "Short",
				retry = true,
				sent = false,
			}
		)
	end)

	test("a failed check has no retry and sends nothing", function()
		expect.deepEqual(
			reduce(IDLE, {
				kind = "refuse",
				reason = "Not enough coins",
			}),
			{
				status = "error",
				error = "Not enough coins",
				retry = false,
				sent = false,
			}
		)
	end)

	test("reset returns to idle", function()
		local failed =
			reduce(IDLE, { kind = "fail", error = "Unavailable" })
		expect.deepEqual(reduce(failed, { kind = "reset" }), IDLE)
	end)
end

return suite

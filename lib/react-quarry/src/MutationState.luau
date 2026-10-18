--!strict
-- The states of a mutation (useMutation) and how events move it between them, as TanStack
-- Query's mutations go idle, pending, then success or error. An optimistic mutation shows success
-- while its request is still out; a failed check fails it before any request is sent.

export type Status = "idle" | "pending" | "success" | "error"
export type State = {
	status: Status,
	-- What failed: the check's reason, or what the request raised.
	error: unknown?,
	-- Whether the request failed, so the button offers a retry; false for a failed check.
	retry: boolean,
	-- Whether a request is still out (an optimistic mutation shows success meanwhile).
	sent: boolean,
}
export type Event =
	{ kind: "start", optimistic: boolean }
	| { kind: "succeed" }
	| { kind: "fail", error: unknown }
	| { kind: "refuse", reason: string }
	| { kind: "reset" }

local IDLE: State = { status = "idle", error = nil, retry = false, sent = false }

local function reduce(state: State, event: Event): State
	if event.kind == "start" then
		return { status = if event.optimistic then "success" else "pending", error = nil, retry = false, sent = true }
	elseif event.kind == "succeed" then
		return { status = "success", error = nil, retry = false, sent = false }
	elseif event.kind == "fail" then
		return { status = "error", error = event.error, retry = true, sent = false }
	elseif event.kind == "refuse" then
		return { status = "error", error = event.reason, retry = false, sent = state.sent }
	end
	return IDLE
end

return { IDLE = IDLE, reduce = reduce }

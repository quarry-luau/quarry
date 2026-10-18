--!strict
-- A server action, as TanStack Query's useMutation runs one: `mutate(variables)` runs
-- `mutationFn`, which may yield (a remote call) and fails by raising (`error("Short", 0)`), and the
-- result reads as `isPending`, `isSuccess`, `isError` and `error`. `onMutate` applies an optimistic
-- update and returns what rolling it back needs (TanStack's context, usually the query data from
-- before); `onError` gets it back to roll back, and `onSuccess` and `onSettled` get it too. Two
-- additions for a game:
--
-- - `optimistic = true` shows success the moment `mutate` is called, so the player never waits;
--   if the request then fails, the mutation turns to an error that offers a retry.
-- - `validate` checks on the client first: a reason it returns fails the mutation at once, sends
--   nothing, and clears after two seconds.
--
-- A mutation called while its request is out is ignored.

local MutationState = require("./MutationState")
local React = require("../React")

export type Options<V> = {
	mutationFn: (variables: V) -> (),
	-- Returns the context the other callbacks get.
	onMutate: ((variables: V) -> unknown)?,
	onSuccess: ((variables: V, context: unknown) -> ())?,
	onError: ((error: unknown, variables: V, context: unknown) -> ())?,
	onSettled: ((error: unknown?, variables: V, context: unknown) -> ())?,
	optimistic: boolean?,
	-- Why the mutation cannot run now, checked before anything is sent; nil when it can.
	validate: ((variables: V) -> string?)?,
}
export type Mutation<V> = {
	status: MutationState.Status,
	isIdle: boolean,
	isPending: boolean,
	isSuccess: boolean,
	isError: boolean,
	-- What `validate` returned, or what `mutationFn` raised.
	error: unknown?,
	-- Whether the request failed (rather than `validate`), so the button offers a retry.
	retry: boolean,
	mutate: (variables: V) -> (),
	reset: () -> (),
}

local REFUSAL_HOLD_SECONDS = 2
-- React's state widens a status to `string`; STATUSES reads it back.
local STATUSES: { [string]: MutationState.Status } =
	{ idle = "idle", pending = "pending", success = "success", error = "error" }

local function useMutation<V>(options: Options<V>): Mutation<V>
	local state, setState = React.useState(MutationState.IDLE)
	local current = React.useRef(state)
	-- The latest options, so a request that answers after a re-render calls this render's callbacks.
	local latest = React.useRef(options)
	latest.current = options
	local none: thread? = nil
	local clear = React.useRef(none)

	local function dispatch(event: MutationState.Event)
		if clear.current then
			task.cancel(clear.current)
			clear.current = nil
		end
		local next = MutationState.reduce(current.current, event)
		current.current = next
		setState(next)
	end

	local function mutate(variables: V)
		if current.current.sent then
			return
		end
		local given = latest.current
		local reason = if given.validate then given.validate(variables) else nil
		if reason then
			dispatch({ kind = "refuse", reason = reason })
			clear.current = task.delay(REFUSAL_HOLD_SECONDS, function()
				clear.current = nil
				dispatch({ kind = "reset" })
			end)
			return
		end
		dispatch({ kind = "start", optimistic = given.optimistic == true })
		local context = if given.onMutate then given.onMutate(variables) else nil
		task.spawn(function()
			local problem: unknown = nil
			local ok = xpcall(given.mutationFn, function(raised: unknown)
				problem = raised
			end, variables)
			local callbacks = latest.current
			if ok then
				dispatch({ kind = "succeed" })
				if callbacks.onSuccess then
					callbacks.onSuccess(variables, context)
				end
			else
				dispatch({ kind = "fail", error = problem })
				if callbacks.onError then
					callbacks.onError(problem, variables, context)
				end
			end
			if callbacks.onSettled then
				callbacks.onSettled(if ok then nil else problem, variables, context)
			end
		end)
	end

	React.useEffect(function()
		return function()
			if clear.current then
				task.cancel(clear.current)
			end
		end
	end, {})

	local status: MutationState.Status = STATUSES[state.status] or "idle"
	return {
		status = status,
		isIdle = status == "idle",
		isPending = status == "pending",
		isSuccess = status == "success",
		isError = status == "error",
		error = state.error,
		retry = state.retry,
		mutate = mutate,
		reset = function()
			dispatch({ kind = "reset" })
		end,
	}
end

return useMutation

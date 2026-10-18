--!strict
-- A server action, as TanStack Query's useMutation runs one: mutate runs
-- mutationFn, which may yield (a remote call) and fails by raising, and the
-- result reads as isPending, isSuccess, isError and error. onMutate applies
-- an optimistic update and returns what undoing it needs (TanStack's
-- context); onError, onSuccess and onSettled get it back. Two additions for
-- a game: optimistic shows success the moment mutate is called, turning to
-- an error that offers a retry if the request fails; validate checks on the
-- client first, and a reason it returns fails the mutation at once, sends
-- nothing, and clears after two seconds. A mutate while the request is out
-- is ignored.

local MutationState = require("./MutationState")
local React = require("../React")

export type Options<V> = {
	mutationFn: (variables: V) -> (),
	-- Returns the context the other callbacks get.
	onMutate: ((variables: V) -> ...unknown)?,
	onSuccess: ((variables: V, context: unknown) -> ())?,
	onError: ((error: unknown, variables: V, context: unknown) -> ())?,
	onSettled: ((error: unknown?, variables: V, context: unknown) -> ())?,
	optimistic: boolean?,
	-- Why the mutation cannot run now, before anything is sent; or nil.
	validate: ((variables: V) -> string?)?,
}
export type Mutation<V> = {
	status: MutationState.Status,
	isIdle: boolean,
	isPending: boolean,
	isSuccess: boolean,
	isError: boolean,
	-- What validate returned, or what mutationFn raised.
	error: unknown?,
	-- Whether the request failed, rather than validate.
	retry: boolean,
	mutate: (variables: V) -> (),
	reset: () -> (),
}

type State = MutationState.State

-- What the hook keeps across renders.
type Refs<V> = {
	state: { current: MutationState.State },
	clear: { current: thread? },
	options: { current: Options<V> },
	setState: (state: MutationState.State) -> (),
}

local REFUSAL_HOLD_SECONDS = 2
-- A status read back from the string React's state widens it to.
local STATUSES: { [string]: MutationState.Status } = {
	idle = "idle",
	pending = "pending",
	success = "success",
	error = "error",
}

local function cancelClear<V>(refs: Refs<V>)
	if refs.clear.current then
		task.cancel(refs.clear.current)
		refs.clear.current = nil
	end
end

local function dispatch<V>(refs: Refs<V>, event: MutationState.Event)
	cancelClear(refs)
	local state = MutationState.reduce(refs.state.current, event)
	refs.state.current = state
	refs.setState(state)
end

-- Fails the mutation with reason, then clears it after a while.
local function refuse<V>(refs: Refs<V>, reason: string)
	dispatch(refs, { kind = "refuse", reason = reason })
	refs.clear.current = task.delay(REFUSAL_HOLD_SECONDS, function()
		refs.clear.current = nil
		dispatch(refs, { kind = "reset" })
	end)
end

-- Calls the latest options' callbacks for how the request ended.
local function report<V>(
	options: Options<V>,
	ok: boolean,
	problem: unknown,
	variables: V,
	context: unknown
)
	if ok and options.onSuccess then
		options.onSuccess(variables, context)
	elseif not ok and options.onError then
		options.onError(problem, variables, context)
	end
	if options.onSettled then
		options.onSettled(
			if ok then nil else problem,
			variables,
			context
		)
	end
end

-- Runs the request, yielding for it, and records how it ended.
local function send<V>(refs: Refs<V>, variables: V, context: unknown)
	local problem: unknown = nil
	local ok = xpcall(refs.options.current.mutationFn, function(raised)
		problem = raised
	end, variables)
	if ok then
		dispatch(refs, { kind = "succeed" })
	else
		dispatch(refs, { kind = "fail", error = problem })
	end
	report(refs.options.current, ok, problem, variables, context)
end

local function mutate<V>(refs: Refs<V>, variables: V)
	local options = refs.options.current
	if refs.state.current.sent then
		return
	end
	local reason = if options.validate
		then options.validate(variables)
		else nil
	if reason then
		refuse(refs, reason)
		return
	end
	local optimistic = options.optimistic == true
	dispatch(refs, { kind = "start", optimistic = optimistic })
	local context = if options.onMutate
		then options.onMutate(variables)
		else nil
	task.spawn(send, refs, variables, context)
end

local function resultOf<V>(state: State, refs: Refs<V>): Mutation<V>
	local status: MutationState.Status = STATUSES[state.status] or "idle"
	return {
		status = status,
		isIdle = status == "idle",
		isPending = status == "pending",
		isSuccess = status == "success",
		isError = status == "error",
		error = state.error,
		retry = state.retry,
		mutate = function(variables: V)
			mutate(refs, variables)
		end,
		reset = function()
			dispatch(refs, { kind = "reset" })
		end,
	}
end

local function useMutation<V>(options: Options<V>): Mutation<V>
	local state, setState = React.useState(MutationState.IDLE)
	local none: thread? = nil
	local refs: Refs<V> = {
		state = React.useRef(state),
		clear = React.useRef(none),
		options = React.useRef(options),
		setState = setState,
	}
	refs.options.current = options
	React.useEffect(function()
		return function()
			cancelClear(refs)
		end
	end, {})
	return resultOf(state, refs)
end

return useMutation

--!strict
-- React bindings for Quarry, a port of TanStack Query's react-query (v5.104) for React-Lua:
-- `QueryClientProvider` sets the client its children read with `useQueryClient`, and `useQuery`
-- reads one query as useBaseQuery does: one observer per component, the optimistic result while
-- rendering, subscribed after mounting, its options updated after every render, and re-rendering
-- only when a field the component read changes (TanStack's tracked props). `useMutation` runs a
-- server action.
--
-- Luau infers a hook's data type only from a function it is given, so TanStack's `select` option
-- is `useQuerySelect(options, select)`: `useQuery` returns what `queryFn` returns, and
-- `useQuerySelect` what `select` picks of it. React-Lua 17 has no useSyncExternalStore; a change
-- re-renders through state.

local Quarry = require("./Quarry")
local React = require("./React")
local useMutation = require("@self/useMutation")

export type Options<T> = {
	queryKey: Quarry.QueryKey,
	queryFn: (context: { queryKey: Quarry.QueryKey }) -> T,
	enabled: boolean?,
	staleTime: number?,
	gcTime: number?,
	retry: Quarry.RetryValue?,
	retryDelay: Quarry.RetryDelayValue?,
	refetchOnMount: (boolean | "always")?,
	retryOnMount: boolean?,
	initialData: T?,
}
-- Quarry's QueryObserverResult with typed data.
export type Result<T> = {
	data: T?,
	dataUpdatedAt: number,
	error: unknown,
	errorUpdatedAt: number,
	errorUpdateCount: number,
	failureCount: number,
	failureReason: unknown,
	status: Quarry.QueryStatus,
	fetchStatus: Quarry.FetchStatus,
	isPending: boolean,
	isSuccess: boolean,
	isError: boolean,
	isFetching: boolean,
	isLoading: boolean,
	isRefetching: boolean,
	isLoadingError: boolean,
	isRefetchError: boolean,
	isFetched: boolean,
	isStale: boolean,
	isEnabled: boolean,
	refetch: () -> (),
}
export type MutationOptions<V> = useMutation.Options<V>
export type Mutation<V> = useMutation.Mutation<V>

local noClient: Quarry.QueryClient? = nil
local ClientContext = React.createContext(noClient)

local ReactQuarry = {
	useMutation = useMutation,
}

function ReactQuarry.QueryClientProvider(props: { client: Quarry.QueryClient, children: React.ReactNode? })
	return React.createElement(ClientContext.Provider, { value = props.client }, props.children)
end

function ReactQuarry.useQueryClient(): Quarry.QueryClient
	local client = React.useContext(ClientContext)
	if client == nil then
		error("No QueryClient set, use QueryClientProvider to set one", 2)
	end
	return client
end

-- Invariant: a query's data is what its queryFn returned (or setQueryData wrote with that type),
-- and a selected result is what `select` returned, so either is the T the caller's options name.
local function typed<T>(result: Quarry.QueryObserverResult): Result<T>
	return result :: any
end
-- Invariant: `select` is only handed the data under its query's key, which its queryFn produced.
local function asData<T>(data: unknown): T
	return data :: any
end

local function observerOptions<T>(options: Options<T>, select: ((data: unknown) -> unknown)?): Quarry.QueryObserverOptions
	return {
		queryKey = options.queryKey,
		queryFn = options.queryFn,
		enabled = options.enabled,
		staleTime = options.staleTime,
		gcTime = options.gcTime,
		retry = options.retry,
		retryDelay = options.retryDelay,
		refetchOnMount = options.refetchOnMount,
		retryOnMount = options.retryOnMount,
		initialData = options.initialData,
		select = select,
	}
end

local function useBaseQuery(options: Quarry.QueryObserverOptions): Quarry.QueryObserverResult
	local client = ReactQuarry.useQueryClient()
	local observer = React.useState(function()
		return client:observe(options)
	end)
	local _, setVersion = React.useState(0)
	local result = observer:getOptimisticResult(options)
	React.useEffect(function()
		return observer:subscribe(function()
			setVersion(function(version: number): number
				return version + 1
			end)
		end)
	end, { observer })
	React.useEffect(function()
		observer:setOptions(options)
	end)
	return observer:trackResult(result)
end

-- The query `options` name: its data (what queryFn returns), status and fetch state.
function ReactQuarry.useQuery<T>(options: Options<T>): Result<T>
	return typed(useBaseQuery(observerOptions(options, nil)))
end

-- What `select` picks of the query's data; the result keeps its identity, and the component does
-- not re-render, while the pick is equal.
function ReactQuarry.useQuerySelect<T, S>(options: Options<T>, select: (data: T) -> S): Result<S>
	return typed(useBaseQuery(observerOptions(options, function(data: unknown): unknown
		return select(asData(data))
	end)))
end

return ReactQuarry

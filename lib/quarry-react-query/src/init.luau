--!strict
-- React bindings for Quarry Query, a port of TanStack Query's react-query for
-- React-Lua. QueryClientProvider sets the client its children read with
-- useQueryClient. useQuery reads one query as useBaseQuery does: one observer
-- per component, the optimistic result while rendering, subscribed after
-- mounting, its options updated after every render, and a re-render only
-- when a field the component read changes. useMutation runs a server action.
--
-- Luau infers a hook's data type only from a function it is given, so
-- TanStack's select option is useQuerySelect(options, select). React-Lua 17
-- has no useSyncExternalStore; a change re-renders through state.

local Query = require("./Query")
local React = require("./React")
local useMutation = require("@self/useMutation")

export type Options<T> = {
	queryKey: Query.QueryKey,
	queryFn: (context: { queryKey: Query.QueryKey }) -> T,
	enabled: boolean?,
	staleTime: number?,
	gcTime: number?,
	retry: Query.RetryValue?,
	retryDelay: Query.RetryDelayValue?,
	refetchOnMount: (boolean | "always")?,
	retryOnMount: boolean?,
	initialData: T?,
}
-- Quarry Query's QueryObserverResult with typed data.
export type Result<T> = {
	data: T?,
	dataUpdatedAt: number,
	error: unknown,
	errorUpdatedAt: number,
	errorUpdateCount: number,
	failureCount: number,
	failureReason: unknown,
	status: Query.QueryStatus,
	fetchStatus: Query.FetchStatus,
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

type Select = (data: unknown) -> unknown

local noClient: Query.QueryClient? = nil
local ClientContext = React.createContext(noClient)

local ReactQuery = {
	useMutation = useMutation,
}

function ReactQuery.QueryClientProvider(props: {
	client: Query.QueryClient,
	children: React.ReactNode?,
})
	return React.createElement(
		ClientContext.Provider,
		{ value = props.client },
		props.children
	)
end

function ReactQuery.useQueryClient(): Query.QueryClient
	local client = React.useContext(ClientContext)
	if client == nil then
		error("No QueryClient: wrap the tree in QueryClientProvider", 2)
	end
	return client
end

-- Invariant: a query's data is what its queryFn returned (or setQueryData
-- wrote with that type), and a pick is what select returned, so either is
-- the T the caller's options name.
local function typed<T>(result: Query.QueryObserverResult): Result<T>
	return result :: any
end

-- Invariant: select is only handed the data under its query's key, which
-- its queryFn produced.
local function asData<T>(data: unknown): T
	return data :: any
end

local function observerOptions<T>(
	options: Options<T>,
	select: Select?
): Query.QueryObserverOptions
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

-- Re-renders the component each time the observer reports a change.
local function useSubscription(observer: Query.QueryObserver)
	local _, setVersion = React.useState(0)
	React.useEffect(function()
		return observer:subscribe(function()
			setVersion(function(version: number): number
				return version + 1
			end)
		end)
	end, { observer })
end

local function useBaseQuery(
	options: Query.QueryObserverOptions
): Query.QueryObserverResult
	local client = ReactQuery.useQueryClient()
	local observer = React.useState(function()
		return client:observe(options)
	end)
	local result = observer:getOptimisticResult(options)
	useSubscription(observer)
	React.useEffect(function()
		observer:setOptions(options)
	end)
	return observer:trackResult(result)
end

-- The query options name: its data (what queryFn returns) and state.
function ReactQuery.useQuery<T>(options: Options<T>): Result<T>
	return typed(useBaseQuery(observerOptions(options, nil)))
end

-- What select picks of the query's data. The pick keeps its identity, and
-- the component does not re-render, while it is equal.
function ReactQuery.useQuerySelect<T, S>(
	options: Options<T>,
	select: (data: T) -> S
): Result<S>
	local function pick(data: unknown): unknown
		return select(asData(data))
	end
	return typed(useBaseQuery(observerOptions(options, pick)))
end

return ReactQuery

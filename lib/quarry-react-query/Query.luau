--!strict
-- Stands in for the Query link Wally installs: the package and its types.
local Query = require(script.Parent["quarry-query"])

export type QueryKey = Query.QueryKey
export type QueryClient = Query.QueryClient
export type QueryClientConfig = Query.QueryClientConfig
export type QueryFilters = Query.QueryFilters
export type InvalidateQueryFilters = Query.InvalidateQueryFilters
export type QueryState = Query.QueryState
export type QueryStatus = Query.QueryStatus
export type FetchStatus = Query.FetchStatus
export type QueryFunction<T = unknown> = Query.QueryFunction<T>
export type QueryObserver = Query.QueryObserver
export type QueryObserverOptions<T = unknown> = Query.QueryObserverOptions<T>
export type QueryObserverResult<T = unknown> = Query.QueryObserverResult<T>
export type RetryValue = Query.RetryValue
export type RetryDelayValue = Query.RetryDelayValue
export type CancelOptions = Query.CancelOptions
export type CancelledError = Query.CancelledError
export type Scheduler = Query.Scheduler

return Query

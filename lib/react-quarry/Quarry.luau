--!strict
-- Development stand-in for the Quarry dependency, as the link Wally installs in its place: the
-- package and its types.
local Quarry = require(script.Parent.quarry)

export type QueryKey = Quarry.QueryKey
export type QueryClient = Quarry.QueryClient
export type QueryClientConfig = Quarry.QueryClientConfig
export type QueryFilters = Quarry.QueryFilters
export type InvalidateQueryFilters = Quarry.InvalidateQueryFilters
export type QueryState = Quarry.QueryState
export type QueryStatus = Quarry.QueryStatus
export type FetchStatus = Quarry.FetchStatus
export type QueryFunction = Quarry.QueryFunction
export type QueryObserver = Quarry.QueryObserver
export type QueryObserverOptions = Quarry.QueryObserverOptions
export type QueryObserverResult = Quarry.QueryObserverResult
export type RetryValue = Quarry.RetryValue
export type RetryDelayValue = Quarry.RetryDelayValue
export type CancelOptions = Quarry.CancelOptions
export type CancelledError = Quarry.CancelledError
export type Scheduler = Quarry.Scheduler

return Quarry

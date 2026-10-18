--!strict
-- Quarry Query: TanStack Query's core for Luau. A QueryClient caches what query
-- functions return, by key, and keeps it fresh; observers read it.

local Key = require("@self/Key")
local Observer = require("@self/Observer")
local Query = require("@self/Query")
local QueryClient = require("@self/QueryClient")
local Retryer = require("@self/Retryer")
local Scheduler = require("@self/Scheduler")

export type QueryKey = Key.QueryKey
export type QueryClient = QueryClient.QueryClient
export type QueryClientConfig = QueryClient.Config
export type QueryFilters = QueryClient.Filters
export type InvalidateQueryFilters = QueryClient.InvalidateFilters
export type QueryState = Query.State
export type QueryStatus = Query.Status
export type FetchStatus = Query.FetchStatus
export type QueryFunction<T = unknown> = Query.QueryFunction<T>
export type QueryObserver = Observer.Observer
export type QueryObserverOptions<T = unknown> = Observer.Options<T>
export type QueryObserverResult<T = unknown> = Observer.Result<T>
export type RetryValue = Retryer.RetryValue
export type RetryDelayValue = Retryer.RetryDelayValue
export type CancelOptions = Retryer.CancelOptions
export type CancelledError = Retryer.CancelledError
export type Scheduler = Scheduler.Scheduler

return {
	QueryClient = QueryClient,
	Scheduler = Scheduler,
	hashKey = Key.hash,
	partialMatchKey = Key.matches,
	replaceEqualDeep = Key.replaceEqualDeep,
	isCancelledError = function(value: unknown): boolean
		return Retryer.cancelled(value) ~= nil
	end,
}

# Changelog

All notable changes to Quarry Query. The format follows [Keep a Changelog](https://keepachangelog.com),
and versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

## [0.2.0] - 2026-10-22

### Added

- `Query.queryOptions(options)` defines a query with its data type, as in TanStack Query v5, and
  `client:data(definition)` reads and writes its cache entry with that type: `get()`, `set(value)`
  and `update(updater)`, whose `old` is typed without an annotation.

### Changed

- `setQueryData` raises for a key read typed (through `client:data` or `useQuery`); such a key is
  written only through `client:data(definition)`, so its typed readers always get its type.
- `onMutate` may return nothing, as in TanStack Query; the context is then nil.
- `QueryFunction<T>`, `QueryObserverOptions<T>` and `QueryObserverResult<T>` are generic in the
  data (`unknown` when left out). `ReactQuery.Options<T>` is the core's `QueryOptions<T>` and
  `ReactQuery.Result<T>` its `QueryObserverResult<T>`.
- A query's state changes through typed fields, so a misspelt field or a status that does not exist
  no longer type checks.

## [0.1.0] - 2026-10-18

First release: a port of TanStack Query's query-core and react-query 5.104.

### Added

- `quarry-query`: `QueryClient` with `getQueryData`, `getQueryState`, `setQueryData`,
  `invalidateQueries`, `refetchQueries`, `cancelQueries`, `removeQueries`, `fetchQuery`,
  `prefetchQuery`, `ensureQueryData`, `isFetching` and `observe`; query filters; deduplicated
  fetches, retries with backoff, stale and gc times, cancel with revert, structural sharing,
  tracked result props; an injectable scheduler; `hashKey`, `partialMatchKey`,
  `replaceEqualDeep`, `isCancelledError`.
- `quarry-react-query`: `QueryClientProvider`, `useQueryClient`, `useQuery`, `useQuerySelect` and
  `useMutation` (with `optimistic` and `validate`).

[Unreleased]: https://github.com/quarry-luau/quarry-query/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/quarry-luau/quarry-query/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/quarry-luau/quarry-query/releases/tag/v0.1.0

# Changelog

All notable changes to Quarry. The format follows [Keep a Changelog](https://keepachangelog.com),
and versions follow [Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-10-18

First release: a port of TanStack Query's query-core and react-query 5.104.

### Added

- `quarry`: `QueryClient` with `getQueryData`, `getQueryState`, `setQueryData`,
  `invalidateQueries`, `refetchQueries`, `cancelQueries`, `removeQueries`, `fetchQuery`,
  `prefetchQuery`, `ensureQueryData`, `isFetching` and `observe`; query filters; deduplicated
  fetches, retries with backoff, stale and gc times, cancel with revert, structural sharing,
  tracked result props; an injectable scheduler; `hashKey`, `partialMatchKey`,
  `replaceEqualDeep`, `isCancelledError`.
- `react-quarry`: `QueryClientProvider`, `useQueryClient`, `useQuery`, `useQuerySelect` and
  `useMutation` (with `optimistic` and `validate`).

[0.1.0]: https://github.com/pcruz1905/quarry/releases/tag/v0.1.0

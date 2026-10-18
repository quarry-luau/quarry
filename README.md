<p align="center">
  <p align="center">
    <img width="120" height="120" src="https://raw.githubusercontent.com/quarry-luau/.github/main/assets/logo.png" alt="Quarry logo">
  </p>
  <h1 align="center"><b>Quarry Query</b></h1>
  <p align="center">
    TanStack Query for Roblox: server data, cached and kept fresh
    <br />
    <a href="https://wally.run/package/quarry-luau/quarry-query"><strong>Wally package →</strong></a>
  </p>
</p>

<div align="center">

[![CI](https://img.shields.io/github/actions/workflow/status/quarry-luau/quarry-query/ci.yml?style=for-the-badge&branch=main&logo=github&label=CI)](https://github.com/quarry-luau/quarry-query/actions/workflows/ci.yml)
[![Wally](https://img.shields.io/badge/wally-quarry--luau%2Fquarry--query-AD4646?style=for-the-badge)](https://wally.run/package/quarry-luau/quarry-query)

</div>

Quarry Query is a port of [TanStack Query](https://tanstack.com/query) v5 to Luau, from
[Quarry](https://github.com/quarry-luau), open-source tools for Roblox. It caches what your
queries return by key, shares one request between everything that asks for the same key, retries
failures, refetches what you invalidate, and lets you update the cache optimistically and roll it
back. The core runs anywhere Luau does; `quarry-react-query` adds TanStack's React hooks for
[React-Lua](https://github.com/jsdotlua/react-lua).

It is ported from TanStack's source (query-core and react-query 5.104), not reimagined: the same
names, the same state, the same rules for when to fetch. If you have used TanStack Query on the
web, you already know Quarry Query.

**What you get:**

- **Caching by key**: `{ "player", userId }` and `{ "player", userId }` are one query; data under a
  key is shared and kept until nothing has used it for `gcTime`.
- **Deduplication**: every component, prefetch and refetch that asks for a key while it is being
  fetched joins the one request.
- **Retries**: a failure is tried again after 1, 2 and 4 seconds by default, and retries stop once
  nothing is watching.
- **Freshness**: `staleTime`, refetch on mount, `invalidateQueries` (which also replaces a fetch
  already out, so an older answer cannot land after a change).
- **Server pushes**: write what the server sends into the cache, as a TanStack app writes what a
  websocket brings.
- **Optimistic updates**: `cancelQueries`, snapshot, write, and roll back on failure;
  `cancelQueries` restores the state from before the fetch.
- **Typed cache access**: define a query once with `queryOptions`, and read and write its data as
  its type; a key read typed can only be written that way.
- **Structural sharing and tracked props**: unchanged parts of new data keep their identity, and a
  component re-renders only when a field it read changed.
- **Testable**: inject a scheduler and drive time yourself; no waiting in tests.

<details>
<summary><b>Table of Contents</b></summary>

- [At a Glance](#at-a-glance)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Guides](#guides)
  - [Query keys](#query-keys)
  - [Defining a query once](#defining-a-query-once)
  - [Data the server pushes](#data-the-server-pushes)
  - [Mutations and optimistic updates](#mutations-and-optimistic-updates)
  - [Selecting part of the data](#selecting-part-of-the-data)
  - [Without React](#without-react)
  - [Testing](#testing)
- [API](#api)
  - [`QueryClient`](#queryclient)
  - [Query options](#query-options)
  - [Query results](#query-results)
  - [React hooks](#react-hooks)
  - [`useMutation`](#usemutation)
  - [Utilities](#utilities)
  - [Types](#types)
- [Differences from TanStack Query](#differences-from-tanstack-query)
- [Development](#development)
- [License](#license)

</details>

## At a Glance

```luau
local ReactQuery = require(ReplicatedStorage.Packages.ReactQuery)

local function Leaderboard()
	local leaderboard = ReactQuery.useQuery({
		queryKey = { "leaderboard", "coins" },
		queryFn = function(): { Entry }
			return Remotes.GetLeaderboard:InvokeServer() -- yields; raise to fail
		end,
		staleTime = 30,
	})

	if leaderboard.isLoading then
		return e(Spinner)
	elseif leaderboard.isError then
		return e(Retry, { onClick = leaderboard.refetch })
	end
	return e(Rows, { entries = leaderboard.data })
end
```

---

## Installation

```toml
# wally.toml
[dependencies]
Query = "quarry-luau/quarry-query@0.1.0"
ReactQuery = "quarry-luau/quarry-react-query@0.1.0" # the React hooks, if you use React-Lua
```

Then `wally install`.

> **Note:** the `quarry-luau` scope is waiting for Wally to approve it
> ([wally-index#131](https://github.com/UpliftGames/wally-index/pull/131)); until then the packages
> are not on Wally yet. Use the `.rbxm` models from the
> [latest release](https://github.com/quarry-luau/quarry-query/releases/latest) meanwhile.

Each [release](https://github.com/quarry-luau/quarry-query/releases) also has
`quarry-query.rbxm` and `quarry-react-query.rbxm` to drop into a place without Wally (put
`quarry-react-query` next to `Query` and `React` modules).

## Quick Start

Make one client for the game's lifetime and give it to the React tree:

```luau
local Query = require(ReplicatedStorage.Packages.Query)
local ReactQuery = require(ReplicatedStorage.Packages.ReactQuery)

local client = Query.QueryClient.new()

root:render(e(ReactQuery.QueryClientProvider, { client = client }, e(App)))
```

Read a query anywhere below it:

```luau
local function Coins()
	local coins = ReactQuery.useQuery({
		queryKey = { "coins" },
		queryFn = function(): number
			return Remotes.GetCoins:InvokeServer()
		end,
	})
	return e("TextLabel", { Text = if coins.data then tostring(coins.data) else "…" })
end
```

A query function may yield (remotes, `task.wait`) and fails by raising: `error("Unavailable", 0)`.
It must return a value; returning nothing is a failure, as `undefined` is in TanStack Query.

## Guides

### Query keys

A key is an array of strings, numbers, booleans and tables of those. Keys with equal contents are
the same query, whatever order a table's fields were written in. Filters match by prefix:

```luau
client:invalidateQueries({ queryKey = { "player" } })               -- { "player", ... } all
client:invalidateQueries({ queryKey = { "player", 1 }, exact = true }) -- only { "player", 1 }
```

### Defining a query once

`Query.queryOptions` defines a query with its data type, as in TanStack Query v5. Hand the
definition to the hooks, and reach its cache entry with `client:data(definition)`, which reads and
writes it as that type where `getQueryData` and `setQueryData` give `unknown`:

```luau
local player = Query.queryOptions({
	queryKey = { "player" },
	queryFn = function(): PlayerView
		return Remotes.GetPlayer:InvokeServer()
	end,
	staleTime = math.huge,
})

local result = ReactQuery.useQuery(player) -- result.data: PlayerView?

local data = client:data(player)
data:get() -- PlayerView?
data:set(view) -- takes a PlayerView
data:update(function(old) -- old: PlayerView?
	return if old then withCoins(old, old.coins + 100) else nil
end)
```

`set` and `update` write nothing for `nil`. Once a key is read typed (through `client:data` or
`useQuery`), `setQueryData` on it raises: only its typed entry writes it, so every typed reader gets
the type its definition promises.

### Data the server pushes

When the server sends state as it changes, write it into the cache. Every component reading the key
updates, and the query never needs to fetch again by itself (`player` is the definition above, with
`staleTime = math.huge`):

```luau
Remotes.PlayerChanged.OnClientEvent:Connect(function(view: PlayerView)
	client:data(player):set(view)
end)

-- Fetched once on the first mount, then kept current by the pushes.
local result = ReactQuery.useQuery(player)
```

For a key nothing reads typed, `setQueryData(key, data)` writes it, and also takes an updater,
`function(old) return new end`; returning `nil` writes nothing.

### Mutations and optimistic updates

`useMutation` runs a server action and reports `isPending`, `isSuccess`, `isError` and `error`. What
`onMutate` returns is handed to `onError`, `onSuccess` and `onSettled` as their context. Here the
roll-back keeps the data from before in a typed local instead (`player` is the definition above):

```luau
local data = client:data(player)
local before: PlayerView? = nil

local buy = ReactQuery.useMutation({
	mutationFn = function(item: string)
		local outcome = Remotes.Buy:InvokeServer(item)
		if outcome ~= "Done" then
			error(outcome, 0) -- fails the mutation
		end
	end,
	onMutate = function(item: string): unknown
		client:cancelQueries({ queryKey = player.queryKey }) -- an older answer cannot land after
		before = data:get()
		data:update(function(old)
			return if old then applyPurchase(old, item) else nil
		end)
		return nil
	end,
	onError = function()
		data:set(before)
		client:invalidateQueries({ queryKey = player.queryKey }) -- and fetch the truth
	end,
})

e(Button, { onClick = function() buy.mutate("Trail") end })
```

Two additions for games: `optimistic = true` shows success the moment `mutate` is called (and turns
to an error with `retry = true` if the request fails), and `validate` checks on the client first,
failing at once with the reason it returns and sending nothing.

### Selecting part of the data

`useQuerySelect(options, select)` returns what `select` picks. The component re-renders only when
the pick changes, and the pick keeps its identity while it is equal:

```luau
local trail = ReactQuery.useQuerySelect(playerQuery, function(player: PlayerView): number
	return player.items.Trail or 0
end)
```

Annotate the selector's parameter: Luau infers the result's type from it. (TanStack's `select`
option is a second argument here for the same reason: Luau infers a hook's type only from a
function it is given.)

### Without React

The core is plain Luau. An observer is what the hooks are built on:

```luau
local observer = client:observe({ queryKey = { "coins" }, queryFn = getCoins })
local unsubscribe = observer:subscribe(function()
	print(observer:getCurrentResult().data)
end)

local coins = client:fetchQuery({ queryKey = { "coins" }, queryFn = getCoins }) -- yields
```

### Testing

Pass a scheduler whose clock you move, and nothing in a test waits on real time:

```luau
local client = Query.QueryClient.new({ scheduler = fakeScheduler })
```

A scheduler is `{ spawn, delay, resume, now }` (see `Scheduler.luau`); `Query.Scheduler.task()`
is the default, on Luau's task library and `os.clock`. Quarry Query's own tests run this way in
[Lune](https://lune-org.github.io/docs).

## API

### `QueryClient`

| Method | Does |
|---|---|
| `QueryClient.new(config?)` | `config.defaultOptions.queries` sets defaults for every query (`retry`, `retryDelay`, `gcTime`, `staleTime`, `refetchOnMount`, `retryOnMount`); `config.scheduler` replaces the clock |
| `client:getQueryData(key)` | The data under `key`, or nil |
| `client:data(definition)` | The cache entry of a query `queryOptions` defined, typed as its `queryFn` returns: `get()`, `set(value)`, `update(updater)`; nil writes nothing |
| `client:getQueryState(key)` | The query's state (`status`, `fetchStatus`, `dataUpdatedAt`, `isInvalidated`, counts) |
| `client:setQueryData(key, dataOrUpdater)` | Writes data; an updater gets the old data; nil writes nothing; raises for a key read typed |
| `client:invalidateQueries(filters?, options?)` | Marks queries stale and refetches the active ones (`refetchType = "active" \| "inactive" \| "all" \| "none"`) |
| `client:refetchQueries(filters?, options?)` | Fetches again, replacing a fetch out unless `cancelRefetch = false` |
| `client:cancelQueries(filters?, options?)` | Drops fetches out and restores the state from before them (`revert = false` keeps it) |
| `client:removeQueries(filters?)` | Removes queries from the cache |
| `client:fetchQuery(options)` | Yields for the data (fetching when stale) and raises a failure; no retries unless asked |
| `client:prefetchQuery(options)` | Fetches when stale, without waiting or raising |
| `client:ensureQueryData(options)` | The cached data, or `fetchQuery`'s (`revalidateIfStale` to refresh behind it) |
| `client:isFetching(filters?)` | How many queries are fetching |
| `client:observe(options)` | A query observer, as the hooks use |
| `client:clear()` | Empties the cache |

Filters: `queryKey` (a prefix, or one key with `exact = true`), `type` (`"all"`, `"active"`,
`"inactive"`), `stale`, `fetchStatus`, `predicate(query)`.

### Query options

| Option | Default | |
|---|---|---|
| `queryKey` | | The key |
| `queryFn` | | `function(context) -> data`; `context.queryKey` is the key; may yield; raises to fail |
| `enabled` | `true` | `false` stops the query fetching by itself |
| `staleTime` | `0` | Seconds data stays fresh; `math.huge` for data that changes only when invalidated or set |
| `gcTime` | `300` | Seconds an unused query stays cached; `math.huge` keeps it |
| `retry` | `3` | Retries, `true`/`false`, or `function(failureCount, error) -> boolean` |
| `retryDelay` | 1, 2, 4… up to 30 s | Seconds, or `function(failureCount, error) -> seconds` |
| `refetchOnMount` | `true` | Whether mounting fetches stale data again; `"always"` fetches anyway |
| `retryOnMount` | `true` | Whether mounting fetches again after an error |
| `initialData` | | Data before the first fetch |

### Query results

`data`, `error`, `status` (`"pending"`, `"error"`, `"success"`), `fetchStatus` (`"fetching"`,
`"idle"`), `isPending`, `isSuccess`, `isError`, `isFetching`, `isLoading` (fetching with no data
yet), `isRefetching`, `isLoadingError`, `isRefetchError`, `isFetched`, `isStale`, `isEnabled`,
`dataUpdatedAt`, `errorUpdatedAt`, `errorUpdateCount`, `failureCount`, `failureReason`, `refetch()`.

### React hooks

| Hook | Returns |
|---|---|
| `QueryClientProvider { client }` | Gives `client` to its children |
| `useQueryClient()` | The client; raises outside a provider |
| `useQuery(options)` | The result, its `data` typed as `queryFn` returns |
| `useQuerySelect(options, select)` | The result, its `data` what `select(data)` returns |
| `useMutation(options)` | A mutation, below |

### `useMutation`

Options: `mutationFn(variables)`, `onMutate(variables) -> context`, `onSuccess(variables, context)`,
`onError(error, variables, context)`, `onSettled(error?, variables, context)`, `optimistic`,
`validate(variables) -> reason?`.

Result: `mutate(variables)`, `reset()`, `status` (`"idle"`, `"pending"`, `"success"`, `"error"`),
`isIdle`, `isPending`, `isSuccess`, `isError`, `error`, and `retry` (whether the failure came from
the request rather than `validate`). A `mutate` while the request is out is ignored.

### Utilities

`Query.queryOptions(options)` (a query defined with its data type), `Query.hashKey(key)`,
`Query.partialMatchKey(key, filter)`, `Query.replaceEqualDeep(old, new)`,
`Query.isCancelledError(value)`, as TanStack exports them.

### Types

From `Query`: `QueryKey`, `QueryClient`, `QueryClientConfig`, `QueryFilters`,
`InvalidateQueryFilters`, `QueryState`, `QueryStatus`, `FetchStatus`, `QueryObserver`,
`RetryValue`, `RetryDelayValue`, `CancelOptions`, `CancelledError`, `Scheduler`, and, generic in
the data and `unknown` when left out, `QueryFunction<T>`, `QueryObserverOptions<T>` and
`QueryObserverResult<T>`; `QueryOptions<T>` is what `queryOptions` and `useQuery` take, and
`Data<T>` what `client:data` returns.

From `ReactQuery`: `Options<T>` (what `useQuery` takes, the core's `QueryOptions<T>`), `Result<T>`
(what it returns, the core's `QueryObserverResult<T>`), `MutationOptions<V>` and `Mutation<V>`.

## Differences from TanStack Query

| TanStack Query | Quarry Query |
|---|---|
| Promises | Functions that yield: `fetchQuery` and `ensureQueryData` return the data and raise the failure |
| `select` option | `useQuerySelect(options, select)`, for Luau's type inference |
| `undefined` | `nil`; a query function returning nil fails |
| `staleTime: Infinity` / `"static"` | `math.huge`; `"static"` is not ported |
| Notifications batched to the next tick | Told at once |
| Mutation cache, `useMutationState`, `mutationKey` | `useMutation` keeps its own state; no mutation cache |
| `onSuccess(data, ...)` on mutations | `onSuccess(variables, context)`: a game's action rarely returns data |

**Not ported:** window focus and reconnect refetching (a Roblox client has no such events),
`refetchInterval`, `placeholderData`, infinite queries, suspense, `notifyOnChangeProps`,
persisters, hydration and devtools. The source comments say where each would go.

## Development

You need [Rokit](https://github.com/rojo-rbx/rokit). Then:

```sh
rokit install
lune run install   # React for type checking the bindings, sourcemap, package types
lune run check     # license, format, style, lint, types, inference, tests, builds: what CI runs
lune run test      # the tests alone; `lune run test Key` filters by path
```

The code follows the Linux kernel coding style, read for Luau: see [STYLE.md](STYLE.md).
`lib/quarry-query` is the core and `lib/quarry-react-query` the React bindings; each is a Wally
package. The core's tests are in `lib/quarry-query/test` and run in Lune with a scheduler they
drive by hand; they were checked by breaking 16 of the ported rules one at a time, and each break
failed a test.

**Releasing:** bump `version` in both `wally.toml` files (and `quarry-react-query`'s dependency on
`quarry-query`), add the changes to `CHANGELOG.md`, and publish a GitHub release tagged `vX.Y.Z`. The
release workflow checks the versions match the tag, builds the models into the release, and
publishes both packages to Wally.

## License

[MIT](LICENSE). Quarry Query is a port of [TanStack Query](https://github.com/TanStack/query), © Tanner
Linsley, also MIT; its notice is kept in the license.

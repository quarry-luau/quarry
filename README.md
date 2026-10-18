<p align="center">
  <h1 align="center"><b>Quarry</b></h1>
  <p align="center">
    TanStack Query for Roblox: server data, cached and kept fresh
    <br />
    <a href="https://wally.run/package/quarry-luau/quarry"><strong>Wally package →</strong></a>
  </p>
</p>

<div align="center">

[![CI](https://img.shields.io/github/actions/workflow/status/quarry-luau/quarry/ci.yml?style=for-the-badge&branch=main&logo=github&label=CI)](https://github.com/quarry-luau/quarry/actions/workflows/ci.yml)
[![Wally](https://img.shields.io/badge/wally-quarry-luau%2Fquarry-AD4646?style=for-the-badge)](https://wally.run/package/quarry-luau/quarry)
[![License](https://img.shields.io/github/license/quarry-luau/quarry?style=for-the-badge)](LICENSE)

</div>

Quarry is a port of [TanStack Query](https://tanstack.com/query) v5 to Luau. It caches what your
queries return by key, shares one request between everything that asks for the same key, retries
failures, refetches what you invalidate, and lets you update the cache optimistically and roll it
back. The core runs anywhere Luau does; `react-quarry` adds TanStack's React hooks for
[React-Lua](https://github.com/jsdotlua/react-lua).

It is ported from TanStack's source (query-core and react-query 5.104), not reimagined: the same
names, the same state, the same rules for when to fetch. If you have used TanStack Query on the
web, you already know Quarry.

**What you get:**

- **Caching by key**: `{ "player", userId }` and `{ "player", userId }` are one query; data under a
  key is shared and kept until nothing has used it for `gcTime`.
- **Deduplication**: every component, prefetch and refetch that asks for a key while it is being
  fetched joins the one request.
- **Retries**: a failure is tried again after 1, 2 and 4 seconds by default, and retries stop once
  nothing is watching.
- **Freshness**: `staleTime`, refetch on mount, `invalidateQueries` (which also replaces a fetch
  already out, so an older answer cannot land after a change).
- **Server pushes**: write what the server sends with `setQueryData`, as a TanStack app writes what
  a websocket brings.
- **Optimistic updates**: `cancelQueries`, snapshot with `getQueryData`, write, and roll back on
  failure; `cancelQueries` restores the state from before the fetch.
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
- [Differences from TanStack Query](#differences-from-tanstack-query)
- [Development](#development)
- [License](#license)

</details>

## At a Glance

```luau
local ReactQuarry = require(ReplicatedStorage.Packages.ReactQuarry)

local function Leaderboard()
	local leaderboard = ReactQuarry.useQuery({
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
Quarry = "quarry-luau/quarry@0.1.0"
ReactQuarry = "quarry-luau/react-quarry@0.1.0" # the React hooks, if you use React-Lua
```

Then `wally install`. Each [release](https://github.com/quarry-luau/quarry/releases) also has
`quarry.rbxm` and `react-quarry.rbxm` to drop into a place without Wally (put `react-quarry` next to
`Quarry` and `React` modules).

## Quick Start

Make one client for the game's lifetime and give it to the React tree:

```luau
local Quarry = require(ReplicatedStorage.Packages.Quarry)
local ReactQuarry = require(ReplicatedStorage.Packages.ReactQuarry)

local client = Quarry.QueryClient.new()

root:render(e(ReactQuarry.QueryClientProvider, { client = client }, e(App)))
```

Read a query anywhere below it:

```luau
local function Coins()
	local coins = ReactQuarry.useQuery({
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

### Data the server pushes

When the server sends state as it changes, write it into the cache. Every component reading the key
updates, and the query never needs to fetch again by itself:

```luau
Remotes.PlayerChanged.OnClientEvent:Connect(function(view)
	client:setQueryData({ "player" }, view)
end)

-- Fetched once on the first mount, then kept current by the pushes.
local player = ReactQuarry.useQuery({
	queryKey = { "player" },
	queryFn = function(): PlayerView
		return Remotes.GetPlayer:InvokeServer()
	end,
	staleTime = math.huge,
})
```

`setQueryData` also takes an updater, `function(old) return new end`; returning `nil` writes
nothing.

### Mutations and optimistic updates

`useMutation` runs a server action and reports `isPending`, `isSuccess`, `isError` and `error`. What
`onMutate` returns is handed to `onError`, `onSuccess` and `onSettled`, so a roll-back gets the data
from before:

```luau
local buy = ReactQuarry.useMutation({
	mutationFn = function(item: string)
		local outcome = Remotes.Buy:InvokeServer(item)
		if outcome ~= "Done" then
			error(outcome, 0) -- fails the mutation
		end
	end,
	onMutate = function(item: string): unknown
		client:cancelQueries({ queryKey = { "player" } }) -- an older answer cannot land after
		local previous = client:getQueryData({ "player" })
		client:setQueryData({ "player" }, function(old: unknown): unknown
			return applyPurchase(old, item)
		end)
		return previous
	end,
	onError = function(_: unknown, _: unknown, previous: unknown)
		client:setQueryData({ "player" }, previous)
		client:invalidateQueries({ queryKey = { "player" } }) -- and fetch the truth
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
local trail = ReactQuarry.useQuerySelect(playerQuery, function(player: PlayerView): number
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
local client = Quarry.QueryClient.new({ scheduler = fakeScheduler })
```

A scheduler is `{ spawn, delay, resume, now }` (see `Scheduler.luau`); `Quarry.Scheduler.task()`
is the default, on Luau's task library and `os.clock`. Quarry's own tests run this way in
[Lune](https://lune-org.github.io/docs).

## API

### `QueryClient`

| Method | Does |
|---|---|
| `QueryClient.new(config?)` | `config.defaultOptions.queries` sets defaults for every query (`retry`, `retryDelay`, `gcTime`, `staleTime`, `refetchOnMount`, `retryOnMount`); `config.scheduler` replaces the clock |
| `client:getQueryData(key)` | The data under `key`, or nil |
| `client:getQueryState(key)` | The query's state (`status`, `fetchStatus`, `dataUpdatedAt`, `isInvalidated`, counts) |
| `client:setQueryData(key, dataOrUpdater)` | Writes data; an updater gets the old data; nil writes nothing |
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

`Quarry.hashKey(key)`, `Quarry.partialMatchKey(key, filter)`, `Quarry.replaceEqualDeep(old, new)`,
`Quarry.isCancelledError(value)`, as TanStack exports them.

## Differences from TanStack Query

| TanStack Query | Quarry |
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
lune run check     # format, lint, types, tests, builds: what CI runs
lune run test      # the tests alone; `lune run test Key` filters by path
```

`lib/quarry` is the core and `lib/react-quarry` the React bindings; each is a Wally package. The
core's tests are in `lib/quarry/test` and run in Lune with a scheduler they drive by hand; every rule
ported from TanStack has a test, and each test has been seen to fail when its rule is broken.

**Releasing:** bump `version` in both `wally.toml` files (and `react-quarry`'s dependency on
`quarry`), add the changes to `CHANGELOG.md`, and publish a GitHub release tagged `vX.Y.Z`. The
release workflow checks the versions match the tag, builds the models into the release, and
publishes both packages to Wally.

## License

[MIT](LICENSE). Quarry is a port of [TanStack Query](https://github.com/TanStack/query), © Tanner
Linsley, also MIT; its notice is kept in the license.

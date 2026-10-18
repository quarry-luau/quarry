--!strict
-- Query keys as TanStack Query treats them. A key is an array of strings, numbers, booleans and
-- tables of those; two keys with the same contents are the same key, whatever order a table's
-- fields were written in (`hash`). A filter key matches every key it is a prefix of, a table in it
-- matching by the fields it names (`matches`). `replaceEqualDeep` is TanStack's structural sharing:
-- the new value, reusing every part of the old one that is equal, so an unchanged part keeps its
-- identity and what reads it need not update.

local Unknown = require("./Unknown")

export type QueryKey = { unknown }

local Key = {}

local function sortedKeys(fields: Unknown.Fields): { string }
	local keys: { string } = {}
	for key in fields do
		if type(key) ~= "string" and type(key) ~= "number" then
			error(`a query key's table keys must be strings or numbers, not {type(key)}`, 3)
		end
		table.insert(keys, `{type(key)}:{key}`)
	end
	table.sort(keys)
	return keys
end

local function encode(value: unknown): string
	if type(value) == "string" then
		return string.format("%q", value)
	elseif type(value) == "number" or type(value) == "boolean" or value == nil then
		return tostring(value)
	end
	local fields = Unknown.fields(value)
	if fields == nil then
		error(`a query key cannot hold a {type(value)}`, 3)
	end
	local parts: { string } = {}
	for _, key in sortedKeys(fields) do
		local name = string.match(key, "^%a+:(.*)$") or key
		local raw: unknown = if string.sub(key, 1, 6) == "number" then tonumber(name) else name
		table.insert(parts, `{key}={encode(fields[raw])}`)
	end
	return `\{{table.concat(parts, ",")}}`
end

-- The key as a string that is equal for keys with equal contents.
function Key.hash(key: QueryKey): string
	return encode(key)
end

-- Whether `a` and `b` hold equal values, tables compared field by field.
function Key.deepEqual(a: unknown, b: unknown): boolean
	if a == b then
		return true
	end
	local left, right = Unknown.fields(a), Unknown.fields(b)
	if left == nil or right == nil then
		return false
	end
	for field, value in left do
		if not Key.deepEqual(value, right[field]) then
			return false
		end
	end
	for field in right do
		if left[field] == nil then
			return false
		end
	end
	return true
end

-- Whether `value` has every field `filter` has, equal (tables in it compared the same way).
local function partialEqual(value: unknown, filter: unknown): boolean
	if value == filter then
		return true
	end
	local have, want = Unknown.fields(value), Unknown.fields(filter)
	if have == nil or want == nil then
		return false
	end
	for field, expected in want do
		if not partialEqual(have[field], expected) then
			return false
		end
	end
	return true
end

-- Whether `filter` selects `key`: it is a prefix of it, tables matching on the fields they name.
function Key.matches(key: QueryKey, filter: QueryKey): boolean
	return partialEqual(key, filter)
end

-- `next`, with every part equal to the same part of `previous` replaced by that part.
function Key.replaceEqualDeep(previous: unknown, next: unknown): unknown
	if previous == next then
		return previous
	end
	local old, new = Unknown.fields(previous), Unknown.fields(next)
	if old == nil or new == nil then
		return next
	end
	local shared: Unknown.Fields = {}
	local same, reused = true, false
	for field, value in new do
		local kept = Key.replaceEqualDeep(old[field], value)
		shared[field] = kept
		local unchanged = kept == old[field]
		same = same and unchanged
		reused = reused or (unchanged and type(kept) == "table")
	end
	for field in old do
		if new[field] == nil then
			same = false
		end
	end
	return if same then previous elseif reused then shared else next
end

return Key

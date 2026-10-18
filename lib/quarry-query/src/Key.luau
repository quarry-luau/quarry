--!strict
-- Query keys, as TanStack Query's utils.ts treats them. A key is an array of
-- strings, numbers, booleans and tables of those. Keys with equal contents
-- hash alike, whatever order a table's fields were written in. A filter key
-- matches the keys it is a prefix of, a table in it by the fields it names.
-- replaceEqualDeep is structural sharing: the new value, keeping every part
-- of the old one that is equal, so unchanged parts keep their identity.

local Unknown = require("./Unknown")

export type QueryKey = { unknown }

-- What a key may hold besides strings and tables.
local SCALARS = { number = true, boolean = true, ["nil"] = true }

local Key = {}

-- The table's keys, each as "kind:name", sorted.
local function sortedKeys(fields: Unknown.Fields): { string }
	local keys: { string } = {}
	for key in fields do
		local kind = type(key)
		if kind ~= "string" and kind ~= "number" then
			error(`a query key's table cannot have {kind} keys`, 4)
		end
		table.insert(keys, `{kind}:{key}`)
	end
	table.sort(keys)
	return keys
end

-- The field a sortedKeys entry names.
local function fieldOf(key: string): unknown
	local kind, name = string.match(key, "^(%a+):(.*)$")
	return if kind == "number" then tonumber(name) else name
end

local function encode(value: unknown): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	local fields = Unknown.fields(value)
	if fields == nil then
		if not SCALARS[type(value)] then
			error(`a query key cannot hold a {type(value)}`, 3)
		end
		return tostring(value)
	end
	local parts: { string } = {}
	for _, key in sortedKeys(fields) do
		table.insert(parts, `{key}={encode(fields[fieldOf(key)])}`)
	end
	return `\{{table.concat(parts, ",")}}`
end

-- The key as a string equal for keys with equal contents.
function Key.hash(key: QueryKey): string
	return encode(key)
end

-- Whether every field of the table has an equal field in the other.
local function contains(left: Unknown.Fields, right: Unknown.Fields): boolean
	for field, value in left do
		if not Key.deepEqual(value, right[field]) then
			return false
		end
	end
	return true
end

-- Whether a and b hold equal values, tables compared field by field.
function Key.deepEqual(a: unknown, b: unknown): boolean
	if a == b then
		return true
	end
	local left, right = Unknown.fields(a), Unknown.fields(b)
	if left == nil or right == nil then
		return false
	end
	return contains(left, right) and contains(right, left)
end

-- Whether value has every field filter has, equal at every depth.
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

-- Whether filter selects key: a prefix of it, tables matching on the fields
-- they name.
function Key.matches(key: QueryKey, filter: QueryKey): boolean
	return partialEqual(key, filter)
end

-- Whether old has a field the new table lacks.
local function lost(old: Unknown.Fields, new: Unknown.Fields): boolean
	for field in old do
		if new[field] == nil then
			return true
		end
	end
	return false
end

-- next, with every part equal to the same part of previous replaced by it.
function Key.replaceEqualDeep(previous: unknown, next: unknown): unknown
	if previous == next then
		return previous
	end
	local old, new = Unknown.fields(previous), Unknown.fields(next)
	if old == nil or new == nil then
		return next
	end
	local shared: Unknown.Fields = {}
	local same, reused = not lost(old, new), false
	for field, value in new do
		local kept = Key.replaceEqualDeep(old[field], value)
		shared[field] = kept
		same = same and kept == old[field]
		reused = reused
			or (kept == old[field] and type(kept) == "table")
	end
	return if same then previous elseif reused then shared else next
end

return Key

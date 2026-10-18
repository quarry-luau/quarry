--!strict
-- Views of a value whose type is not known (data from a module, a file or the network), after a
-- runtime check. Each returns nil when the value is not of that kind.

local Unknown = {}

export type Fields = { [unknown]: unknown }
export type Callable = (...unknown) -> ...unknown

-- Invariant: each helper below has checked the value's runtime type before calling this; the
-- result only lets callers read fields or call it, with every result still unknown.
local function view<T>(value: unknown): T
	return value :: any
end

-- The value as a table of unknown fields, when it is a table.
function Unknown.fields(value: unknown): Fields?
	return if type(value) == "table" then view(value) else nil
end

-- The value as a function of unknown arguments and results, when it is a function.
function Unknown.callable(value: unknown): Callable?
	return if type(value) == "function" then view(value) else nil
end

return Unknown

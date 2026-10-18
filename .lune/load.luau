--!strict
-- Requires a file chosen at runtime, with the path relative to this directory (.lune). The checker
-- cannot follow such a require, so the result is `unknown` and callers check its shape.

-- Invariant: `require` accepts any path to a Luau file; only its result type is unknown.
local requirePath = (require :: any) :: (path: string) -> unknown

return function(path: string): unknown
	return requirePath(path)
end

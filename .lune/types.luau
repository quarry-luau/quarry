--!strict
-- Checks what the packages infer, which no runtime test can see: in each
-- file under lib/*/types, every `never` assignment is a deliberate error, and
-- the type luau-lsp names in it must be the one its `-- expect:` comment
-- gives. A free generic ('a) in its place means inference was lost. Any
-- other error in those files fails too.
-- Usage: lune run types (after lune run analyze has fetched the definitions)

local fs = require("@lune/fs")
local process = require("@lune/process")

local DEFINITIONS_PATH = ".cache/globalTypes.d.luau"
local FOUND = "^.-%((%d+),%d+%): TypeError: Expected this to be "
	.. "unreachable, but got (.+)$"

type Check = { file: string, line: number, expected: string }

local function typeFiles(): { string }
	local files = {}
	for _, package in fs.readDir("lib") do
		local folder = `lib/{package}/types`
		if fs.isDir(folder) then
			for _, name in fs.readDir(folder) do
				table.insert(files, `{folder}/{name}`)
			end
		end
	end
	table.sort(files)
	return files
end

local function expectations(file: string): { Check }
	local checks = {}
	for index, line in string.split(fs.readFile(file), "\n") do
		local expected = string.match(line, "%-%- expect: (.-)%s*$")
		if expected then
			table.insert(checks, {
				file = file,
				line = index,
				expected = expected,
			})
		end
	end
	return checks
end

-- The type each line's deliberate error names, by line, and every other
-- error luau-lsp reports in `file`.
local function analyze(file: string): ({ [number]: string }, { string })
	local result = process.exec("luau-lsp", {
		"analyze",
		"--platform=roblox",
		"--sourcemap=sourcemap.json",
		`--definitions=@roblox={DEFINITIONS_PATH}`,
		"--settings=.vscode/settings.json",
		file,
	})
	-- A long message continues on the next line, indented.
	local output =
		string.gsub(result.stdout .. result.stderr, "\r?\n%s+", " ")
	local found, other = {}, {}
	for _, line in string.split(output, "\n") do
		local number, named = string.match(line, FOUND)
		if number and named then
			found[tonumber(number) or 0] = string.match(
				named,
				"^'(.*)'%s*$"
			) or named
		elseif string.find(line, "%(%d+,%d+%): %a*Error:") then
			table.insert(other, line)
		end
	end
	return found, other
end

local failures = 0
for _, file in typeFiles() do
	local found, other = analyze(file)
	for _, problem in other do
		failures += 1
		print(problem)
	end
	for _, check in expectations(file) do
		local got = found[check.line]
		if got ~= check.expected then
			failures += 1
			local where = `{file}:{check.line}`
			local shown = got or "nothing"
			print(`{where}: inferred {shown}, not {check.expected}`)
		end
	end
end
print(`{failures} inference problems`)
if failures > 0 then
	process.exit(1)
end

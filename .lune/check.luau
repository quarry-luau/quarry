--!strict
-- Everything CI checks: the license copies, format, style, lint, types,
-- tests, and that both packages build.
-- Usage: lune run check (after lune run install)

local fs = require("@lune/fs")
local process = require("@lune/process")
local run = require("./run")

-- MIT asks for the notice in every copy: each package carries the root LICENSE.
local license = fs.readFile("LICENSE")
for _, name in { "quarry-query", "quarry-react-query" } do
	if fs.readFile(`lib/{name}/LICENSE`) ~= license then
		print(`lib/{name}/LICENSE differs from LICENSE; copy it over`)
		process.exit(1)
	end
end

run("stylua", { "--check", "lib", ".lune" })
run("lune", { "run", "style" })
run("selene", { "lib" })
run("lune", { "run", "analyze" })
run("lune", { "run", "test" })
run("lune", { "run", "build" })
print("All checks passed")

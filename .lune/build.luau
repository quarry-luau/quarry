--!strict
-- Builds each package as a Roblox model (build/<name>.rbxm), for the release's downloads and for
-- dropping into a place without Wally. Usage: lune run build

local fs = require("@lune/fs")
local run = require("./run")

fs.writeDir("build")
for _, name in { "quarry", "react-quarry" } do
	run("rojo", { "build", `lib/{name}`, "--output", `build/{name}.rbxm` })
end

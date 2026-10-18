--!strict
-- Installs the development packages (React, for type checking the bindings), writes the
-- sourcemap and adds types to the package links. Usage: lune run install

local run = require("./run")

run("wally", { "install" })
run("rojo", { "sourcemap", "dev.project.json", "--output", "sourcemap.json" })
run("wally-package-types", { "--sourcemap", "sourcemap.json", "Packages/" })

--!strict
-- Development stand-in for the React dependency, as the link Wally installs in its place: the
-- package and the types the bindings use.
local React = require(script.Parent.Parent.Packages.React)

export type ReactNode = React.ReactNode

return React

local source = readfile("bsv2.lua")
local run, compileError = loadstring(source)
assert(run, compileError)
run()

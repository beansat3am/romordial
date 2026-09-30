local base = "https://raw.githubusercontent.com/beansat3am/romordial/main/"
local source = game:HttpGet(base .. "bsv2.lua")
local run, compileError = loadstring(source)
assert(run, compileError)
if type(writefile) == "function" then
    pcall(function()
        writefile("romordial-hourglass.png", game:HttpGet(base .. "romordial-hourglass.png"))
    end)
end
run()

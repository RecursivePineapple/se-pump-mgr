
local package = require("package")

package.loaded["se_pump_mgr.logging"] = nil
package.loaded["se_pump_mgr.utils"] = nil
package.loaded["se_pump_mgr.fluids"] = nil

local component = require("component")
local os = require("os")
local event = require("event")
local sides = require("sides")
local colors = require("colors")
local term = require("term")
local math = require("math")

local logging = require("se_pump_mgr.logging")
local utils = require("se_pump_mgr.utils")
local fluids = require("se_pump_mgr.fluids")

local logger = logging({
    app_name = "se-pump-mgr",
})

local config = utils.load("/etc/se-pump-mgr/fluids.cfg") or {}

if not config.fluids then
    error("fluids to maintain not configured in /etc/se-pump-mgr/fluids.cfg")
end

for fluid, _ in pairs(config.fluids) do
    if not fluids[fluid] then
        error("could not find fluid: " .. fluid)
    end
end

local lookup = {}

lookup[0] = nil

for fluid, ids in pairs(fluids) do
    lookup[ids[1] * 10 + ids[2]] = fluid
end

function comparing(...)
    local keys = table.pack(...)

    return function(a, b)
        for i, value in pairs(keys) do
            if i ~= "n" then
                local inv = false

                local v2 = value

                if value:sub(1, 1) == "-" then
                    v2 = v2:sub(2)
                    inv = true
                end

                local va = a[v2]
                local vb = b[v2]

                if va ~= vb then
                    if inv then
                        return va > vb
                    else
                        return va < vb
                    end
                end
            end
        end

        return false
    end
end

function mk_pump(proxy, tier, index, pump_number)
    local this = {
        proxy = proxy,
        tier = tier,
        index = index,
        pump_number = pump_number
    }

    function this.getFluid()
        return lookup[proxy.getParameters(index, 0) * 10 + proxy.getParameters(index, 1)]
    end

    function this.setFluid(fluid)
        fluid = fluid and fluids[fluid] or {0, 0, "Nothing"}

        if fluid[1] ~= proxy.getParameters(index, 0) or fluid[2] ~= proxy.getParameters(index, 1) then
            proxy.setWorkAllowed(false)

            return {
                deadline = (proxy.getWorkMaxProgress() - proxy.getWorkProgress() + 2) / 20 + os.time() / 72,
                op = function()
                    logger.info("Setting pump " .. pump_number .. ":" .. index .. " to pump " .. fluid[3])

                    for i = 1, 20 do
                        if not proxy.isMachineActive() then break end
                        os.sleep(0.05)
                    end

                    if fluid[1] ~= proxy.getParameters(index, 0) then
                        proxy.setParameters(index, 0, fluid[1])
                    end
            
                    if fluid[2] ~= proxy.getParameters(index, 1) then
                        proxy.setParameters(index, 1, fluid[2])
                    end
                end,
                post = function()
                    proxy.setWorkAllowed(true)
                end
            }
        end
    end

    return this
end

function run_tasks(pending)
    table.sort(pending, comparing("deadline"))
    
    for _, task in pairs(pending) do
        task.op()
    end
    
    for _, task in pairs(pending) do
        task.post()
    end
end

::start::

local pumps = {}
local pump_number = 1

for addr, _ in pairs(component.list("gt_machine")) do
    local proxy = component.proxy(addr)

    local name = proxy.getName()

    if name == "projectmodulepumpt1" then
        table.insert(pumps, mk_pump(proxy, 1, 0, pump_number))
    elseif name == "projectmodulepumpt2" then
        table.insert(pumps, mk_pump(proxy, 2, 0, pump_number))
        table.insert(pumps, mk_pump(proxy, 2, 2, pump_number))
        table.insert(pumps, mk_pump(proxy, 2, 4, pump_number))
        table.insert(pumps, mk_pump(proxy, 2, 6, pump_number))
    elseif name == "projectmodulepumpt3" then
        table.insert(pumps, mk_pump(proxy, 3, 0, pump_number))
        table.insert(pumps, mk_pump(proxy, 3, 2, pump_number))
        table.insert(pumps, mk_pump(proxy, 3, 4, pump_number))
        table.insert(pumps, mk_pump(proxy, 3, 6, pump_number))
    end

    pump_number = pump_number + 1
end

table.sort(pumps, comparing("-tier", "pump_number", "index"))

local to_pump = {}
local status = {}

local amounts = {}

for name, _ in pairs(config.fluids) do
    amounts[name] = 0
end

for _, fluid in pairs(component.me_interface.getFluidsInNetwork()) do
    local fluid_cfg = config.fluids[fluid.name]

    if fluid_cfg then
        amounts[fluid.name] = fluid.amount
    end
end

for name, fluid_cfg in pairs(config.fluids) do
    local s = {
        amount = amounts[name],
        target = fluid_cfg.amount,
        wanted = 0,
        provided = 0,
        priority = fluid_cfg.priority,
    }

    if s.amount < fluid_cfg.amount then
        logger.info("Low fluid detected: " .. fluids[name][3] .. " (has " .. utils.format_int(s.amount) .. "L, needs " .. utils.format_int(fluid_cfg.amount) .. "L)")

        s.wanted = fluid_cfg.pumps or 1

        for i = 1, (fluid_cfg.pumps or 1) do
            table.insert(to_pump, {
                fluid = name,
                priority = fluid_cfg.priority or 1,
            })
        end
    end

    status[name] = s
end

to_pump = utils.shuffle(to_pump)

table.sort(to_pump, comparing("priority"))

local i = 1

local pending = {}

logger.info("Updating pumps")

for _, pump in pairs(pumps) do
    local fluid = to_pump[i]
    i = i + 1

    local task = pump.setFluid(fluid and fluid.fluid or nil)

    if task then table.insert(pending, task) end

    if fluid then
        status[fluid.fluid].provided = status[fluid.fluid].provided + 1
    end
end

run_tasks(pending)

logger.info("Pumps started")

local status_lines = {}

for fluid, status in pairs(status) do
    table.insert(status_lines, {
        fluid=fluids[fluid][3],
        text=fluids[fluid][3] .. ": " ..
            utils.format_int(status.amount) .. "L / " ..utils.format_int(status.target) .. "L " ..
            "(" .. utils.format_int(status.amount / status.target * 100) .. "%) " ..
            "pumps: " .. status.provided .. " / " .. status.wanted
    })
end

table.sort(status_lines, function (a, b) return a.fluid < b.fluid end)

term.clear()

print("Current Fluid Status:")
print()

for _, text in pairs(status_lines) do
    print(text.text)
end

print()
print("Current Pump Status:")
print()

table.sort(pumps, comparing("pump_number", "index"))

for _, pump in pairs(pumps) do
    local fluid = pump.getFluid()

    local fluid_name = fluid and fluids[fluid][3] or "Nothing"

    print("Pump " .. pump.pump_number .. " (parallel " .. math.floor(pump.index / 2) .. ", MK" .. pump.tier .. "): " .. fluid_name)
end

print()
print(string.format("Last updated at %4.2fs Interval: %ds", os.time() / 72 - logger.settings.start_time, config.interval or 10))
print()

if event.pull(config.interval or 10, "interrupt") then
    logger.info("Interrupted: Shutting down pumps")
    print()
    
    local pending = {}

    for _, pump in pairs(pumps) do
        local task = pump.setFluid(nil)

        if task then table.insert(pending, task) end
    end

    run_tasks(pending)

    return
end

goto start

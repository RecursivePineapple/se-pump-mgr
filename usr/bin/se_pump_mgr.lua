
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

for fluid, ids in pairs(fluids) do
    lookup[ids[1] * 10 + ids[2]] = fluid
end

::start::

function mk_pump(proxy, tier, index)
    local this = {
        proxy = proxy,
        tier = tier
    }

    function this.getFluid()
        return lookup[proxy.getParameters(index, 0) * 10 + proxy.getParameters(index, 1)]
    end

    function this.setFluid(fluid)
        fluid = fluid and fluids[fluid] or {0, 0}

        if fluid[1] ~= proxy.getParameters(index, 0) or fluid[2] ~= proxy.getParameters(index, 1) then
            proxy.setWorkAllowed(false)

            return {
                deadline = (proxy.getWorkMaxProgress() - proxy.getWorkProgress() + 2) / 20 + os.time() / 72,
                op = function()
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

local pumps = {}

for addr, _ in pairs(component.list("gt_machine")) do
    local proxy = component.proxy(addr)

    local name = proxy.getName()

    if name == "projectmodulepumpt1" then
        table.insert(pumps, mk_pump(proxy, 1, 0))
    elseif name == "projectmodulepumpt2" then
        table.insert(pumps, mk_pump(proxy, 2, 0))
        table.insert(pumps, mk_pump(proxy, 2, 2))
        table.insert(pumps, mk_pump(proxy, 2, 4))
        table.insert(pumps, mk_pump(proxy, 2, 6))
    elseif name == "projectmodulepumpt3" then
        table.insert(pumps, mk_pump(proxy, 3, 0))
        table.insert(pumps, mk_pump(proxy, 3, 2))
        table.insert(pumps, mk_pump(proxy, 3, 4))
        table.insert(pumps, mk_pump(proxy, 3, 6))
    end
end

table.sort(pumps, function (a, b) return a.tier > b.tier end)

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
        provided = 0
    }

    if s.amount < fluid_cfg.amount then
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

table.sort(to_pump, function (a, b) return a.priority < b.priority end)

local i = 1

local pending = {}

for _, pump in pairs(pumps) do
    local fluid = to_pump[i]
    i = i + 1

    local task = pump.setFluid(fluid and fluid.fluid or nil)

    if task then table.insert(pending, task) end

    if fluid then
        status[fluid.fluid].provided = status[fluid.fluid].provided + 1
    end
end

table.sort(pending, function (a, b) return a.deadline < b.deadline end)

for _, task in pairs(pending) do
    os.sleep(os.time() / 72 - task.deadline)

    task.op()
end

for _, task in pairs(pending) do
    task.post()
end

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

for _, text in pairs(status_lines) do
    print(text.text)
end

if event.pull(config.interval or 10, "interrupt") then
    logger.info("interrupted: shutting down pumps")
    
    local pending = {}

    for _, pump in pairs(pumps) do
        local task = pump.setFluid(nil)

        if task then table.insert(pending, task) end
    end

    table.sort(pending, function (a, b) return a.deadline < b.deadline end)

    for _, task in pairs(pending) do
        os.sleep(os.time() / 72 - task.deadline)
    
        task.op()
    end
    
    for _, task in pairs(pending) do
        task.post()
    end
    
    return
end

goto start

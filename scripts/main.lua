-- ============================================================================
-- main.lua - 超级红温！ 模式分支入口
-- 根据 IsServerMode / IsNetworkMode 分发到对应模块
-- ============================================================================

---@type table
local Module = nil

function Start()
    if IsServerMode and IsServerMode() then
        Module = require("network.Server")
    elseif IsNetworkMode and IsNetworkMode() then
        Module = require("network.Client")
    else
        Module = require("network.Standalone")
    end
    Module.Start()

    -- 订阅事件（全局函数 → 委托给 Module）
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")
end

function Stop()
    if Module and Module.Stop then
        Module.Stop()
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    if Module and Module.HandleUpdate then
        local dt = eventData["TimeStep"]:GetFloat()
        Module.HandleUpdate(dt)
    end
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType, eventData)
    if Module and Module.HandlePostUpdate then
        local dt = eventData["TimeStep"]:GetFloat()
        Module.HandlePostUpdate(dt)
    end
end

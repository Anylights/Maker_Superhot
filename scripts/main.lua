-- ============================================================================
-- main.lua - 超级红温！ 入口文件
-- ============================================================================

---@type table
local Module = nil

function Start()
    print("[Main] Starting game")
    Module = require("Standalone")
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

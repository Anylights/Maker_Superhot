--- ControlLayout.lua
--- 自定义键位布局管理：默认值、云端读写、应用到虚拟控件
--- 所有 position 值基于 1920x1080 设计分辨率

local ControlLayout = {}

------------------------------------------------------------
-- 默认布局（与 Standalone.InitMobileControls 原始值一致）
------------------------------------------------------------

---@return table 默认布局数据
function ControlLayout.GetDefaults()
    return {
        -- 摇杆（左下角，alignment = LEFT, BOTTOM）
        joystick = {
            x = 266, y = -203,          -- position
            baseRadius = 154,
            knobRadius = 56,
            moveRadius = 84,
        },
        -- 跳跃按钮（右下角，alignment = RIGHT, BOTTOM）
        jump = {
            x = -144, y = -211,         -- position
            radius = 98,
        },
        -- 冲刺按钮
        dash = {
            x = -327, y = -144,
            radius = 74,
        },
        -- 下砸按钮
        slam = {
            x = -304, y = -323,
            radius = 74,
        },
        -- 蓄力/爆炸按钮
        charge = {
            x = -110, y = -403,
            radius = 74,
        },
    }
end

------------------------------------------------------------
-- 当前布局（运行时使用）
------------------------------------------------------------

local currentLayout_ = nil   -- 加载后缓存
local loaded_ = false
local loading_ = false

--- 获取当前生效的布局（未加载则返回默认值）
---@return table
function ControlLayout.Get()
    if currentLayout_ then
        return currentLayout_
    end
    return ControlLayout.GetDefaults()
end

--- 布局是否已从云端加载完毕
---@return boolean
function ControlLayout.IsLoaded()
    return loaded_
end

------------------------------------------------------------
-- 云端读写
------------------------------------------------------------

--- 从云端加载自定义布局
---@param callback? fun(layout: table) 加载完成后回调
function ControlLayout.LoadFromCloud(callback)
    if not clientCloud then
        print("[ControlLayout] clientCloud not available, using defaults")
        currentLayout_ = ControlLayout.GetDefaults()
        loaded_ = true
        if callback then callback(currentLayout_) end
        return
    end
    if loading_ then return end
    loading_ = true

    clientCloud:Get("control_layout", {
        ok = function(values, iscores)
            local saved = values.control_layout
            if saved and type(saved) == "table" then
                -- 合并：以默认值为基础，覆盖已保存的字段（兼容新增控件）
                local defaults = ControlLayout.GetDefaults()
                currentLayout_ = ControlLayout._merge(defaults, saved)
                print("[ControlLayout] Loaded custom layout from cloud")
            else
                currentLayout_ = ControlLayout.GetDefaults()
                print("[ControlLayout] No saved layout, using defaults")
            end
            loaded_ = true
            loading_ = false
            if callback then callback(currentLayout_) end
        end,
        error = function(code, reason)
            print("[ControlLayout] Load error: " .. tostring(reason) .. ", using defaults")
            currentLayout_ = ControlLayout.GetDefaults()
            loaded_ = true
            loading_ = false
            if callback then callback(currentLayout_) end
        end,
    })
end

--- 保存当前布局到云端
---@param layout table 要保存的布局数据
---@param callback? fun(success: boolean)
function ControlLayout.SaveToCloud(layout, callback)
    if not clientCloud then
        print("[ControlLayout] clientCloud not available, cannot save")
        if callback then callback(false) end
        return
    end

    currentLayout_ = layout

    clientCloud:Set("control_layout", layout, {
        ok = function()
            print("[ControlLayout] Layout saved to cloud")
            if callback then callback(true) end
        end,
        error = function(code, reason)
            print("[ControlLayout] Save error: " .. tostring(reason))
            if callback then callback(false) end
        end,
    })
end

--- 重置为默认布局并保存到云端
---@param callback? fun(success: boolean)
function ControlLayout.ResetToDefault(callback)
    ControlLayout.SaveToCloud(ControlLayout.GetDefaults(), callback)
end

------------------------------------------------------------
-- 应用布局到已创建的虚拟控件
------------------------------------------------------------

--- 将布局数据应用到虚拟控件实例
---@param layout table
---@param joystick any VirtualJoystick 实例
---@param jumpBtn any VirtualButton 实例
---@param dashBtn any VirtualButton 实例
---@param slamBtn any VirtualButton 实例
---@param chargeBtn any VirtualButton 实例
function ControlLayout.ApplyToControls(layout, joystick, jumpBtn, dashBtn, slamBtn, chargeBtn)
    if not layout then
        print("[ControlLayout] ApplyToControls: layout is nil, skipping")
        return
    end

    print("[ControlLayout] ApplyToControls called, joystick=" .. tostring(joystick ~= nil)
        .. " jumpBtn=" .. tostring(jumpBtn ~= nil))

    if joystick and layout.joystick then
        local j = layout.joystick
        print("[ControlLayout] Joystick: pos=(" .. j.x .. "," .. j.y .. ") baseR=" .. j.baseRadius)
        joystick.position = Vector2(j.x, j.y)
        joystick.baseRadius = j.baseRadius
        joystick.knobRadius = j.knobRadius
        joystick.moveRadius = j.moveRadius
    end

    local function applyButton(name, btn, data)
        if btn and data then
            print("[ControlLayout] " .. name .. ": pos=(" .. data.x .. "," .. data.y .. ") r=" .. data.radius)
            btn.position = Vector2(data.x, data.y)
            btn.radius = data.radius
        end
    end

    applyButton("jump", jumpBtn, layout.jump)
    applyButton("dash", dashBtn, layout.dash)
    applyButton("slam", slamBtn, layout.slam)
    applyButton("charge", chargeBtn, layout.charge)
    print("[ControlLayout] Applied layout to all controls")
end

------------------------------------------------------------
-- 内部工具
------------------------------------------------------------

--- 深度合并：base 为默认值，overlay 为用户保存值
function ControlLayout._merge(base, overlay)
    local result = {}
    for k, v in pairs(base) do
        if type(v) == "table" then
            if type(overlay[k]) == "table" then
                result[k] = {}
                for kk, vv in pairs(v) do
                    result[k][kk] = overlay[k][kk] ~= nil and overlay[k][kk] or vv
                end
            else
                -- overlay 没有这个控件的数据，使用默认
                result[k] = {}
                for kk, vv in pairs(v) do result[k][kk] = vv end
            end
        else
            result[k] = overlay[k] ~= nil and overlay[k] or v
        end
    end
    return result
end

return ControlLayout

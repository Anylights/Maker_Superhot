-- ============================================================================
-- FXDiag.lua - FX 诊断环形缓冲区
-- 用于在游戏内可视化粒子/特效诊断信息（替代 print 日志）
-- ============================================================================

local FXDiag = {}

local MAX_ENTRIES = 30  -- 最多保留 30 条消息
local entries_ = {}

--- 记录一条诊断消息
---@param msg string 消息内容
---@param r? number 颜色 R (0-255)，默认 220
---@param g? number 颜色 G (0-255)，默认 220
---@param b? number 颜色 B (0-255)，默认 220
function FXDiag.Log(msg, r, g, b)
    local entry = {
        msg = msg,
        r = r or 220,
        g = g or 220,
        b = b or 220,
        time = os.clock(),
    }
    table.insert(entries_, entry)
    -- 超过上限时移除最旧的
    if #entries_ > MAX_ENTRIES then
        table.remove(entries_, 1)
    end
    -- 同时 print 一份（服务端或有日志访问时可查）
    print("[FX-DIAG] " .. msg)
end

--- 获取所有诊断条目（只读）
---@return table[] entries
function FXDiag.GetEntries()
    return entries_
end

--- 清空所有条目
function FXDiag.Clear()
    entries_ = {}
end

--- 获取条目数量
---@return number
function FXDiag.Count()
    return #entries_
end

-- 注册到全局，方便跨模块访问
_G.FXDiag = FXDiag

return FXDiag

-- ============================================================================
-- RandomEvent.lua - 局内随机 Buff/Debuff 事件系统
-- 进入 PLAYING 30秒后首次触发，之后每20秒一次，每局最多3次
-- 每次事件持续10秒，伴随背景渐变和屏幕公告
-- ============================================================================

local Config = require("Config")
local Theme  = require("Theme")

local RandomEvent = {}

-- ============================================================================
-- 常量
-- ============================================================================
local FIRST_DELAY    = 30   -- 首次触发延迟（秒）
local INTERVAL       = 20   -- 后续触发间隔（秒）
local DURATION       = 10   -- 每次事件持续时间（秒）
local MAX_TRIGGERS   = 3    -- 每局最大触发次数
local ANNOUNCE_TIME  = 3.0  -- 标题展示时间（秒）
local BG_LERP_SPEED  = 1.5  -- 背景渐变速度（1/秒）

-- ============================================================================
-- 事件定义
-- ============================================================================
local EVENT_DEFS = {
    {
        id    = "wind",
        title = "八级大风！",
        desc  = "所有玩家被向左吹飞",
        bgTop = { 0.15, 0.55, 0.70 },   -- 湖蓝
        bgBot = { 0.10, 0.40, 0.55 },
    },
    {
        id    = "heavy",
        title = "超重！",
        desc  = "所有玩家跳跃高度降低",
        bgTop = { 0.05, 0.08, 0.25 },   -- 深蓝（太空）
        bgBot = { 0.02, 0.04, 0.15 },
    },
    {
        id    = "bloodlust",
        title = "超级嗜血！",
        desc  = "击杀得分翻倍",
        bgTop = { 0.55, 0.08, 0.08 },   -- 红色
        bgBot = { 0.35, 0.04, 0.04 },
    },
    {
        id    = "climb",
        title = "欲穷千里！",
        desc  = "高度提升额外加两倍分数",
        bgTop = { 0.08, 0.30, 0.12 },   -- 深草绿
        bgBot = { 0.05, 0.20, 0.08 },
    },
    {
        id    = "energyboost",
        title = "精力过剩！",
        desc  = "能量积累速度五倍",
        bgTop = { 0.70, 0.35, 0.05 },   -- 橙色
        bgBot = { 0.50, 0.22, 0.03 },
    },
}

-- ============================================================================
-- 状态
-- ============================================================================
local active_        = false   -- 当前是否有事件激活
local currentDef_    = nil     -- 当前事件定义（EVENT_DEFS 条目）
local lastDef_       = nil     -- 上一个事件定义（渐出时用）
local eventTimer_    = 0       -- 事件剩余时间
local elapsedPlay_   = 0       -- PLAYING 状态累计时间
local triggeredCount_ = 0      -- 本局已触发次数
local nextTrigger_   = FIRST_DELAY  -- 下次触发的 elapsed 阈值
local announceTimer_ = 0       -- 公告剩余展示时间

-- 背景渐变
local bgLerp_        = 0       -- 0 = 原始色, 1 = 目标事件色
local originalBgTop_ = nil     -- 缓存原始背景色
local originalBgBot_ = nil

-- 避免连续重复同一事件
local lastEventIndex_ = 0

-- NanoVG 引用（由 HUD 传入）
---@type integer
local vg_ = nil

-- ============================================================================
-- 初始化 / 重置
-- ============================================================================
function RandomEvent.Init()
    active_        = false
    currentDef_    = nil
    lastDef_       = nil
    eventTimer_    = 0
    elapsedPlay_   = 0
    triggeredCount_ = 0
    nextTrigger_   = FIRST_DELAY
    announceTimer_ = 0
    bgLerp_        = 0
    lastEventIndex_ = 0
    originalBgTop_ = { Config.BgColorTop[1], Config.BgColorTop[2], Config.BgColorTop[3] }
    originalBgBot_ = { Config.BgColorBot[1], Config.BgColorBot[2], Config.BgColorBot[3] }
end

-- ============================================================================
-- 每帧更新（仅在 PLAYING 状态调用）
-- ============================================================================
function RandomEvent.Update(dt)
    elapsedPlay_ = elapsedPlay_ + dt

    -- 事件激活中
    if active_ then
        eventTimer_ = eventTimer_ - dt
        announceTimer_ = announceTimer_ - dt

        -- 背景渐入
        if bgLerp_ < 1.0 then
            bgLerp_ = math.min(1.0, bgLerp_ + BG_LERP_SPEED * dt)
        end

        -- 事件结束
        if eventTimer_ <= 0 then
            active_ = false
            lastDef_ = currentDef_   -- 保留用于渐出
            currentDef_ = nil
            eventTimer_ = 0
        end
    else
        -- 背景渐出回原色
        if bgLerp_ > 0 then
            bgLerp_ = math.max(0, bgLerp_ - BG_LERP_SPEED * dt)
        end

        -- 检查是否该触发下一个事件
        if triggeredCount_ < MAX_TRIGGERS and elapsedPlay_ >= nextTrigger_ then
            RandomEvent.TriggerRandom()
        end
    end
end

-- ============================================================================
-- 触发随机事件
-- ============================================================================
function RandomEvent.TriggerRandom()
    -- 随机选一个事件（避免连续重复）
    local idx
    repeat
        idx = math.random(1, #EVENT_DEFS)
    until idx ~= lastEventIndex_ or #EVENT_DEFS <= 1
    lastEventIndex_ = idx

    currentDef_    = EVENT_DEFS[idx]
    active_        = true
    eventTimer_    = DURATION
    announceTimer_ = ANNOUNCE_TIME
    bgLerp_        = 0  -- 从0开始渐入
    triggeredCount_ = triggeredCount_ + 1
    nextTrigger_   = elapsedPlay_ + DURATION + INTERVAL  -- 当前事件结束后再等 INTERVAL

    print("[RandomEvent] Triggered: " .. currentDef_.title .. " (#" .. triggeredCount_ .. ")")
end

-- ============================================================================
-- 效果查询接口（供 Player 调用）
-- ============================================================================

--- 返回风力（m/s²），0 = 无风
function RandomEvent.GetWindForce()
    if active_ and currentDef_ and currentDef_.id == "wind" then
        return -36.0   -- 向左吹
    end
    return 0
end

--- 返回跳跃速度乘数
function RandomEvent.GetJumpSpeedMul()
    if active_ and currentDef_ and currentDef_.id == "heavy" then
        return 0.6
    end
    return 1.0
end

--- 返回击杀得分乘数
function RandomEvent.GetKillScoreMul()
    if active_ and currentDef_ and currentDef_.id == "bloodlust" then
        return 2
    end
    return 1
end

--- 返回高度得分乘数
function RandomEvent.GetHeightScoreMul()
    if active_ and currentDef_ and currentDef_.id == "climb" then
        return 3   -- 基础 + 额外2倍 = 3倍
    end
    return 1
end

--- 返回能量充能速度乘数
function RandomEvent.GetEnergyChargeMul()
    if active_ and currentDef_ and currentDef_.id == "energyboost" then
        return 5
    end
    return 1
end

-- ============================================================================
-- 背景颜色查询（供 Standalone 更新 3D 背景材质）
-- ============================================================================

--- 返回 lerp 后的背景 top/bot 颜色（各3个浮点数）
--- 没有事件或 lerp=0 时返回 nil（表示无需覆盖）
function RandomEvent.GetBgColors()
    if bgLerp_ <= 0 then return nil end

    local def = currentDef_ or lastDef_
    if not def then return nil end

    local targetTop = def.bgTop
    local targetBot = def.bgBot

    local t = bgLerp_
    local oT = originalBgTop_
    local oB = originalBgBot_
    local topR = oT[1] + (targetTop[1] - oT[1]) * t
    local topG = oT[2] + (targetTop[2] - oT[2]) * t
    local topB = oT[3] + (targetTop[3] - oT[3]) * t
    local botR = oB[1] + (targetBot[1] - oB[1]) * t
    local botG = oB[2] + (targetBot[2] - oB[2]) * t
    local botB = oB[3] + (targetBot[3] - oB[3]) * t

    return { topR, topG, topB }, { botR, botG, botB }
end

--- 返回当前 bgLerp（用于渐出时保存目标色）
function RandomEvent.GetBgLerp()
    return bgLerp_
end

--- 返回当前事件定义（渐出时需要知道上一个事件的目标色）
function RandomEvent.GetCurrentDef()
    return currentDef_
end

function RandomEvent.IsActive()
    return active_
end

-- ============================================================================
-- 屏幕公告绘制（NanoVG，由 HUD 调用）
-- ============================================================================

--- 绘制事件公告（屏幕中央标题 + 副标题）
---@param vg integer NanoVG 上下文
---@param w number 逻辑屏幕宽
---@param h number 逻辑屏幕高
function RandomEvent.DrawAnnouncement(vg, w, h)
    if announceTimer_ <= 0 or currentDef_ == nil then return end

    local elapsed = ANNOUNCE_TIME - announceTimer_
    local progress = elapsed / ANNOUNCE_TIME  -- 0 → 1

    -- 透明度：快速出现，持续显示，最后淡出
    local alpha
    if progress < 0.1 then
        alpha = progress / 0.1                  -- 0→1 淡入（0.3秒）
    elseif progress > 0.8 then
        alpha = (1.0 - progress) / 0.2          -- 1→0 淡出
    else
        alpha = 1.0
    end
    alpha = math.max(0, math.min(1, alpha))

    -- 缩放弹入效果
    local scale
    if progress < 0.1 then
        local t = progress / 0.1
        scale = 1.5 - 0.5 * t  -- 1.5 → 1.0
    else
        scale = 1.0
    end

    local cx = w * 0.5
    local cy = h * 0.38

    -- 半透明背景遮罩条
    nvgBeginPath(vg)
    nvgRect(vg, 0, cy - 40 * scale, w, 90 * scale)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(alpha * 100)))
    nvgFill(vg)

    -- 标题
    nvgFontFace(vg, "bold")
    nvgFontSize(vg, math.floor(42 * scale))
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    -- 阴影
    nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(alpha * 180)))
    nvgText(vg, cx + 2, cy + 2, currentDef_.title)
    -- 主文字（金色）
    nvgFillColor(vg, nvgRGBA(255, 220, 80, math.floor(alpha * 255)))
    nvgText(vg, cx, cy, currentDef_.title)

    -- 副标题
    nvgFontFace(vg, "sans")
    nvgFontSize(vg, math.floor(18 * scale))
    nvgFillColor(vg, nvgRGBA(255, 255, 255, math.floor(alpha * 200)))
    nvgText(vg, cx, cy + 32 * scale, currentDef_.desc)
end

return RandomEvent

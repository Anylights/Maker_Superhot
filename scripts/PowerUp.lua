-- ============================================================================
-- PowerUp.lua - 特殊道具效果管理模块
-- 管理：道具拾取 → 效果应用 → 倒计时 → 效果移除 → 视觉表现
-- 每个玩家同时只能有一个 buff，新 buff 替换旧 buff
-- ============================================================================

local Config = require("Config")
local Camera = require("Camera")

local PowerUp = {}

-- 道具效果类型
PowerUp.SUPER_BIG      = "superBig"
PowerUp.SUPER_SMALL    = "superSmall"
PowerUp.INFINITE_DASH  = "infiniteDash"
PowerUp.UNSTOPPABLE    = "unstoppable"
PowerUp.INSTANT_HOT    = "instantHot"

-- 所有效果类型列表（用于随机选取）
PowerUp.ALL_TYPES = {
    PowerUp.SUPER_BIG,
    PowerUp.SUPER_SMALL,
    PowerUp.INFINITE_DASH,
    PowerUp.UNSTOPPABLE,
    PowerUp.INSTANT_HOT,
}

-- 每个玩家的 buff 状态 { [playerIndex] = { type, remaining, duration } }
local buffs_ = {}

-- 模块引用
local playerModule_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化道具系统
---@param playerRef table Player 模块引用
function PowerUp.Init(playerRef)
    playerModule_ = playerRef
    buffs_ = {}
    print("[PowerUp] Initialized")
end

-- ============================================================================
-- 核心接口
-- ============================================================================

--- 应用道具效果到指定玩家
---@param playerIndex number 玩家编号
---@param effectType string 效果类型（PowerUp.SUPER_BIG 等）
function PowerUp.Apply(playerIndex, effectType)
    -- 如果已有 buff，先移除旧的
    if buffs_[playerIndex] then
        PowerUp.Remove(playerIndex)
    end

    local duration = Config.PowerUpDuration
    buffs_[playerIndex] = {
        type = effectType,
        remaining = duration,
        duration = duration,
    }

    -- 查找玩家数据
    local p = PowerUp.FindPlayer(playerIndex)
    if not p then return end

    -- 应用即时效果
    if effectType == PowerUp.UNSTOPPABLE then
        -- 势如破竹：保存原始碰撞 mask（每帧根据速度方向动态切换）
        if p.body then
            p.savedCollisionMask = p.body.collisionMask
        end
    elseif effectType == PowerUp.INSTANT_HOT then
        -- 直接红温：立即充满能量
        p.energy = 1.0
    end

    -- 保存原始 scale 数据（用于变大/变小恢复）
    if effectType == PowerUp.SUPER_BIG or effectType == PowerUp.SUPER_SMALL then
        p.powerUpTargetScale = (effectType == PowerUp.SUPER_BIG)
            and Config.SuperBigScale or Config.SuperSmallScale
        p.powerUpCurrentScale = 1.0  -- 从当前 1.0 开始 lerp
    end

    print("[PowerUp] Applied " .. effectType .. " to player " .. playerIndex)
end

--- 移除玩家的道具效果
---@param playerIndex number
function PowerUp.Remove(playerIndex)
    local buff = buffs_[playerIndex]
    if not buff then return end

    local p = PowerUp.FindPlayer(playerIndex)
    if p then
        local effectType = buff.type

        if effectType == PowerUp.UNSTOPPABLE then
            -- 势如破竹结束：恢复碰撞 mask
            if p.body then
                p.body.collisionMask = p.savedCollisionMask or 0xFFFF
                p.savedCollisionMask = nil
            end
        end

        if effectType == PowerUp.SUPER_BIG or effectType == PowerUp.SUPER_SMALL then
            -- 开始反向 lerp 回 1.0
            p.powerUpTargetScale = 1.0
            -- powerUpCurrentScale 保持当前值，在 Update 中 lerp 回去
        end

        -- 隐藏光晕
        PowerUp.HideGlow(p)
    end

    buffs_[playerIndex] = nil
    print("[PowerUp] Removed buff from player " .. playerIndex)
end

--- 每帧更新所有 buff（倒计时 + 持续效果逻辑）
---@param dt number
function PowerUp.Update(dt)
    if not playerModule_ then return end

    -- 收集需要移除的 buff（不要在遍历中直接修改）
    local toRemove = {}

    for playerIndex, buff in pairs(buffs_) do
        buff.remaining = buff.remaining - dt
        if buff.remaining <= 0 then
            table.insert(toRemove, playerIndex)
        else
            -- 持续效果逻辑
            local p = PowerUp.FindPlayer(playerIndex)
            if p and p.alive then
                PowerUp.ApplyPerFrame(p, buff.type, dt)
            elseif p and not p.alive then
                -- 玩家死亡，移除 buff
                table.insert(toRemove, playerIndex)
            end
        end
    end

    for _, idx in ipairs(toRemove) do
        PowerUp.Remove(idx)
    end

    -- 更新所有玩家的 scale lerp（即使 buff 已移除，仍需 lerp 回 1.0）
    for _, p in ipairs(playerModule_.list) do
        PowerUp.UpdateScaleLerp(p, dt)
    end
end

--- 每帧持续效果
---@param p table 玩家数据
---@param effectType string
---@param dt number
local function applyPerFrame(p, effectType, dt)
    if effectType == PowerUp.INFINITE_DASH then
        -- 无限冲刺：每帧重置冷却
        p.dashCooldown = 0

    elseif effectType == PowerUp.UNSTOPPABLE then
        -- 势如破竹：向上运动时关闭平台碰撞，下落/静止时恢复碰撞
        if p.body then
            local velY = p.body.linearVelocity.y
            local baseMask = p.savedCollisionMask or 0xFFFF
            if velY > 0.5 then
                -- 向上运动：穿透平台（移除 layer 1）
                p.body.collisionMask = baseMask & 0xFFFE
            else
                -- 下落或静止：正常碰撞
                p.body.collisionMask = baseMask
            end
        end

    elseif effectType == PowerUp.INSTANT_HOT then
        -- 直接红温：蓄力时立即设满 chargeTimer
        if p.charging then
            p.chargeTimer = p.explosionChargeTime
            p.chargeProgress = 1.0
        end

    elseif effectType == PowerUp.SUPER_SMALL then
        -- 变小增强：跳跃和冲刺都增强（通过每帧修改速度属性实现临时效果不合适）
        -- 实际在 Player.lua 中通过查询 PowerUp.HasEffect 来调整
    end

    -- 角色发光脉冲效果
    PowerUp.ApplyGlow(p, effectType, dt)
end

-- 暴露给外部的 per-frame 接口
function PowerUp.ApplyPerFrame(p, effectType, dt)
    applyPerFrame(p, effectType, dt)
end

-- ============================================================================
-- Scale Lerp（变大/变小的平滑过渡）
-- ============================================================================

--- 更新角色 scale 的 lerp
---@param p table 玩家数据
---@param dt number
function PowerUp.UpdateScaleLerp(p, dt)
    if not p.powerUpTargetScale then return end
    if not p.powerUpCurrentScale then
        p.powerUpCurrentScale = 1.0
    end

    local target = p.powerUpTargetScale
    local current = p.powerUpCurrentScale
    local diff = target - current

    if math.abs(diff) < 0.01 then
        p.powerUpCurrentScale = target
        -- lerp 完成且目标是 1.0 时清理
        if target == 1.0 then
            p.powerUpTargetScale = nil
            p.powerUpCurrentScale = nil
        end
        return
    end

    -- 平滑 lerp
    p.powerUpCurrentScale = current + diff * math.min(1.0, Config.ScaleLerpSpeed * dt)

    -- 同步碰撞体尺寸
    if p.node then
        local s = p.powerUpCurrentScale
        local shape = p.node:GetComponent("CollisionShape")
        if shape then
            shape:SetCapsule(0.9 * s, 1.0 * s)
        end
    end
end

--- 获取玩家当前的 scale 倍率（供 UpdateVisualEffects 使用）
---@param p table
---@return number scale 当前 scale 倍率（默认 1.0）
function PowerUp.GetScale(p)
    return p.powerUpCurrentScale or 1.0
end

-- ============================================================================
-- 发光效果
-- ============================================================================

--- 角色光晕脉冲（使用 GlowHalo 子节点，而非角色自身 emissive）
---@param p table
---@param effectType string
---@param dt number
function PowerUp.ApplyGlow(p, effectType, dt)
    if not p.visualNode then return end

    local halo = p.visualNode:GetChild("GlowHalo")
    if not halo then return end

    local color = Config.PowerUpColors[effectType]
    if not color then return end

    local buff = buffs_[p.index]
    if not buff then return end

    -- 启用光晕节点
    halo.enabled = true

    local elapsed = buff.duration - buff.remaining

    -- 脉冲动画：透明度 0.25~0.55，emissive 强度 0.4~0.8
    local pulse = 0.5 + 0.3 * math.sin(elapsed * 4.0)
    local alphaPulse = 0.25 + 0.3 * math.sin(elapsed * 3.0)

    -- 最后 3 秒闪烁加快
    if buff.remaining < 3.0 then
        pulse = 0.5 + 0.4 * math.sin(elapsed * 10.0)
        alphaPulse = 0.2 + 0.35 * math.sin(elapsed * 8.0)
    end

    local model = halo:GetComponent("StaticModel")
    if model then
        local mat = model:GetMaterial(0)
        if mat then
            mat:SetShaderParameter("MatDiffColor", Variant(Color(color.r, color.g, color.b, alphaPulse)))
            mat:SetShaderParameter("MatEmissiveColor", Variant(Color(color.r * pulse, color.g * pulse, color.b * pulse)))
        end
    end
end

--- 隐藏角色光晕
---@param p table
function PowerUp.HideGlow(p)
    if not p.visualNode then return end
    local halo = p.visualNode:GetChild("GlowHalo")
    if halo then
        halo.enabled = false
    end
end

-- ============================================================================
-- 查询接口
-- ============================================================================

--- 查询玩家是否有指定效果
---@param playerIndex number
---@param effectType string
---@return boolean
function PowerUp.HasEffect(playerIndex, effectType)
    local buff = buffs_[playerIndex]
    return buff ~= nil and buff.type == effectType
end

--- 查询玩家是否有任何 buff
---@param playerIndex number
---@return boolean
function PowerUp.HasAnyEffect(playerIndex)
    return buffs_[playerIndex] ~= nil
end

--- 获取玩家 buff 剩余时间
---@param playerIndex number
---@return number 剩余时间（无 buff 返回 0）
function PowerUp.GetRemaining(playerIndex)
    local buff = buffs_[playerIndex]
    return buff and buff.remaining or 0
end

--- 获取玩家当前 buff 类型
---@param playerIndex number
---@return string|nil
function PowerUp.GetEffectType(playerIndex)
    local buff = buffs_[playerIndex]
    return buff and buff.type or nil
end

--- 获取效果颜色
---@param effectType string
---@return Color
function PowerUp.GetEffectColor(effectType)
    return Config.PowerUpColors[effectType] or Color(1, 1, 1, 1)
end

--- 获取效果名称
---@param effectType string
---@return string
function PowerUp.GetEffectName(effectType)
    return Config.PowerUpNames[effectType] or "未知"
end

--- 获取随机效果类型
---@return string
function PowerUp.GetRandomType()
    return PowerUp.ALL_TYPES[math.random(1, #PowerUp.ALL_TYPES)]
end

-- ============================================================================
-- HUD 绘制（NanoVG）
-- ============================================================================

--- 绘制 buff 状态 HUD（屏幕上方居中）
--- 仅显示人类玩家（P1）的 buff
---@param vg number NanoVG context
---@param w number 逻辑宽度
---@param h number 逻辑高度
function PowerUp.DrawBuffHUD(vg, w, h)
    local buff = buffs_[1]  -- P1 = 人类玩家
    if not buff then return end

    local name = Config.PowerUpNames[buff.type] or "???"
    local color = Config.PowerUpColors[buff.type] or Color(1, 1, 1, 1)
    local remaining = buff.remaining
    local duration = buff.duration

    -- 位置：屏幕上方 12% 处居中
    local cx = w * 0.5
    local cy = h * 0.12

    -- 最后 3 秒闪烁
    local alpha = 1.0
    if remaining < 3.0 then
        alpha = 0.5 + 0.5 * math.abs(math.sin(remaining * 5.0))
    end

    -- 背景圆角矩形
    local textStr = name .. "  " .. string.format("%.1f", math.max(0, remaining)) .. "s"
    local fontSize = math.min(w, h) * 0.035
    nvgFontSize(vg, fontSize)
    nvgFontFace(vg, "sans")

    -- 测量文本宽度
    local bounds = {0, 0, 0, 0}
    local tw = nvgTextBounds(vg, 0, 0, textStr, bounds)
    local padding = fontSize * 0.6
    local bgW = tw + padding * 2
    local bgH = fontSize * 1.6

    -- 背景
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cx - bgW * 0.5, cy - bgH * 0.5, bgW, bgH, bgH * 0.3)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(160 * alpha)))
    nvgFill(vg)

    -- 进度条底色
    nvgBeginPath(vg)
    local barY = cy + bgH * 0.5 - 3
    nvgRoundedRect(vg, cx - bgW * 0.5 + 2, barY, bgW - 4, 3, 1.5)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 30))
    nvgFill(vg)

    -- 进度条
    local progress = remaining / duration
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cx - bgW * 0.5 + 2, barY, (bgW - 4) * progress, 3, 1.5)
    local cr = math.floor(color.r * 255)
    local cg = math.floor(color.g * 255)
    local cb = math.floor(color.b * 255)
    nvgFillColor(vg, nvgRGBA(cr, cg, cb, math.floor(220 * alpha)))
    nvgFill(vg)

    -- 文字
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    -- 阴影
    nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(180 * alpha)))
    nvgText(vg, cx + 1, cy - 2 + 1, textStr)
    -- 正文（效果颜色）
    nvgFillColor(vg, nvgRGBA(cr, cg, cb, math.floor(255 * alpha)))
    nvgText(vg, cx, cy - 2, textStr)
end

-- ============================================================================
-- 辅助
-- ============================================================================

--- 通过 playerIndex 查找玩家数据
---@param playerIndex number
---@return table|nil
function PowerUp.FindPlayer(playerIndex)
    if not playerModule_ then return nil end
    for _, p in ipairs(playerModule_.list) do
        if p.index == playerIndex then
            return p
        end
    end
    return nil
end

--- 清除所有 buff（回合重置时调用）
function PowerUp.ClearAll()
    for playerIndex, _ in pairs(buffs_) do
        PowerUp.Remove(playerIndex)
    end
    buffs_ = {}
    -- 清除所有玩家的 scale 状态
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            p.powerUpTargetScale = nil
            p.powerUpCurrentScale = nil
        end
    end
    print("[PowerUp] Cleared all buffs")
end

return PowerUp

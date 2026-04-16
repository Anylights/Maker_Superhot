-- ============================================================================
-- HUD.lua - NanoVG 游戏 HUD
-- 显示：能量条、分数、倒计时、回合计时器、状态覆盖层
-- 世界空间指示器：冲刺冷却环、爆炸警告区域
-- 使用 NanoVG Mode B（系统逻辑分辨率）
-- ============================================================================

local Config = require("Config")
local Camera = require("Camera")

local HUD = {}

-- Map 模块引用（由 main 注入）
local mapModule_ = nil

-- NanoVG 上下文
---@type number
local vg_ = nil

-- 分辨率变量（Mode B）
local physW_, physH_ = 0, 0
local dpr_ = 1.0
local logW_, logH_ = 0, 0

-- 字体句柄
local fontNormal_ = -1
local fontBold_ = -1

-- 模块引用（由 main 注入）
local playerModule_ = nil
local gameManager_ = nil

-- 动画
local countdownScale_ = 1.0
local flashAlpha_ = 0

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化 HUD
---@param playerRef table
---@param gmRef table
---@param mapRef table|nil
function HUD.Init(playerRef, gmRef, mapRef)
    playerModule_ = playerRef
    gameManager_ = gmRef
    mapModule_ = mapRef

    vg_ = nvgCreate(1)  -- 1 = NVG_ANTIALIAS

    -- 刷新分辨率
    HUD.RefreshResolution()

    -- 创建字体（只调用一次）
    fontNormal_ = nvgCreateFont(vg_, "sans", "Fonts/MiSans-Regular.ttf")
    fontBold_ = nvgCreateFont(vg_, "bold", "Fonts/MiSans-Regular.ttf")

    -- 订阅渲染事件（NanoVG 事件需要以 vg_ 为事件源）
    SubscribeToEvent(vg_, "NanoVGRender", "HandleNanoVGRender")
    SubscribeToEvent("ScreenMode", "HandleScreenMode_HUD")

    print("[HUD] Initialized")
end

--- 刷新分辨率数据
function HUD.RefreshResolution()
    physW_ = graphics:GetWidth()
    physH_ = graphics:GetHeight()
    dpr_ = graphics:GetDPR()
    logW_ = physW_ / dpr_
    logH_ = physH_ / dpr_
end

-- ============================================================================
-- 渲染
-- ============================================================================

function HandleNanoVGRender(eventType, eventData)
    if vg_ == nil then return end

    nvgBeginFrame(vg_, logW_, logH_, dpr_)

    local state = gameManager_ and gameManager_.state or "racing"

    -- 主菜单
    if state == "menu" then
        HUD.DrawMenu()
        nvgEndFrame(vg_)
        return
    end

    -- 世界空间指示器（在 HUD 元素下面绘制）
    if state == "racing" then
        HUD.DrawWorldIndicators()
    end

    HUD.DrawEnergyBars()
    HUD.DrawScores()

    if state == "racing" then
        HUD.DrawRoundTimer()
    end

    HUD.DrawRoundInfo()

    if state == "countdown" then
        HUD.DrawCountdown()
    elseif state == "roundEnd" then
        HUD.DrawRoundEnd()
    elseif state == "score" then
        HUD.DrawScoreScreen()
    elseif state == "matchEnd" then
        HUD.DrawMatchEnd()
    end

    nvgEndFrame(vg_)
end

function HandleScreenMode_HUD(eventType, eventData)
    HUD.RefreshResolution()
end

-- ============================================================================
-- 世界空间指示器
-- ============================================================================

--- 绘制虚线圆（用于爆炸警告区域）
---@param cx number 中心 X
---@param cy number 中心 Y
---@param radius number 半径
---@param r number 红
---@param g number 绿
---@param b number 蓝
---@param a number 透明度
---@param strokeW number 线宽
local function drawDashedCircle(cx, cy, radius, r, g, b, a, strokeW)
    local segments = 24
    local dashLen = math.pi * 2 / segments  -- 每段弧度
    nvgStrokeColor(vg_, nvgRGBA(r, g, b, a))
    nvgStrokeWidth(vg_, strokeW)
    for i = 0, segments - 1, 2 do
        local startAngle = i * dashLen - math.pi * 0.5
        local endAngle = startAngle + dashLen * 0.8
        nvgBeginPath(vg_)
        nvgArc(vg_, cx, cy, radius, startAngle, endAngle, NVG_CW)
        nvgStroke(vg_)
    end
end

--- 绘制世界空间指示器（冲刺冷却环、爆炸警告区域）
function HUD.DrawWorldIndicators()
    if playerModule_ == nil then return end

    for _, p in ipairs(playerModule_.list) do
        if p.alive and p.node then
            local pos = p.node.position

            -- ----- 冲刺冷却环 -----
            if p.dashCooldown > 0 then
                local headY = pos.y + 0.8  -- 玩家头顶上方
                local sx, sy = Camera.WorldToScreen(pos.x, headY, logW_, logH_)
                local ringRadius = Camera.WorldSizeToScreen(0.35, logH_)
                if ringRadius < 4 then ringRadius = 4 end

                -- 进度 0→1（0=刚冲刺，1=冷却完毕）
                local progress = 1.0 - (p.dashCooldown / Config.DashCooldown)
                progress = math.max(0, math.min(1, progress))

                -- 背景环（深灰）
                nvgBeginPath(vg_)
                nvgArc(vg_, sx, sy, ringRadius, 0, math.pi * 2, NVG_CW)
                nvgStrokeColor(vg_, nvgRGBA(80, 80, 90, 120))
                nvgStrokeWidth(vg_, 2.5)
                nvgStroke(vg_)

                -- 进度弧（白色/浅灰）
                if progress > 0.01 then
                    local startAngle = -math.pi * 0.5
                    local endAngle = startAngle + math.pi * 2 * progress
                    nvgBeginPath(vg_)
                    nvgArc(vg_, sx, sy, ringRadius, startAngle, endAngle, NVG_CW)
                    nvgStrokeColor(vg_, nvgRGBA(220, 225, 230, 200))
                    nvgStrokeWidth(vg_, 2.5)
                    nvgStroke(vg_)
                end
            end

            -- ----- 爆炸前摇警告区域 -----
            if p.exploding then
                local sx, sy = Camera.WorldToScreen(pos.x, pos.y, logW_, logH_)
                local worldRadius = Config.ExplosionRadius * Config.BlockSize
                local screenRadius = Camera.WorldSizeToScreen(worldRadius, logH_)

                -- 闪烁 alpha
                local pulse = math.abs(math.sin(os.clock() * 8)) * 0.4 + 0.2

                -- 半透明红色填充
                nvgBeginPath(vg_)
                nvgCircle(vg_, sx, sy, screenRadius)
                nvgFillColor(vg_, nvgRGBA(255, 40, 30, math.floor(pulse * 80)))
                nvgFill(vg_)

                -- 红色虚线描边
                drawDashedCircle(sx, sy, screenRadius, 255, 60, 40,
                    math.floor(pulse * 255 + 80), 2.0)
            end
        end
    end

    -- ----- 被炸方块虚线轮廓 + 重生进度条 -----
    HUD.DrawDestroyedBlockGhosts()
end

--- 绘制被炸方块的虚线轮廓和重生进度条
function HUD.DrawDestroyedBlockGhosts()
    if mapModule_ == nil then return end

    local blocks = mapModule_.GetDestroyedBlocks()
    if #blocks == 0 then return end

    local bs = Config.BlockSize
    local blockScreenSize = Camera.WorldSizeToScreen(bs, logH_)
    -- 太小了就不画
    if blockScreenSize < 3 then return end

    local dashLen = math.max(2, blockScreenSize * 0.12)
    local gapLen = math.max(2, blockScreenSize * 0.10)

    -- 圆角半径：方块屏幕尺寸的 18%
    local cornerR = blockScreenSize * 0.18

    for _, info in ipairs(blocks) do
        -- 网格坐标转世界坐标（中心）
        local wx = (info.x - 1) * bs + bs * 0.5
        local wy = (info.y - 1) * bs + bs * 0.5
        local sx, sy = Camera.WorldToScreen(wx, wy, logW_, logH_)

        local halfS = blockScreenSize * 0.5

        -- 稍微内缩，让虚线框比原方块小一点
        local inset = blockScreenSize * 0.06
        local drawSize = blockScreenSize - inset * 2
        local drawX = sx - halfS + inset
        local drawY = sy - halfS + inset

        local progress = 1.0 - (info.timer / info.totalTime)  -- 0→1
        local alpha = 80 + math.floor(math.abs(math.sin(os.clock() * 3 + info.x * 0.7)) * 40)

        -- 1) 灰色虚线轮廓（底层，圆角）
        nvgStrokeColor(vg_, nvgRGBA(200, 200, 220, alpha))
        nvgStrokeWidth(vg_, 2.5)
        HUD.DrawDashedRoundedRect(drawX, drawY, drawSize, drawSize, cornerR, dashLen, gapLen)

        -- 2) 高亮进度（沿同一外框走进度，覆盖在灰色虚线之上）
        local segments = HUD.GetRoundedRectSegments(drawX, drawY, drawSize, drawSize, cornerR)
        local totalPerim = 0
        for _, seg in ipairs(segments) do totalPerim = totalPerim + seg.len end
        local filledPerim = totalPerim * progress

        if filledPerim > 0.5 then
            local pAlpha = 160 + math.floor(progress * 95)
            nvgStrokeColor(vg_, nvgRGBA(120, 200, 255, pAlpha))
            nvgStrokeWidth(vg_, 3.5)
            HUD.DrawDashedPath(segments, filledPerim, dashLen, gapLen)
        end
    end
end

-- ============================================================================
-- 圆角矩形虚线绘制
-- ============================================================================

--- 获取圆角矩形的分段路径（直线 + 圆弧），顺时针从左上圆角末端开始
--- 返回 segments 数组，每个元素 = { type="line"|"arc", len, ... }
---@param x number 左上角 X
---@param y number 左上角 Y
---@param w number 宽度
---@param h number 高度
---@param r number 圆角半径
---@return table segments
function HUD.GetRoundedRectSegments(x, y, w, h, r)
    r = math.min(r, w * 0.5, h * 0.5)
    local segs = {}
    -- 顺时针：上边 → 右上弧 → 右边 → 右下弧 → 下边 → 左下弧 → 左边 → 左上弧
    -- 上边（从 x+r 到 x+w-r）
    table.insert(segs, { type = "line", x1 = x + r, y1 = y, x2 = x + w - r, y2 = y, len = w - 2 * r })
    -- 右上弧
    local arcLen = math.pi * 0.5 * r
    table.insert(segs, { type = "arc", cx = x + w - r, cy = y + r, r = r, startAngle = -math.pi * 0.5, endAngle = 0, len = arcLen })
    -- 右边
    table.insert(segs, { type = "line", x1 = x + w, y1 = y + r, x2 = x + w, y2 = y + h - r, len = h - 2 * r })
    -- 右下弧
    table.insert(segs, { type = "arc", cx = x + w - r, cy = y + h - r, r = r, startAngle = 0, endAngle = math.pi * 0.5, len = arcLen })
    -- 下边
    table.insert(segs, { type = "line", x1 = x + w - r, y1 = y + h, x2 = x + r, y2 = y + h, len = w - 2 * r })
    -- 左下弧
    table.insert(segs, { type = "arc", cx = x + r, cy = y + h - r, r = r, startAngle = math.pi * 0.5, endAngle = math.pi, len = arcLen })
    -- 左边
    table.insert(segs, { type = "line", x1 = x, y1 = y + h - r, x2 = x, y2 = y + r, len = h - 2 * r })
    -- 左上弧
    table.insert(segs, { type = "arc", cx = x + r, cy = y + r, r = r, startAngle = math.pi, endAngle = math.pi * 1.5, len = arcLen })
    return segs
end

--- 沿分段路径绘制虚线（支持直线和圆弧段）
---@param segments table 分段路径
---@param maxLen number 最大绘制长度（用于进度条，nil 或极大值则画完整圈）
---@param dashLen number 虚线段长
---@param gapLen number 间隙长
function HUD.DrawDashedPath(segments, maxLen, dashLen, gapLen)
    dashLen = math.max(dashLen, 1.0)
    gapLen = math.max(gapLen, 0.5)
    local cycleLen = dashLen + gapLen
    local globalPos = 0  -- 全局已走过的路径长度（用于虚线相位）
    local remaining = maxLen or 1e9

    for _, seg in ipairs(segments) do
        if remaining <= 0 then break end
        local segDrawLen = math.min(seg.len, remaining)
        remaining = remaining - segDrawLen

        if seg.type == "line" then
            local edgeLen = seg.len
            if edgeLen < 0.1 then goto continueSeg end
            local ux = (seg.x2 - seg.x1) / edgeLen
            local uy = (seg.y2 - seg.y1) / edgeLen
            local pos = 0
            local maxIter = math.ceil(segDrawLen / math.max(cycleLen * 0.5, 0.5)) + 4
            local iter = 0
            while pos < segDrawLen and iter < maxIter do
                iter = iter + 1
                local cyclePos = math.fmod(globalPos + pos, cycleLen)
                if cyclePos < dashLen then
                    local advance = math.max(dashLen - cyclePos, 0.5)
                    local drawEnd = math.min(pos + advance, segDrawLen)
                    nvgBeginPath(vg_)
                    nvgMoveTo(vg_, seg.x1 + ux * pos, seg.y1 + uy * pos)
                    nvgLineTo(vg_, seg.x1 + ux * drawEnd, seg.y1 + uy * drawEnd)
                    nvgStroke(vg_)
                    pos = drawEnd + 0.01
                else
                    local advance = math.max(cycleLen - cyclePos, 0.5)
                    pos = pos + advance
                end
            end
            globalPos = globalPos + segDrawLen

        elseif seg.type == "arc" then
            local totalArc = seg.endAngle - seg.startAngle
            if math.abs(totalArc) < 0.001 or seg.r < 0.1 then goto continueSeg end
            local pos = 0
            local maxIter = math.ceil(segDrawLen / math.max(cycleLen * 0.5, 0.5)) + 4
            local iter = 0
            while pos < segDrawLen and iter < maxIter do
                iter = iter + 1
                local cyclePos = math.fmod(globalPos + pos, cycleLen)
                if cyclePos < dashLen then
                    local advance = math.max(dashLen - cyclePos, 0.5)
                    local drawEnd = math.min(pos + advance, segDrawLen)
                    -- 将路径距离转为角度
                    local a1 = seg.startAngle + totalArc * (pos / seg.len)
                    local a2 = seg.startAngle + totalArc * (drawEnd / seg.len)
                    nvgBeginPath(vg_)
                    nvgArc(vg_, seg.cx, seg.cy, seg.r, a1, a2, NVG_CW)
                    nvgStroke(vg_)
                    pos = drawEnd + 0.01
                else
                    local advance = math.max(cycleLen - cyclePos, 0.5)
                    pos = pos + advance
                end
            end
            globalPos = globalPos + segDrawLen
        end

        ::continueSeg::
    end
end

--- 绘制完整的圆角矩形虚线轮廓
function HUD.DrawDashedRoundedRect(x, y, w, h, r, dashLen, gapLen)
    local segments = HUD.GetRoundedRectSegments(x, y, w, h, r)
    local totalLen = 0
    for _, seg in ipairs(segments) do totalLen = totalLen + seg.len end
    HUD.DrawDashedPath(segments, totalLen, dashLen, gapLen)
end

--- 绘制虚线矩形（保留兼容，无圆角版本）
---@param x number 左上角 X
---@param y number 左上角 Y
---@param w number 宽度
---@param h number 高度
---@param dashLen number 虚线长度
---@param gapLen number 间隙长度
function HUD.DrawDashedRect(x, y, w, h, dashLen, gapLen)
    -- 4 条边
    local edges = {
        { x, y, x + w, y },           -- 上
        { x + w, y, x + w, y + h },   -- 右
        { x + w, y + h, x, y + h },   -- 下
        { x, y + h, x, y },           -- 左
    }
    for _, e in ipairs(edges) do
        HUD.DrawDashedLine(e[1], e[2], e[3], e[4], dashLen, gapLen)
    end
end

--- 绘制虚线直线
function HUD.DrawDashedLine(x1, y1, x2, y2, dashLen, gapLen)
    local dx = x2 - x1
    local dy = y2 - y1
    local totalLen = math.sqrt(dx * dx + dy * dy)
    if totalLen < 0.1 then return end

    local ux = dx / totalLen
    local uy = dy / totalLen
    local pos = 0

    while pos < totalLen do
        -- 画一段 dash
        local segEnd = math.min(pos + dashLen, totalLen)
        nvgBeginPath(vg_)
        nvgMoveTo(vg_, x1 + ux * pos, y1 + uy * pos)
        nvgLineTo(vg_, x1 + ux * segEnd, y1 + uy * segEnd)
        nvgStroke(vg_)
        -- 跳过 gap
        pos = segEnd + gapLen
    end
end

--- 绘制进度矩形（沿矩形周长的虚线进度条）
---@param x number 左上角 X
---@param y number 左上角 Y
---@param w number 宽度
---@param h number 高度
---@param filledPerim number 已填充的周长
---@param totalPerim number 总周长
---@param dashLen number 虚线段长度
---@param gapLen number 间隙长度
function HUD.DrawProgressRect(x, y, w, h, filledPerim, totalPerim, dashLen, gapLen)
    if filledPerim <= 0 then return end
    -- 防止 dashLen/gapLen 过小导致死循环
    dashLen = math.max(dashLen, 1.0)
    gapLen = math.max(gapLen, 0.5)
    local cycleLen = dashLen + gapLen

    -- 从顶部左端开始，顺时针
    local edges = {
        { sx = x, sy = y, ex = x + w, ey = y, len = w },         -- 上
        { sx = x + w, sy = y, ex = x + w, ey = y + h, len = h }, -- 右
        { sx = x + w, sy = y + h, ex = x, ey = y + h, len = w }, -- 下
        { sx = x, sy = y + h, ex = x, ey = y, len = h },         -- 左
    }

    local remaining = filledPerim
    local dashPos = 0  -- 累计虚线相位

    for _, e in ipairs(edges) do
        if remaining <= 0 then break end

        local segLen = math.min(remaining, e.len)
        remaining = remaining - segLen

        local edgeLen = e.len
        if edgeLen < 0.1 then goto continue end

        local ux = (e.ex - e.sx) / edgeLen
        local uy = (e.ey - e.sy) / edgeLen

        -- 沿这条边逐段绘制虚线
        local pos = 0
        local maxIter = math.ceil(segLen / math.max(cycleLen * 0.5, 0.5)) + 4
        local iter = 0
        while pos < segLen and iter < maxIter do
            iter = iter + 1
            local cyclePos = math.fmod(dashPos + pos, cycleLen)
            if cyclePos < dashLen then
                -- 在 dash 阶段：画一段线
                local advanceDash = dashLen - cyclePos
                if advanceDash < 0.5 then advanceDash = 0.5 end  -- 最小步进防死循环
                local drawEnd = math.min(pos + advanceDash, segLen)
                nvgBeginPath(vg_)
                nvgMoveTo(vg_, e.sx + ux * pos, e.sy + uy * pos)
                nvgLineTo(vg_, e.sx + ux * drawEnd, e.sy + uy * drawEnd)
                nvgStroke(vg_)
                pos = drawEnd + 0.01  -- 微小偏移确保推进
            else
                -- 在 gap 阶段：跳过
                local advanceGap = cycleLen - cyclePos
                if advanceGap < 0.5 then advanceGap = 0.5 end  -- 最小步进防死循环
                pos = pos + advanceGap
            end
        end

        dashPos = dashPos + segLen
        ::continue::
    end
end

-- ============================================================================
-- HUD 组件
-- ============================================================================

--- 绘制玩家能量条（左上角）
function HUD.DrawEnergyBars()
    if playerModule_ == nil then return end

    local barW = 120
    local barH = 14
    local gap = 6
    local startX = 16
    local startY = 16

    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 13)

    for i, p in ipairs(playerModule_.list) do
        local x = startX
        local y = startY + (i - 1) * (barH + gap)

        local color = Config.PlayerColors[i]
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        -- 玩家标签
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgText(vg_, x, y + barH * 0.5, "P" .. i)

        local bx = x + 26
        -- 背景
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, y, barW, barH, 3)
        nvgFillColor(vg_, nvgRGBA(40, 40, 50, 180))
        nvgFill(vg_)

        -- 能量填充
        local fillW = barW * math.min(1, p.energy)
        if fillW > 1 then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, bx, y, fillW, barH, 3)
            -- 充满时高亮
            if p.energy >= 1.0 then
                -- 充满闪烁
                local pulse = math.abs(math.sin(os.clock() * 4)) * 80 + 175
                nvgFillColor(vg_, nvgRGBA(255, 200, 50, math.floor(pulse)))
            else
                nvgFillColor(vg_, nvgRGBA(50, 200, 240, 220))
            end
            nvgFill(vg_)
        end

        -- 百分比文字
        local pct = math.floor(p.energy * 100)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 200))
        nvgFontSize(vg_, 11)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgText(vg_, bx + barW * 0.5, y + barH * 0.5, pct .. "%")

        -- 爆炸前摇指示
        if p.exploding then
            nvgFillColor(vg_, nvgRGBA(255, 80, 30, 220))
            nvgFontSize(vg_, 12)
            nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
            nvgText(vg_, bx + barW + 6, y + barH * 0.5, "BOOM!")
        end

        -- 死亡状态
        if not p.alive then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, bx, y, barW, barH, 3)
            nvgFillColor(vg_, nvgRGBA(0, 0, 0, 160))
            nvgFill(vg_)
            nvgFillColor(vg_, nvgRGBA(255, 60, 60, 255))
            nvgFontSize(vg_, 11)
            nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgText(vg_, bx + barW * 0.5, y + barH * 0.5, "DEAD")
        end

        -- 已完成标记
        if p.finished then
            nvgFillColor(vg_, nvgRGBA(50, 255, 80, 255))
            nvgFontSize(vg_, 12)
            nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
            nvgText(vg_, bx + barW + 6, y + barH * 0.5, "#" .. p.finishOrder)
        end
    end
end

--- 绘制分数（右上角）
function HUD.DrawScores()
    if gameManager_ == nil or playerModule_ == nil then return end

    local x = logW_ - 16
    local startY = 16

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)

    -- 标题
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 200))
    nvgText(vg_, x, startY, "SCORE")

    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 16)

    for i = 1, Config.NumPlayers do
        local y = startY + 20 + (i - 1) * 22
        local color = Config.PlayerColors[i]
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        local score = gameManager_.scores[i] or 0
        local text = "P" .. i .. ": " .. score

        -- 阴影
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
        nvgText(vg_, x + 1, y + 1, text)

        -- 文字
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgText(vg_, x, y, text)

        -- 胜利目标线
        if score >= Config.WinScore then
            nvgFillColor(vg_, nvgRGBA(255, 215, 0, 255))
            nvgText(vg_, x - 60, y, "WIN!")
        end
    end
end

--- 绘制回合计时器（顶部中央）
function HUD.DrawRoundTimer()
    if gameManager_ == nil then return end

    local remaining = gameManager_.GetRoundTime()
    local minutes = math.floor(remaining / 60)
    local seconds = math.floor(remaining % 60)

    local timeStr = string.format("%d:%02d", minutes, seconds)

    -- 背景
    local tw = 80
    local th = 32
    local tx = (logW_ - tw) * 0.5
    local ty = 10

    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, tx, ty, tw, th, 6)
    -- 时间紧迫时变红
    if remaining <= 10 then
        local pulse = math.abs(math.sin(os.clock() * 3)) * 100 + 50
        nvgFillColor(vg_, nvgRGBA(180, 30, 30, math.floor(pulse) + 100))
    else
        nvgFillColor(vg_, nvgRGBA(30, 30, 40, 200))
    end
    nvgFill(vg_)

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 20)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    if remaining <= 10 then
        nvgFillColor(vg_, nvgRGBA(255, 80, 60, 255))
    else
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    end
    nvgText(vg_, tx + tw * 0.5, ty + th * 0.5, timeStr)
end

--- 绘制回合信息（顶部中央偏下）
function HUD.DrawRoundInfo()
    if gameManager_ == nil then return end

    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(200, 200, 210, 180))

    local roundText = "ROUND " .. gameManager_.round
    nvgText(vg_, logW_ * 0.5, 46, roundText)
end

-- ============================================================================
-- 状态覆盖层
-- ============================================================================

--- 倒计时覆盖层
function HUD.DrawCountdown()
    if gameManager_ == nil then return end

    -- 半透明背景
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 100))
    nvgFill(vg_)

    local num = gameManager_.GetCountdownNumber()

    -- 大倒计时数字
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 120)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 阴影
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, logW_ * 0.5 + 3, logH_ * 0.5 + 3, tostring(num))

    -- 数字（渐变色）
    if num <= 0 then
        nvgFillColor(vg_, nvgRGBA(50, 255, 100, 255))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, "GO!")
    else
        nvgFillColor(vg_, nvgRGBA(255, 255, 80, 255))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, tostring(num))
    end

    -- 提示
    nvgFontSize(vg_, 18)
    nvgFillColor(vg_, nvgRGBA(220, 220, 230, 200))
    nvgText(vg_, logW_ * 0.5, logH_ * 0.5 + 80, "Get Ready!")
end

--- 回合结束覆盖层
function HUD.DrawRoundEnd()
    if gameManager_ == nil then return end

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 140))
    nvgFill(vg_)

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 48)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, logW_ * 0.5 + 2, logH_ * 0.5 - 18, "ROUND OVER")
    nvgFillColor(vg_, nvgRGBA(255, 200, 50, 255))
    nvgText(vg_, logW_ * 0.5, logH_ * 0.5 - 20, "ROUND OVER")

    -- 显示本回合名次
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 20)
    local startY = logH_ * 0.5 + 20

    for place, playerIdx in ipairs(gameManager_.roundResults) do
        local y = startY + (place - 1) * 28
        local color = Config.PlayerColors[playerIdx]
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        local pts = Config.PlaceScores[place] or 0
        local text = "#" .. place .. "  P" .. playerIdx .. "  +" .. pts

        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgText(vg_, logW_ * 0.5, y, text)
    end
end

--- 分数总览覆盖层
function HUD.DrawScoreScreen()
    if gameManager_ == nil then return end

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(15, 15, 25, 210))
    nvgFill(vg_)

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 36)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    nvgText(vg_, logW_ * 0.5, logH_ * 0.3, "STANDINGS")

    -- 积分条
    local barMaxW = logW_ * 0.5
    local barH = 28
    local gap = 10
    local startY = logH_ * 0.4

    -- 按分数排序的玩家索引
    local sorted = {}
    for i = 1, Config.NumPlayers do
        sorted[i] = i
    end
    table.sort(sorted, function(a, b)
        return gameManager_.scores[a] > gameManager_.scores[b]
    end)

    local maxScore = math.max(1, Config.WinScore)

    for rank, idx in ipairs(sorted) do
        local y = startY + (rank - 1) * (barH + gap)
        local score = gameManager_.scores[idx]
        local color = Config.PlayerColors[idx]
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        -- 名次标签
        local labelX = logW_ * 0.5 - barMaxW * 0.5 - 40
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 18)
        nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgText(vg_, labelX, y + barH * 0.5, "P" .. idx)

        -- 背景条
        local bx = logW_ * 0.5 - barMaxW * 0.5
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, y, barMaxW, barH, 4)
        nvgFillColor(vg_, nvgRGBA(40, 40, 50, 180))
        nvgFill(vg_)

        -- 填充条
        local fillW = math.max(2, barMaxW * score / maxScore)
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, y, fillW, barH, 4)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 200))
        nvgFill(vg_)

        -- 分数文字
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
        nvgFontSize(vg_, 15)
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgText(vg_, bx + 8, y + barH * 0.5, tostring(score) .. " / " .. Config.WinScore)
    end

    -- 提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(180, 180, 190, 180))
    nvgText(vg_, logW_ * 0.5, logH_ - 30, "Next round starting soon...")
end

--- 比赛结束覆盖层
function HUD.DrawMatchEnd()
    if gameManager_ == nil then return end

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(10, 10, 20, 220))
    nvgFill(vg_)

    local winner = gameManager_.GetWinner()

    -- 冠军文字
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 52)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    if winner then
        local color = Config.PlayerColors[winner]
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        -- 闪光背景
        local pulse = math.abs(math.sin(os.clock() * 2)) * 30 + 20
        nvgBeginPath(vg_)
        nvgCircle(vg_, logW_ * 0.5, logH_ * 0.4, 100 + pulse)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 40))
        nvgFill(vg_)

        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
        nvgText(vg_, logW_ * 0.5 + 3, logH_ * 0.35 + 3, "WINNER!")
        nvgFillColor(vg_, nvgRGBA(255, 215, 0, 255))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.35, "WINNER!")

        nvgFontSize(vg_, 36)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, "Player " .. winner)

        nvgFontSize(vg_, 20)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 200))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.58, "Score: " .. gameManager_.scores[winner])
    end

    -- 提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(180, 180, 190, 180))
    nvgText(vg_, logW_ * 0.5, logH_ - 30, "New match starting soon...")
end

--- 主菜单界面
function HUD.DrawMenu()
    -- 全屏背景渐变（深蓝到深紫）
    local bgPaint = nvgLinearGradient(vg_, 0, 0, logW_, logH_,
        nvgRGBA(15, 10, 35, 255), nvgRGBA(35, 15, 25, 255))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillPaint(vg_, bgPaint)
    nvgFill(vg_)

    -- 装饰粒子（缓慢浮动的光点）
    local t = os.clock()
    for i = 1, 20 do
        local px = (math.sin(t * 0.3 + i * 1.7) * 0.5 + 0.5) * logW_
        local py = (math.cos(t * 0.2 + i * 2.3) * 0.5 + 0.5) * logH_
        local alpha = math.abs(math.sin(t * 0.5 + i)) * 60 + 20
        local radius = 2 + math.sin(t + i) * 1.5
        nvgBeginPath(vg_)
        nvgCircle(vg_, px, py, radius)
        nvgFillColor(vg_, nvgRGBA(255, 200, 100, math.floor(alpha)))
        nvgFill(vg_)
    end

    local cx = logW_ * 0.5
    local cy = logH_ * 0.5

    -- ======== 标题 ========
    -- 标题光晕
    local glowAlpha = math.abs(math.sin(t * 1.5)) * 30 + 15
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 72)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 80, 40, math.floor(glowAlpha)))
    nvgText(vg_, cx, cy - 90, Config.Title)

    -- 标题阴影
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, cx + 3, cy - 87, Config.Title)

    -- 标题文字（火红色渐变感）
    nvgFillColor(vg_, nvgRGBA(255, 90, 40, 255))
    nvgText(vg_, cx, cy - 90, Config.Title)

    -- ======== 副标题 ========
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 18)
    nvgFillColor(vg_, nvgRGBA(220, 200, 180, 200))
    nvgText(vg_, cx, cy - 45, "2.5D 多人平台竞速派对")

    -- ======== 开始提示（闪烁） ========
    local blink = math.abs(math.sin(t * 2.5))
    nvgFontSize(vg_, 26)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, math.floor(blink * 200 + 55)))
    nvgText(vg_, cx, cy + 20, "按 空格 / Enter 开始游戏")

    -- ======== 操作说明面板 ========
    local panelW = 320
    local panelH = 160
    local panelX = cx - panelW * 0.5
    local panelY = cy + 55

    -- 面板背景
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, panelX, panelY, panelW, panelH, 10)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 120))
    nvgFill(vg_)

    -- 面板边框
    nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 40))
    nvgStrokeWidth(vg_, 1)
    nvgStroke(vg_)

    -- 操作说明标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 16)
    nvgFillColor(vg_, nvgRGBA(255, 200, 80, 240))
    nvgText(vg_, cx, panelY + 22, "操作说明")

    -- 操作说明内容
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgFillColor(vg_, nvgRGBA(210, 210, 220, 220))
    local instructions = {
        "A / D  或  ← / →    移动",
        "空格                  跳跃",
        "Shift                 冲刺（无视重力！）",
        "E                     爆炸（消耗能量）",
        "P                     调参面板",
    }
    for i, line in ipairs(instructions) do
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgText(vg_, cx, panelY + 44 + (i - 1) * 22, line)
    end

    -- ======== 底部玩家颜色指示 ========
    local dotY = panelY + panelH + 25
    local dotSpacing = 50
    local dotStartX = cx - dotSpacing * 1.5
    nvgFontSize(vg_, 12)
    for i = 1, 4 do
        local dx = dotStartX + (i - 1) * dotSpacing
        local color = Config.PlayerColors[i]
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        -- 玩家色块
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, dx - 8, dotY - 8, 16, 16, 4)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgFill(vg_)

        -- 玩家标签
        nvgFillColor(vg_, nvgRGBA(200, 200, 210, 200))
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        local label = i == 1 and "P1 你" or ("P" .. i .. " AI")
        nvgText(vg_, dx, dotY + 12, label)
    end
end

--- 绘制控制提示（底部）
function HUD.DrawControls()
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(180, 180, 190, 140))
    nvgText(vg_, logW_ * 0.5, logH_ - 8, "A/D: Move  SPACE: Jump  SHIFT: Dash  E: Explode  TAB: Debug")
end

return HUD

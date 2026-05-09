-- ============================================================================
-- HUD.lua - NanoVG 游戏 HUD（大地图攀登模式）
-- 显示：能量条、分数排行、倒计时、游戏计时器、结算画面、云端排行榜
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

-- 菜单按钮点击结果
local menuButtonClicked_ = nil  -- "startGame" | nil

-- 结算画面按钮点击结果
local resultButtonClicked_ = nil  -- "restart" | "menu" | nil

-- 标题图片句柄
local titleImage_ = -1
local titleImageW_ = 0
local titleImageH_ = 0

-- 帧缓存：鼠标点击状态（在 Update 阶段缓存，供 NanoVG 渲染阶段的按钮使用）
local cachedMousePress_ = false
local cachedMouseLogX_ = 0
local cachedMouseLogY_ = 0

--- 在 Update 阶段缓存鼠标输入状态（GetMouseButtonPress 在渲染阶段不可靠）
--- 必须由 Standalone.HandleUpdate 在每帧开头调用
function HUD.CacheInput()
    cachedMousePress_ = input:GetMouseButtonPress(MOUSEB_LEFT)
    if cachedMousePress_ then
        cachedMouseLogX_ = input.mousePosition.x / dpr_
        cachedMouseLogY_ = input.mousePosition.y / dpr_
    end
    -- G 键切换 AI 寻路可视化
    if input:GetKeyPress(KEY_G) then
        HUD.aiDebugVisible = not HUD.aiDebugVisible
        print("[HUD] AI debug visualization toggled: " .. tostring(HUD.aiDebugVisible))
    end
end

-- AI 寻路调试可视化开关
HUD.aiDebugVisible = true

-- 动画
local countdownScale_ = 1.0
local flashAlpha_ = 0

-- 击杀动效系统
local killFloatTexts_ = {}
local KILL_FLOAT_DURATION = 2.0
local lastRenderTime_ = 0
-- 每个玩家的弹跳动画状态（支持 6 名玩家）
local killBounceTimers_ = {}
for i = 1, Config.NumPlayers do killBounceTimers_[i] = 0 end
local KILL_BOUNCE_DURATION = 0.8

-- 云端排行榜缓存
local cloudLeaderboard_ = nil        -- 排行榜数据
local cloudLeaderboardLoading_ = false
local cloudScoreSubmitted_ = false

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

    -- 加载标题图片
    titleImage_ = nvgCreateImage(vg_, "image/image_20260422143231.png", 0)
    if titleImage_ > 0 then
        titleImageW_, titleImageH_ = nvgImageSize(vg_, titleImage_)
        if titleImageW_ <= 16 or titleImageH_ <= 16 then
            titleImageW_ = 1024
            titleImageH_ = 434
        end
        print("[HUD] Title image loaded: " .. titleImageW_ .. "x" .. titleImageH_)
    else
        print("[HUD] Warning: title image not found, fallback to text")
    end

    -- 订阅渲染事件
    SubscribeToEvent(vg_, "NanoVGRender", "HandleNanoVGRender")
    SubscribeToEvent("ScreenMode", "HandleScreenMode_HUD")

    print("[HUD] Initialized")
end

--- 获取 NanoVG 上下文
---@return number
function HUD.GetNVGContext()
    return vg_
end

--- 获取逻辑分辨率
---@return number, number
function HUD.GetLogicalSize()
    return logW_, logH_
end

--- 获取菜单中哪个按钮被点击（获取后自动清除）
---@return string|nil
function HUD.GetMenuButtonClicked()
    local v = menuButtonClicked_
    menuButtonClicked_ = nil
    return v
end

--- 获取结算画面中哪个按钮被点击（获取后自动清除）
---@return string|nil -- "restart" | "menu" | nil
function HUD.GetResultButtonClicked()
    local v = resultButtonClicked_
    resultButtonClicked_ = nil
    return v
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

    -- 计算帧间隔（用于浮动文字动画）
    local now = os.clock()
    local renderDt = now - lastRenderTime_
    if renderDt > 0.1 then renderDt = 0.016 end
    lastRenderTime_ = now

    -- 更新浮动文字计时
    HUD.UpdateKillFloats(renderDt)

    nvgBeginFrame(vg_, logW_, logH_, dpr_)

    local state = gameManager_ and gameManager_.state or "playing"

    -- 主菜单
    if state == "menu" then
        HUD.DrawMenu()
        nvgEndFrame(vg_)
        return
    end

    -- 温暖渐变背景（所有游戏状态共用）
    HUD.DrawBackground()

    -- 世界空间指示器（在 HUD 元素下面绘制）
    if state == "playing" then
        HUD.DrawWorldIndicators()
        HUD.DrawAIDebug()
    end

    -- HUD 元素
    HUD.DrawEnergyBars()

    if state == "playing" or state == "countdown" then
        HUD.DrawScoreRankings()
        HUD.DrawKillScorePanel()
    end

    if state == "playing" then
        HUD.DrawGameTimer()
        HUD.DrawHeightIndicator()
    end

    -- 消费击杀事件 + 绘制浮动文字
    HUD.ConsumeKillEvents()
    HUD.DrawKillFloatTexts()

    -- 状态覆盖层
    if state == "countdown" then
        HUD.DrawCountdown()
    elseif state == "result" then
        HUD.DrawResultScreen()
    end

    nvgEndFrame(vg_)
end

function HandleScreenMode_HUD(eventType, eventData)
    HUD.RefreshResolution()
end

-- ============================================================================
-- 渐变背景
-- ============================================================================

--- 绘制半透明山丘剪影（叠加在 3D 渐变背景之上）
function HUD.DrawBackground()
    local t = (os.clock() or 0) * 0.02
    -- 远山（浅色）
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, 0, logH_)
    local hillY1 = logH_ * 0.72
    for x = 0, logW_, 4 do
        local y = hillY1 + math.sin((x + t * 30) * 0.008) * logH_ * 0.06
                        + math.sin((x + t * 50) * 0.015) * logH_ * 0.03
        nvgLineTo(vg_, x, y)
    end
    nvgLineTo(vg_, logW_, logH_)
    nvgClosePath(vg_)
    nvgFillColor(vg_, nvgRGBA(180, 140, 110, 35))
    nvgFill(vg_)

    -- 近山（深色）
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, 0, logH_)
    local hillY2 = logH_ * 0.82
    for x = 0, logW_, 4 do
        local y = hillY2 + math.sin((x + t * 60) * 0.012) * logH_ * 0.04
                        + math.sin((x + t * 80) * 0.025) * logH_ * 0.02
        nvgLineTo(vg_, x, y)
    end
    nvgLineTo(vg_, logW_, logH_)
    nvgClosePath(vg_)
    nvgFillColor(vg_, nvgRGBA(140, 100, 80, 45))
    nvgFill(vg_)
end

-- ============================================================================
-- 世界空间指示器
-- ============================================================================

--- 绘制虚线圆（用于爆炸警告区域）
local function drawDashedCircle(cx, cy, radius, r, g, b, a, strokeW)
    local segments = 24
    local dashLen = math.pi * 2 / segments
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
                local headY = pos.y + 0.8
                local sx, sy = Camera.WorldToScreen(pos.x, headY, logW_, logH_)
                local ringRadius = Camera.WorldSizeToScreen(0.35, logH_)
                if ringRadius < 4 then ringRadius = 4 end

                local progress = 1.0 - (p.dashCooldown / Config.DashCooldown)
                progress = math.max(0, math.min(1, progress))

                nvgBeginPath(vg_)
                nvgArc(vg_, sx, sy, ringRadius, 0, math.pi * 2, NVG_CW)
                nvgStrokeColor(vg_, nvgRGBA(80, 80, 90, 120))
                nvgStrokeWidth(vg_, 2.5)
                nvgStroke(vg_)

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

            -- ----- 蓄力警告区域 -----
            if p.charging then
                local sx, sy = Camera.WorldToScreen(pos.x, pos.y, logW_, logH_)
                local maxWorldRadius = Config.ExplosionRadius * Config.BlockSize
                local currentWorldRadius = maxWorldRadius * p.chargeProgress
                local screenRadius = Camera.WorldSizeToScreen(currentWorldRadius, logH_)

                local pc = Config.PlayerColors[p.index]
                local pr = math.floor(pc.r * 255)
                local pg = math.floor(pc.g * 255)
                local pb = math.floor(pc.b * 255)

                local freq = 4 + p.chargeProgress * 12
                local pulse = math.abs(math.sin(os.clock() * freq)) * 0.4 + 0.2

                local fillAlpha = math.floor(52 + pulse * 127)
                nvgBeginPath(vg_)
                nvgCircle(vg_, sx, sy, screenRadius)
                nvgFillColor(vg_, nvgRGBA(pr, pg, pb, fillAlpha))
                nvgFill(vg_)

                local strokeAlpha = math.floor(pulse * 200 + 55 + p.chargeProgress * 80)
                drawDashedCircle(sx, sy, screenRadius, pr, pg, pb,
                    math.min(255, strokeAlpha), 2.0)
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
    if blockScreenSize < 3 then return end

    local dashLen = math.max(2, blockScreenSize * 0.12)
    local gapLen = math.max(2, blockScreenSize * 0.10)
    local cornerR = blockScreenSize * 0.18

    for _, info in ipairs(blocks) do
        local wx = (info.x - 1) * bs + bs * 0.5
        local wy = (info.y - 1) * bs + bs * 0.5
        local sx, sy = Camera.WorldToScreen(wx, wy, logW_, logH_)

        local halfS = blockScreenSize * 0.5
        local inset = blockScreenSize * 0.06
        local drawSize = blockScreenSize - inset * 2
        local drawX = sx - halfS + inset
        local drawY = sy - halfS + inset

        local progress = 1.0 - (info.timer / info.totalTime)
        local alpha = 80 + math.floor(math.abs(math.sin(os.clock() * 3 + info.x * 0.7)) * 40)

        nvgStrokeColor(vg_, nvgRGBA(200, 200, 220, alpha))
        nvgStrokeWidth(vg_, 2.5)
        HUD.DrawDashedRoundedRect(drawX, drawY, drawSize, drawSize, cornerR, dashLen, gapLen)

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
-- 圆角矩形虚线绘制工具
-- ============================================================================

function HUD.GetRoundedRectSegments(x, y, w, h, r)
    r = math.min(r, w * 0.5, h * 0.5)
    local segs = {}
    local arcLen = math.pi * 0.5 * r
    table.insert(segs, { type = "line", x1 = x + r, y1 = y, x2 = x + w - r, y2 = y, len = w - 2 * r })
    table.insert(segs, { type = "arc", cx = x + w - r, cy = y + r, r = r, startAngle = -math.pi * 0.5, endAngle = 0, len = arcLen })
    table.insert(segs, { type = "line", x1 = x + w, y1 = y + r, x2 = x + w, y2 = y + h - r, len = h - 2 * r })
    table.insert(segs, { type = "arc", cx = x + w - r, cy = y + h - r, r = r, startAngle = 0, endAngle = math.pi * 0.5, len = arcLen })
    table.insert(segs, { type = "line", x1 = x + w - r, y1 = y + h, x2 = x + r, y2 = y + h, len = w - 2 * r })
    table.insert(segs, { type = "arc", cx = x + r, cy = y + h - r, r = r, startAngle = math.pi * 0.5, endAngle = math.pi, len = arcLen })
    table.insert(segs, { type = "line", x1 = x, y1 = y + h - r, x2 = x, y2 = y + r, len = h - 2 * r })
    table.insert(segs, { type = "arc", cx = x + r, cy = y + r, r = r, startAngle = math.pi, endAngle = math.pi * 1.5, len = arcLen })
    return segs
end

function HUD.DrawDashedPath(segments, maxLen, dashLen, gapLen)
    dashLen = math.max(dashLen, 1.0)
    gapLen = math.max(gapLen, 0.5)
    local cycleLen = dashLen + gapLen
    local globalPos = 0
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

function HUD.DrawDashedRoundedRect(x, y, w, h, r, dashLen, gapLen)
    local segments = HUD.GetRoundedRectSegments(x, y, w, h, r)
    local totalLen = 0
    for _, seg in ipairs(segments) do totalLen = totalLen + seg.len end
    HUD.DrawDashedPath(segments, totalLen, dashLen, gapLen)
end

-- ============================================================================
-- AI 寻路调试可视化
-- ============================================================================

local AI_DEBUG_COLORS = {
    { 0.30, 0.70, 1.00 },  -- P1 蓝
    { 1.00, 0.40, 0.40 },  -- P2 红
    { 0.40, 0.95, 0.50 },  -- P3 绿
    { 1.00, 0.85, 0.30 },  -- P4 黄
    { 0.85, 0.50, 0.90 },  -- P5 紫
    { 1.00, 0.65, 0.30 },  -- P6 橙
}

local _aiDbgFrameCount_ = 0
function HUD.DrawAIDebug()
    if not HUD.aiDebugVisible then return end

    local AIController = package.loaded["AIController"]
    _aiDbgFrameCount_ = _aiDbgFrameCount_ + 1
    if not AIController or not AIController.GetDebugInfo then return end
    if not playerModule_ then return end

    local debugList = AIController.GetDebugInfo()

    for _, info in ipairs(debugList) do
        local idx = info.playerIdx or 1
        local col = AI_DEBUG_COLORS[idx] or { 1, 1, 1 }
        local r, g, b = col[1] * 255, col[2] * 255, col[3] * 255

        local p = playerModule_.list[idx]
        if p and p.node and info.path and #info.path > 0 then
            local pos = p.node.position
            local startSX, startSY = Camera.WorldToScreen(pos.x, pos.y, logW_, logH_)

            local points = { { x = startSX, y = startSY } }
            local startIdx = math.max(1, info.pathIdx or 1)
            for i = startIdx, #info.path do
                local pt = info.path[i]
                local sx, sy = Camera.WorldToScreen(pt.x, pt.y, logW_, logH_)
                table.insert(points, { x = sx, y = sy })
            end

            if #points >= 2 then
                -- 黑色描边
                nvgBeginPath(vg_)
                nvgMoveTo(vg_, points[1].x, points[1].y)
                for i = 2, #points do
                    nvgLineTo(vg_, points[i].x, points[i].y)
                end
                nvgStrokeColor(vg_, nvgRGBA(0, 0, 0, 220))
                nvgStrokeWidth(vg_, 8)
                nvgStroke(vg_)

                -- 玩家颜色主线
                nvgBeginPath(vg_)
                nvgMoveTo(vg_, points[1].x, points[1].y)
                for i = 2, #points do
                    nvgLineTo(vg_, points[i].x, points[i].y)
                end
                nvgStrokeColor(vg_, nvgRGBA(r, g, b, 255))
                nvgStrokeWidth(vg_, 5)
                nvgStroke(vg_)

                -- 节点圆点 + 序号
                for i = 2, #points do
                    local pt = points[i]
                    nvgBeginPath(vg_)
                    nvgCircle(vg_, pt.x, pt.y, 12)
                    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 220))
                    nvgFill(vg_)
                    nvgBeginPath(vg_)
                    nvgCircle(vg_, pt.x, pt.y, 9)
                    nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
                    nvgFill(vg_)
                    nvgFontFace(vg_, "sans")
                    nvgFontSize(vg_, 13)
                    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
                    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                    nvgText(vg_, pt.x, pt.y, tostring(i - 1))
                end

                -- 起点圆环
                nvgBeginPath(vg_)
                nvgCircle(vg_, points[1].x, points[1].y, 14)
                nvgStrokeColor(vg_, nvgRGBA(r, g, b, 255))
                nvgStrokeWidth(vg_, 3)
                nvgStroke(vg_)
            end
        end
    end

    -- 顶部提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 16)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 220))
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgText(vg_, 13, 13, "[G] AI 寻路可视化 ON")
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    nvgText(vg_, 12, 12, "[G] AI 寻路可视化 ON")
end

-- ============================================================================
-- HUD 组件
-- ============================================================================

--- 绘制玩家能量条（角色头顶，世界空间投影）
function HUD.DrawEnergyBars()
    if playerModule_ == nil then return end

    for _, p in ipairs(playerModule_.list) do
        if not p.alive or not p.node then goto continueBar end

        local pos = p.node.position
        local color = Config.PlayerColors[p.index]
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        local headY = pos.y + 0.75
        local sx, sy = Camera.WorldToScreen(pos.x, headY, logW_, logH_)

        local barWorldW = 1.1
        local barW = Camera.WorldSizeToScreen(barWorldW, logH_)
        if barW < 24 then barW = 24 end
        local barH = math.max(5, math.min(10, barW * 0.14))
        local cornerR = barH * 0.4
        local bx = sx - barW * 0.5
        local by = sy - barH - 2

        -- 背景
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, barW, barH, cornerR)
        nvgFillColor(vg_, nvgRGBA(30, 20, 15, 180))
        nvgFill(vg_)

        -- 能量填充
        local fillW = barW * math.min(1, p.energy)
        if fillW > 0.5 then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, bx, by, fillW, barH, cornerR)
            if p.energy >= 1.0 then
                local pulse = math.abs(math.sin(os.clock() * 4)) * 55 + 200
                nvgFillColor(vg_, nvgRGBA(255, 40, 30, math.floor(pulse)))
            else
                nvgFillColor(vg_, nvgRGBA(180, 220, 255, 210))
            end
            nvgFill(vg_)
        end

        -- 边框
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, barW, barH, cornerR)
        nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 60))
        nvgStrokeWidth(vg_, 1.0)
        nvgStroke(vg_)

        ::continueBar::
    end
end

--- 绘制实时分数排行（右上角）
function HUD.DrawScoreRankings()
    if gameManager_ == nil or playerModule_ == nil then return end

    local rankings = gameManager_.GetRankings()
    local x = logW_ - 16
    local startY = 16

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 200))
    nvgText(vg_, x, startY, "SCORE")

    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 15)

    for rank, entry in ipairs(rankings) do
        local y = startY + 20 + (rank - 1) * 22
        local color = Config.PlayerColors[entry.index]
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        local label = entry.index == 1 and "你" or ("P" .. entry.index)
        local text = "#" .. rank .. " " .. label .. ": " .. entry.score

        -- 阴影
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
        nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
        nvgText(vg_, x + 1, y + 1, text)

        -- 文字
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgText(vg_, x, y, text)
    end
end

--- 绘制游戏计时器（顶部中央）
function HUD.DrawGameTimer()
    if gameManager_ == nil then return end

    local remaining = gameManager_.GetGameTime()
    local minutes = math.floor(remaining / 60)
    local seconds = math.floor(remaining % 60)
    local timeStr = string.format("%d:%02d", minutes, seconds)

    local tw = 80
    local th = 32
    local tx = (logW_ - tw) * 0.5
    local ty = 10

    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, tx, ty, tw, th, 6)
    if remaining <= 10 then
        local pulse = math.abs(math.sin(os.clock() * 3)) * 100 + 50
        nvgFillColor(vg_, nvgRGBA(180, 30, 30, math.floor(pulse) + 100))
    else
        nvgFillColor(vg_, nvgRGBA(50, 38, 30, 210))
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

--- 绘制高度指示器（左下角，显示 P1 当前高度和最高记录）
function HUD.DrawHeightIndicator()
    if playerModule_ == nil then return end

    local p1 = playerModule_.list[1]
    if not p1 or not p1.node then return end

    local currentY = p1.node.position.y
    local maxH = p1.maxHeight or 0
    local heightBlocks = math.floor(currentY / Config.BlockSize)
    local maxBlocks = math.floor(maxH / Config.BlockSize)

    local x = 12
    local y = logH_ - 50

    -- 背景
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x - 4, y - 4, 110, 42, 6)
    nvgFillColor(vg_, nvgRGBA(20, 12, 8, 150))
    nvgFill(vg_)

    -- 当前高度
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 220))
    nvgText(vg_, x, y, "高度 " .. heightBlocks)

    -- 最高记录
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgFillColor(vg_, nvgRGBA(255, 200, 100, 180))
    nvgText(vg_, x, y + 20, "最高 " .. maxBlocks)
end

-- ============================================================================
-- 击杀分值面板 + 浮动文字动效
-- ============================================================================

--- 消费 GameManager 击杀事件，生成动效
function HUD.ConsumeKillEvents()
    if gameManager_ == nil then return end

    for _, evt in ipairs(gameManager_.killEvents) do
        local killerIdx = evt.killerIndex
        local multiKill = evt.multiKillCount
        local streak = evt.killStreak

        -- 触发该玩家的弹跳
        if killerIdx >= 1 and killerIdx <= Config.NumPlayers then
            killBounceTimers_[killerIdx] = KILL_BOUNCE_DURATION
        end

        -- 玩家颜色
        local pc = Config.PlayerColors[killerIdx]
        local cr = math.floor(pc.r * 255)
        local cg = math.floor(pc.g * 255)
        local cb = math.floor(pc.b * 255)

        -- 双杀及以上
        if multiKill >= 2 then
            local mainText = Config.MultiKillTexts[multiKill] or Config.MultiKillTexts[5]
            if multiKill > 5 then mainText = Config.MultiKillTexts[5] end
            table.insert(killFloatTexts_, {
                text = mainText,
                r = cr, g = cg, b = cb,
                timer = KILL_FLOAT_DURATION,
                duration = KILL_FLOAT_DURATION,
                kind = "multi",
            })
        end

        -- 连杀 ≥3
        if streak >= 3 then
            local streakText = nil
            for s = streak, 3, -1 do
                if Config.KillStreakTexts[s] then
                    streakText = Config.KillStreakTexts[s]
                    break
                end
            end
            if streakText then
                table.insert(killFloatTexts_, {
                    text = streakText,
                    r = 255, g = 210, b = 50,
                    timer = KILL_FLOAT_DURATION,
                    duration = KILL_FLOAT_DURATION,
                    kind = "streak",
                })
            end
        end
    end

    gameManager_.killEvents = {}
end

--- 更新动效计时器
function HUD.UpdateKillFloats(dt)
    local i = 1
    while i <= #killFloatTexts_ do
        local ft = killFloatTexts_[i]
        ft.timer = ft.timer - dt
        if ft.timer <= 0 then
            table.remove(killFloatTexts_, i)
        else
            i = i + 1
        end
    end

    for pi = 1, Config.NumPlayers do
        if killBounceTimers_[pi] > 0 then
            killBounceTimers_[pi] = killBounceTimers_[pi] - dt
            if killBounceTimers_[pi] < 0 then killBounceTimers_[pi] = 0 end
        end
    end
end

--- 绘制左上角击杀面板
function HUD.DrawKillScorePanel()
    if gameManager_ == nil or playerModule_ == nil then return end

    local panelX = 12
    local panelY = 12

    -- AI debug 开启时面板下移
    if HUD.aiDebugVisible then
        panelY = 32
    end

    local lineH = 22
    local headerH = 20
    local panelW = 120

    local totalH = headerH + Config.NumPlayers * lineH + 4
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, panelX - 4, panelY - 4, panelW + 8, totalH + 8, 6)
    nvgFillColor(vg_, nvgRGBA(20, 12, 8, 150))
    nvgFill(vg_)

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 160))
    nvgText(vg_, panelX, panelY, "KILLS")

    for i = 1, Config.NumPlayers do
        local y = panelY + headerH + (i - 1) * lineH
        local pc = Config.PlayerColors[i]
        local r = math.floor(pc.r * 255)
        local g = math.floor(pc.g * 255)
        local b = math.floor(pc.b * 255)

        -- 获取玩家击杀得分
        local p = playerModule_.list[i]
        local killPts = p and p.killScore or 0

        -- 玩家色块
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, panelX, y + 3, 10, 10, 2)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgFill(vg_)

        -- 弹跳动画
        local bounceT = killBounceTimers_[i]
        local isAnimating = bounceT > 0

        local numScale = 1.0
        if isAnimating then
            local bp = 1.0 - (bounceT / KILL_BOUNCE_DURATION)
            local elastic = 1.0 + math.sin(bp * math.pi * 3) * math.exp(-bp * 4) * 0.6
            numScale = elastic
        end

        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

        -- 玩家标签
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        local label = i == 1 and "你" or ("P" .. i)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 220))
        nvgText(vg_, panelX + 14, y + 9, label)

        -- 击杀得分（带弹跳）
        local numX = panelX + 34
        local numY = y + 9
        local numSize = math.floor(14 * numScale)
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, numSize)
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

        local shakeY = 0
        if isAnimating then
            local bp = 1.0 - (bounceT / KILL_BOUNCE_DURATION)
            shakeY = math.sin(bp * math.pi * 5) * math.exp(-bp * 3) * 4
        end

        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 160))
        nvgText(vg_, numX + 1, numY + 1 - shakeY, tostring(killPts))
        if isAnimating then
            nvgFillColor(vg_, nvgRGBA(math.min(255, r + 60), math.min(255, g + 60), math.min(255, b + 60), 255))
        else
            nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        end
        nvgText(vg_, numX, numY - shakeY, tostring(killPts))

        -- "+1" 浮出动画
        if isAnimating then
            local bp = 1.0 - (bounceT / KILL_BOUNCE_DURATION)
            local plusAlpha
            if bp < 0.1 then plusAlpha = bp / 0.1
            elseif bp > 0.5 then plusAlpha = (1.0 - bp) / 0.5
            else plusAlpha = 1.0 end
            plusAlpha = math.max(0, math.min(1, plusAlpha))

            local plusOffX = bp * 25
            local plusOffY = -bp * 18
            local plusScale = 1.0
            if bp < 0.2 then plusScale = 1.0 + (1.0 - bp / 0.2) * 0.8 end

            local plusSize = math.floor(16 * plusScale)
            nvgFontFace(vg_, "bold")
            nvgFontSize(vg_, plusSize)
            nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

            nvgFillColor(vg_, nvgRGBA(255, 255, 100, math.floor(plusAlpha * 80)))
            nvgText(vg_, numX + 22 + plusOffX + 1, numY + plusOffY + 1, "+")
            nvgFillColor(vg_, nvgRGBA(255, 255, 80, math.floor(plusAlpha * 255)))
            nvgText(vg_, numX + 22 + plusOffX, numY + plusOffY, "+")
        end
    end
end

--- 绘制屏幕中央击杀浮动大字
function HUD.DrawKillFloatTexts()
    local cx = logW_ * 0.5
    local baseY = logH_ * 0.35

    local slot = 0
    for _, ft in ipairs(killFloatTexts_) do
        local progress = 1.0 - (ft.timer / ft.duration)

        local alpha
        if progress < 0.08 then alpha = progress / 0.08
        elseif progress > 0.55 then alpha = (1.0 - progress) / 0.45
        else alpha = 1.0 end
        alpha = math.max(0, math.min(1, alpha))

        local scale
        if progress < 0.15 then
            local t = progress / 0.15
            scale = 2.0 - t * 1.0 + math.sin(t * math.pi * 2) * (1.0 - t) * 0.3
        elseif progress > 0.7 then
            local t = (progress - 0.7) / 0.3
            scale = 1.0 - t * 0.3
        else
            scale = 1.0
        end

        local shakeX, shakeY = 0, 0
        if progress < 0.3 then
            local intensity = (1.0 - progress / 0.3) * 3
            shakeX = math.sin(progress * 80) * intensity
            shakeY = math.cos(progress * 60) * intensity * 0.7
        end

        local y = baseY + slot * 50

        local baseFontSize = 36
        if ft.kind == "streak" then baseFontSize = 30 end
        local fontSize = math.floor(baseFontSize * scale)

        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, fontSize)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        local drawX = cx + shakeX
        local drawY = y + shakeY

        -- 发光
        local glowA = math.floor(alpha * 60)
        nvgFillColor(vg_, nvgRGBA(ft.r, ft.g, ft.b, glowA))
        nvgText(vg_, drawX, drawY + 3, ft.text)
        nvgText(vg_, drawX, drawY - 3, ft.text)
        nvgText(vg_, drawX + 3, drawY, ft.text)
        nvgText(vg_, drawX - 3, drawY, ft.text)

        -- 描边
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 200)))
        nvgText(vg_, drawX + 2, drawY + 2, ft.text)

        -- 主文字
        nvgFillColor(vg_, nvgRGBA(ft.r, ft.g, ft.b, math.floor(alpha * 255)))
        nvgText(vg_, drawX, drawY, ft.text)

        -- 高光
        local hlA = math.floor(alpha * 60)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, hlA))
        nvgText(vg_, drawX, drawY - 1, ft.text)

        slot = slot + 1
    end
end

-- ============================================================================
-- 状态覆盖层
-- ============================================================================

--- 倒计时覆盖层
function HUD.DrawCountdown()
    if gameManager_ == nil then return end

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(40, 25, 15, 100))
    nvgFill(vg_)

    local num = gameManager_.GetCountdownNumber()

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 120)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, logW_ * 0.5 + 3, logH_ * 0.5 + 3, tostring(num))

    if num <= 0 then
        nvgFillColor(vg_, nvgRGBA(50, 255, 100, 255))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, "GO!")
    else
        nvgFillColor(vg_, nvgRGBA(255, 255, 80, 255))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, tostring(num))
    end

    nvgFontSize(vg_, 18)
    nvgFillColor(vg_, nvgRGBA(220, 200, 170, 200))
    nvgText(vg_, logW_ * 0.5, logH_ * 0.5 + 80, "向上攀登，争取最高分！")
end

-- ============================================================================
-- 结算画面
-- ============================================================================

--- 绘制结算画面
function HUD.DrawResultScreen()
    if gameManager_ == nil then return end

    -- 半透明背景
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(30, 18, 10, 220))
    nvgFill(vg_)

    local cx = logW_ * 0.5
    local rankings = gameManager_.GetRankings()

    -- 提交云端分数（仅一次）
    if not cloudScoreSubmitted_ then
        cloudScoreSubmitted_ = true
        HUD.SubmitCloudScore(rankings)
    end

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 42)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    local winner = gameManager_.GetWinner()
    if winner == 1 then
        -- 玩家胜利
        local pulse = math.abs(math.sin(os.clock() * 2)) * 30 + 225
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
        nvgText(vg_, cx + 2, 44, "你赢了！")
        nvgFillColor(vg_, nvgRGBA(255, 215, 0, math.floor(pulse)))
        nvgText(vg_, cx, 42, "你赢了！")
    else
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
        nvgText(vg_, cx + 2, 44, "游戏结束")
        nvgFillColor(vg_, nvgRGBA(255, 200, 50, 255))
        nvgText(vg_, cx, 42, "游戏结束")
    end

    -- 排名表
    local tableY = 75
    local rowH = 26
    local tableW = math.min(logW_ * 0.85, 500)
    local tableX = cx - tableW * 0.5

    -- 表头
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 12)
    nvgFillColor(vg_, nvgRGBA(200, 180, 160, 200))

    local cols = {
        { x = tableX + 10,            label = "排名", align = NVG_ALIGN_LEFT },
        { x = tableX + 50,            label = "玩家", align = NVG_ALIGN_LEFT },
        { x = tableX + tableW * 0.35, label = "总分", align = NVG_ALIGN_CENTER },
        { x = tableX + tableW * 0.50, label = "高度", align = NVG_ALIGN_CENTER },
        { x = tableX + tableW * 0.63, label = "击杀", align = NVG_ALIGN_CENTER },
        { x = tableX + tableW * 0.76, label = "拾取", align = NVG_ALIGN_CENTER },
        { x = tableX + tableW * 0.89, label = "死亡", align = NVG_ALIGN_CENTER },
    }
    for _, col in ipairs(cols) do
        nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
        nvgText(vg_, col.x, tableY, col.label)
    end

    -- 数据行
    for rank, entry in ipairs(rankings) do
        local y = tableY + 18 + (rank - 1) * rowH
        local pc = Config.PlayerColors[entry.index]
        local r = math.floor(pc.r * 255)
        local g = math.floor(pc.g * 255)
        local b = math.floor(pc.b * 255)

        -- 行背景（高亮 P1）
        if entry.index == 1 then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, tableX, y - 2, tableW, rowH, 4)
            nvgFillColor(vg_, nvgRGBA(r, g, b, 30))
            nvgFill(vg_)
        end

        nvgFontFace(vg_, entry.index == 1 and "bold" or "sans")
        nvgFontSize(vg_, 14)

        local label = entry.index == 1 and "你" or ("P" .. entry.index)
        local values = {
            "#" .. rank,
            label,
            tostring(entry.score),
            tostring(entry.heightScore),
            tostring(entry.killScore),
            tostring(entry.pickupScore),
            tostring(entry.deaths),
        }

        for ci, col in ipairs(cols) do
            nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
            nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
            nvgText(vg_, col.x, y, values[ci])
        end
    end

    -- 分割线
    local divY = tableY + 18 + #rankings * rowH + 10
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, tableX, divY)
    nvgLineTo(vg_, tableX + tableW, divY)
    nvgStrokeColor(vg_, nvgRGBA(200, 180, 160, 60))
    nvgStrokeWidth(vg_, 1)
    nvgStroke(vg_)

    -- 云端排行榜
    local cloudY = divY + 10
    HUD.DrawCloudLeaderboard(cx, cloudY, tableW, tableX)

    -- 底部按钮
    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    local btnW = 130
    local btnH = 44
    local btnGap = 20
    local btnY = logH_ - 65

    -- "再来一局" 按钮
    local restartX = cx - btnW - btnGap * 0.5
    local restartHover = mx >= restartX and mx <= restartX + btnW and my >= btnY and my <= btnY + btnH
    local restartClicked = HUD.DrawRubberButton(restartX, btnY, btnW, btnH, "再来一局", 242, 56, 46, restartHover)
    if restartClicked then
        resultButtonClicked_ = "restart"
        cloudScoreSubmitted_ = false
        cloudLeaderboard_ = nil
        cloudLeaderboardLoading_ = false
    end

    -- "返回菜单" 按钮
    local menuX = cx + btnGap * 0.5
    local menuHover = mx >= menuX and mx <= menuX + btnW and my >= btnY and my <= btnY + btnH
    local menuClicked = HUD.DrawRubberButton(menuX, btnY, btnW, btnH, "返回菜单", 80, 65, 50, menuHover)
    if menuClicked then
        resultButtonClicked_ = "menu"
        cloudScoreSubmitted_ = false
        cloudLeaderboard_ = nil
        cloudLeaderboardLoading_ = false
    end
end

-- ============================================================================
-- 云端排行榜
-- ============================================================================

--- 提交玩家分数到云端
function HUD.SubmitCloudScore(rankings)
    -- 仅提交 P1（人类玩家）的分数
    local p1Entry = nil
    for _, entry in ipairs(rankings) do
        if entry.index == 1 then p1Entry = entry break end
    end
    if not p1Entry then return end

    local score = p1Entry.score
    if score <= 0 then return end

    -- 检查 clientCloud 是否可用
    if not clientCloud then
        print("[HUD] clientCloud not available, skipping cloud submit")
        return
    end

    -- 先读取历史最高分，仅在新纪录时更新
    clientCloud:Get("high_score", {
        ok = function(values, iscores)
            local oldScore = iscores.high_score or 0
            if score > oldScore then
                clientCloud:BatchSet()
                    :SetInt("high_score", score)
                    :SetInt("max_height", p1Entry.maxHeight or 0)
                    :Add("play_count", 1)
                    :Save("game result", {
                        ok = function()
                            print("[HUD] Cloud score submitted: " .. score)
                            HUD.LoadCloudLeaderboard()
                        end,
                        error = function(code, reason)
                            print("[HUD] Cloud submit error: " .. tostring(reason))
                            HUD.LoadCloudLeaderboard()
                        end
                    })
            else
                -- 分数没有超过，只增加 play_count
                clientCloud:Add("play_count", 1, {
                    ok = function()
                        print("[HUD] Play count incremented")
                        HUD.LoadCloudLeaderboard()
                    end,
                    error = function(code, reason)
                        HUD.LoadCloudLeaderboard()
                    end
                })
            end
        end,
        error = function(code, reason)
            print("[HUD] Cloud get error: " .. tostring(reason))
            -- 直接写入
            clientCloud:BatchSet()
                :SetInt("high_score", score)
                :SetInt("max_height", p1Entry.maxHeight or 0)
                :Add("play_count", 1)
                :Save("game result", {
                    ok = function()
                        HUD.LoadCloudLeaderboard()
                    end,
                    error = function()
                        HUD.LoadCloudLeaderboard()
                    end
                })
        end
    })
end

--- 加载云端排行榜
function HUD.LoadCloudLeaderboard()
    if not clientCloud then return end
    if cloudLeaderboardLoading_ then return end

    cloudLeaderboardLoading_ = true
    cloudLeaderboard_ = nil

    clientCloud:GetRankList("high_score", 0, 10, {
        ok = function(rankList)
            local leaderboard = {}
            local userIds = {}
            for i, item in ipairs(rankList) do
                table.insert(leaderboard, {
                    rank = i,
                    userId = item.userId,
                    score = item.iscore.high_score or 0,
                    maxHeight = item.iscore.max_height or 0,
                    playCount = item.iscore.play_count or 0,
                    isMe = item.userId == clientCloud.userId,
                })
                table.insert(userIds, item.userId)
            end

            if #userIds == 0 then
                cloudLeaderboard_ = leaderboard
                cloudLeaderboardLoading_ = false
                return
            end

            GetUserNickname({
                userIds = userIds,
                onSuccess = function(nicknames)
                    local map = {}
                    for _, info in ipairs(nicknames) do
                        map[info.userId] = info.nickname or ""
                    end
                    for _, entry in ipairs(leaderboard) do
                        entry.nickname = map[entry.userId] or "未知"
                    end
                    cloudLeaderboard_ = leaderboard
                    cloudLeaderboardLoading_ = false
                    print("[HUD] Cloud leaderboard loaded: " .. #leaderboard .. " entries")
                end,
                onError = function(errorCode)
                    for _, entry in ipairs(leaderboard) do
                        entry.nickname = "玩家"
                    end
                    cloudLeaderboard_ = leaderboard
                    cloudLeaderboardLoading_ = false
                end
            })
        end,
        error = function(code, reason)
            print("[HUD] Leaderboard load error: " .. tostring(reason))
            cloudLeaderboardLoading_ = false
        end
    }, "max_height", "play_count")
end

--- 绘制云端排行榜（在结算画面中）
function HUD.DrawCloudLeaderboard(cx, startY, tableW, tableX)
    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 215, 100, 220))
    nvgText(vg_, cx, startY, "云端排行榜")

    local contentY = startY + 24

    if cloudLeaderboardLoading_ then
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 14)
        nvgFillColor(vg_, nvgRGBA(200, 180, 160, 180))
        nvgText(vg_, cx, contentY, "加载中...")
        return
    end

    if not cloudLeaderboard_ or #cloudLeaderboard_ == 0 then
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 14)
        nvgFillColor(vg_, nvgRGBA(200, 180, 160, 180))
        if not clientCloud then
            nvgText(vg_, cx, contentY, "云端排行榜暂不可用")
        else
            nvgText(vg_, cx, contentY, "暂无数据")
        end
        return
    end

    -- 表头
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 11)
    nvgFillColor(vg_, nvgRGBA(180, 160, 140, 180))

    local cloudCols = {
        { x = tableX + 10,            label = "#",    align = NVG_ALIGN_LEFT },
        { x = tableX + 30,            label = "昵称",  align = NVG_ALIGN_LEFT },
        { x = tableX + tableW * 0.55, label = "最高分", align = NVG_ALIGN_CENTER },
        { x = tableX + tableW * 0.75, label = "最高高度", align = NVG_ALIGN_CENTER },
        { x = tableX + tableW * 0.92, label = "场次", align = NVG_ALIGN_CENTER },
    }
    for _, col in ipairs(cloudCols) do
        nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
        nvgText(vg_, col.x, contentY, col.label)
    end

    local rowH = 20
    for i, entry in ipairs(cloudLeaderboard_) do
        local y = contentY + 16 + (i - 1) * rowH

        -- "我" 的行高亮
        if entry.isMe then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, tableX, y - 2, tableW, rowH, 3)
            nvgFillColor(vg_, nvgRGBA(255, 215, 0, 25))
            nvgFill(vg_)
        end

        nvgFontFace(vg_, entry.isMe and "bold" or "sans")
        nvgFontSize(vg_, 13)

        local nameDisplay = entry.nickname or "玩家"
        if entry.isMe then nameDisplay = nameDisplay .. " (我)" end
        -- 截断昵称
        if #nameDisplay > 20 then nameDisplay = nameDisplay:sub(1, 18) .. ".." end

        local values = {
            tostring(entry.rank),
            nameDisplay,
            tostring(entry.score),
            tostring(entry.maxHeight),
            tostring(entry.playCount),
        }

        local textColor
        if entry.isMe then
            textColor = nvgRGBA(255, 215, 100, 255)
        elseif entry.rank == 1 then
            textColor = nvgRGBA(255, 200, 50, 255)
        elseif entry.rank <= 3 then
            textColor = nvgRGBA(220, 200, 180, 240)
        else
            textColor = nvgRGBA(200, 180, 160, 200)
        end

        for ci, col in ipairs(cloudCols) do
            nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
            nvgFillColor(vg_, textColor)
            nvgText(vg_, col.x, y, values[ci])
        end
    end
end

-- ============================================================================
-- 橡胶按钮
-- ============================================================================

--- 绘制橡胶材质按钮（5 层 NanoVG 效果）
function HUD.DrawRubberButton(x, y, w, h, label, baseR, baseG, baseB, hovered)
    local cornerR = h * 0.35

    -- 阴影
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x + 2, y + 4, w, h, cornerR)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, hovered and 100 or 70))
    nvgFill(vg_)

    -- 基色
    local br = hovered and math.min(255, baseR + 30) or baseR
    local bg = hovered and math.min(255, baseG + 30) or baseG
    local bb = hovered and math.min(255, baseB + 30) or baseB
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillColor(vg_, nvgRGBA(br, bg, bb, 255))
    nvgFill(vg_)

    -- 底部暗色渐变
    local darkPaint = nvgLinearGradient(vg_, x, y + h * 0.6, x, y + h,
        nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 0, 0, 80))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillPaint(vg_, darkPaint)
    nvgFill(vg_)

    -- 顶部高光
    local glossPaint = nvgLinearGradient(vg_, x, y, x, y + h * 0.45,
        nvgRGBA(255, 255, 255, hovered and 110 or 80), nvgRGBA(255, 255, 255, 0))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillPaint(vg_, glossPaint)
    nvgFill(vg_)

    -- 边框
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    local darkR = math.floor(baseR * 0.5)
    local darkG = math.floor(baseG * 0.5)
    local darkB = math.floor(baseB * 0.5)
    nvgStrokeColor(vg_, nvgRGBA(darkR, darkG, darkB, hovered and 200 or 140))
    nvgStrokeWidth(vg_, 2)
    nvgStroke(vg_)

    -- 文字阴影
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.floor(h * 0.42))
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 120))
    nvgText(vg_, x + w * 0.5 + 1, y + h * 0.52 + 1, label)

    -- 文字
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
    nvgText(vg_, x + w * 0.5, y + h * 0.52, label)

    -- 点击检测
    if cachedMousePress_ and hovered then
        return true
    end
    return false
end

-- ============================================================================
-- 主菜单
-- ============================================================================

function HUD.DrawMenu()
    -- 全屏背景渐变
    local bgPaint = nvgLinearGradient(vg_, 0, 0, logW_, logH_,
        nvgRGBA(250, 217, 179, 255), nvgRGBA(224, 166, 153, 255))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillPaint(vg_, bgPaint)
    nvgFill(vg_)

    -- 装饰粒子
    local t = os.clock()
    for i = 1, 20 do
        local px = (math.sin(t * 0.3 + i * 1.7) * 0.5 + 0.5) * logW_
        local py = (math.cos(t * 0.2 + i * 2.3) * 0.5 + 0.5) * logH_
        local alpha = math.abs(math.sin(t * 0.5 + i)) * 60 + 20
        local radius = 2 + math.sin(t + i) * 1.5
        nvgBeginPath(vg_)
        nvgCircle(vg_, px, py, radius)
        nvgFillColor(vg_, nvgRGBA(255, 255, 220, math.floor(alpha)))
        nvgFill(vg_)
    end

    local cx = logW_ * 0.5
    local cy = logH_ * 0.38

    -- 标题图片
    local titleBottom = cy + 40

    if titleImage_ > 0 and titleImageW_ > 0 then
        local maxW = logW_ * 0.55
        local imgScale = maxW / titleImageW_
        local drawW = titleImageW_ * imgScale
        local drawH = titleImageH_ * imgScale
        local imgX = cx - drawW * 0.5
        local imgY = cy - drawH * 0.5

        local floatY = math.sin(t * 1.2) * 4
        imgY = imgY + floatY

        local glowA = math.floor(math.abs(math.sin(t * 1.5)) * 30 + 20)
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, imgX - 10, imgY - 6, drawW + 20, drawH + 12, 16)
        nvgFillColor(vg_, nvgRGBA(255, 80, 40, glowA))
        nvgFill(vg_)

        local imgPaint = nvgImagePattern(vg_, imgX, imgY, drawW, drawH, 0, titleImage_, 1.0)
        nvgBeginPath(vg_)
        nvgRect(vg_, imgX, imgY, drawW, drawH)
        nvgFillPaint(vg_, imgPaint)
        nvgFill(vg_)

        titleBottom = imgY + drawH
    else
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 72)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
        nvgText(vg_, cx + 3, cy + 3, Config.Title)
        nvgFillColor(vg_, nvgRGBA(255, 90, 40, 255))
        nvgText(vg_, cx, cy, Config.Title)
    end

    -- 副标题
    local subtitleY = titleBottom + 14
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(220, 200, 180, 180))
    nvgText(vg_, cx, subtitleY, "大地图攀登挑战  3分钟限时赛")

    -- 开始按钮（居中单个大按钮）
    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    local btnW = 180
    local btnH = 56
    local btnY = subtitleY + 30
    local btnX = cx - btnW * 0.5

    local hovered = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH
    local clicked = HUD.DrawRubberButton(btnX, btnY, btnW, btnH, "开始游戏", 242, 56, 46, hovered)
    if clicked then
        menuButtonClicked_ = "startGame"
    end

    -- 底部玩家颜色指示（6 名玩家）
    local dotY = btnY + btnH + 30
    local dotSpacing = 42
    local dotStartX = cx - dotSpacing * (Config.NumPlayers - 1) * 0.5
    nvgFontSize(vg_, 11)
    for i = 1, Config.NumPlayers do
        local dx = dotStartX + (i - 1) * dotSpacing
        local color = Config.PlayerColors[i]
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, dx - 7, dotY - 7, 14, 14, 4)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgFill(vg_)

        nvgFillColor(vg_, nvgRGBA(100, 70, 50, 200))
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        local label = i == 1 and "你" or ("AI" .. (i - 1))
        nvgText(vg_, dx, dotY + 10, label)
    end

    -- 操作说明
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(120, 90, 70, 160))
    nvgText(vg_, cx, logH_ - 10, "A/D:移动  空格:跳跃  Shift:冲刺  S:下砸  鼠标左键:蓄力爆炸")
end

return HUD

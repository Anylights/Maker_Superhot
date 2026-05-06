-- ============================================================================
-- HUD.lua - NanoVG 游戏 HUD（持久世界模式 v2）
-- 显示：会话计时器、会话分数、能量条、排行榜、结算、世界空间指示器
-- 使用 NanoVG Mode B（系统逻辑分辨率）
-- ============================================================================

local Config = require("Config")
local Camera = require("Camera")
local FXDiag = require("FXDiag")

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

-- 标题图片句柄
local titleImage_ = -1
local titleImageW_ = 0
local titleImageH_ = 0

-- 帧缓存：鼠标点击状态（在 Update 阶段缓存，供 NanoVG 渲染阶段的按钮使用）
local cachedMousePress_ = false
local cachedMouseLogX_ = 0
local cachedMouseLogY_ = 0
local prevMouseDown_ = false
local cacheInputCalledThisFrame_ = false

-- 调试变量
local dbg_cacheInputCount_ = 0
local dbg_cacheInputMissed_ = 0
local dbg_lastPressTime_ = 0
local dbg_mouseDownRaw_ = false
local dbg_lastClickX_ = 0
local dbg_lastClickY_ = 0
local dbg_lastAction_ = "none"
local dbg_lastActionTime_ = 0
local dbg_btnReturnTrue_ = 0

-- 帧率监测
local fpsRenderFrames_ = 0
local fpsLastSample_ = -1
local fpsRenderValue_ = 0
local fpsNetValue_ = 0

-- 调试信息总开关（F2 切换）
local debugVisible_ = false
local prevF2Down_ = false

-- 引擎时间缓存（每帧更新一次）
local hudElapsedTime_ = 0

--- 在 Update 阶段缓存鼠标输入状态
function HUD.CacheInput()
    cacheInputCalledThisFrame_ = true
    dbg_cacheInputCount_ = dbg_cacheInputCount_ + 1
    local down = input:GetMouseButtonDown(MOUSEB_LEFT)
    dbg_mouseDownRaw_ = down
    cachedMousePress_ = down and not prevMouseDown_
    prevMouseDown_ = down
    if cachedMousePress_ then
        cachedMouseLogX_ = input.mousePosition.x / dpr_
        cachedMouseLogY_ = input.mousePosition.y / dpr_
        dbg_lastPressTime_ = os.clock()
        dbg_lastClickX_ = cachedMouseLogX_
        dbg_lastClickY_ = cachedMouseLogY_
    end

    local f2Down = input:GetKeyDown(KEY_F2)
    if f2Down and not prevF2Down_ then
        debugVisible_ = not debugVisible_
    end
    prevF2Down_ = f2Down
end

function HUD.IsDebugVisible()
    return debugVisible_
end

-- 击杀动效系统
local killFloatTexts_ = {}
local KILL_FLOAT_DURATION = 2.0
local lastRenderTime_ = 0
-- 动态击杀弹跳计时（按玩家 index 索引）
local killBounceTimers_ = {}
local KILL_BOUNCE_DURATION = 0.8

-- ============================================================================
-- 初始化
-- ============================================================================

---@param playerRef table
---@param gmRef table
---@param mapRef table|nil
function HUD.Init(playerRef, gmRef, mapRef)
    playerModule_ = playerRef
    gameManager_ = gmRef
    mapModule_ = mapRef

    vg_ = nvgCreate(1)

    HUD.RefreshResolution()

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

    SubscribeToEvent(vg_, "NanoVGRender", "HandleNanoVGRender")
    SubscribeToEvent("ScreenMode", "HandleScreenMode_HUD")

    print("[HUD] Initialized (persistent world mode)")
end

function HUD.GetNVGContext()
    return vg_
end

function HUD.GetLogicalSize()
    return logW_, logH_
end

function HUD.RefreshResolution()
    physW_ = graphics:GetWidth()
    physH_ = graphics:GetHeight()
    dpr_ = graphics:GetDPR()
    logW_ = physW_ / dpr_
    logH_ = physH_ / dpr_
end

-- ============================================================================
-- 渲染主入口
-- ============================================================================

function HandleNanoVGRender(eventType, eventData)
    if vg_ == nil then return end

    if not cacheInputCalledThisFrame_ then
        HUD.CacheInput()
        dbg_cacheInputMissed_ = dbg_cacheInputMissed_ + 1
    end
    cacheInputCalledThisFrame_ = false

    local now = time:GetElapsedTime()
    local renderDt = now - lastRenderTime_
    if renderDt > 0.1 then renderDt = 0.016 end
    lastRenderTime_ = now
    hudElapsedTime_ = now

    HUD.UpdateKillFloats(renderDt)

    nvgBeginFrame(vg_, logW_, logH_, dpr_)

    HUD.DrawFpsHud()

    -- 客户端状态路由
    local clientMod = _G.ClientModule
    if clientMod then
        local cs = clientMod.GetState()
        if cs == "connecting" then
            HUD.DrawConnecting()
            HUD.DrawToast()
            HUD.DrawDebugOverlay()
            nvgEndFrame(vg_)
            return
        elseif cs == "results" then
            HUD.DrawBackground()
            HUD.DrawResults()
            HUD.DrawToast()
            HUD.DrawDebugOverlay()
            nvgEndFrame(vg_)
            return
        end
        -- cs == "playing" → 走下方游戏 HUD
    end

    -- 单机/联机 playing 状态
    local state = gameManager_ and gameManager_.state or "playing"

    if state == "waiting" then
        HUD.DrawConnecting()
        nvgEndFrame(vg_)
        return
    end

    if state == "results" then
        HUD.DrawBackground()
        HUD.DrawResults()
        nvgEndFrame(vg_)
        return
    end

    -- 游戏进行中
    HUD.DrawBackground()
    HUD.DrawWorldIndicators()
    HUD.DrawEnergyBars()
    HUD.DrawSessionTimer()
    HUD.DrawSessionScores()
    HUD.DrawLeaderboard()
    HUD.DrawKillScorePanel()

    HUD.ConsumeKillEvents()
    HUD.DrawKillFloatTexts()

    HUD.DrawFXDiagPanel()
    HUD.DrawDebugOverlay()

    nvgEndFrame(vg_)
end

function HandleScreenMode_HUD(eventType, eventData)
    HUD.RefreshResolution()
end

-- ============================================================================
-- 背景（委托给 Background.lua 的 3D 渲染）
-- ============================================================================

function HUD.DrawBackground()
    -- 背景已由 Background.lua 在 3D 场景中渲染
end

-- ============================================================================
-- 连接等待界面
-- ============================================================================

function HUD.DrawConnecting()
    HUD.DrawAnimatedBgPattern({
        bgTop    = { 36, 32, 56 },
        bgBottom = { 26, 24, 44 },
        accent   = { 50, 46, 74, 90 },
    })

    local cx = logW_ * 0.5
    local cy = logH_ * 0.45
    local t = hudElapsedTime_

    -- 旋转圆环
    local ringR = 20
    nvgSave(vg_)
    nvgTranslate(vg_, cx, cy - 30)
    nvgRotate(vg_, t * 3.0)
    nvgBeginPath(vg_)
    nvgArc(vg_, 0, 0, ringR, 0, math.pi * 1.5, NVG_CW)
    nvgStrokeColor(vg_, nvgRGBA(255, 220, 140, 220))
    nvgStrokeWidth(vg_, 4)
    nvgLineCap(vg_, NVG_ROUND)
    nvgStroke(vg_)
    nvgRestore(vg_)

    local dots = string.rep(".", (math.floor(t * 2) % 4))
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 24)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
    nvgText(vg_, cx + 1, cy + 21, "连接中" .. dots)
    nvgFillColor(vg_, nvgRGBA(255, 220, 140, 255))
    nvgText(vg_, cx, cy + 20, "连接中" .. dots)
end

-- ============================================================================
-- 会话计时器（顶部中央）
-- ============================================================================

function HUD.DrawSessionTimer()
    local remaining = 0
    local clientMod = _G.ClientModule
    if clientMod and clientMod.GetSessionScores then
        remaining = clientMod.GetSessionScores().timer or 0
    elseif gameManager_ then
        -- 单机模式：从本地人类玩家获取
        local hp = gameManager_.GetHumanPlayer and gameManager_.GetHumanPlayer()
        if hp and hp.session then
            remaining = math.max(0, hp.session.timer)
        end
    end

    local seconds = math.floor(remaining)
    local timeStr = tostring(seconds) .. "s"

    local tw = 70
    local th = 30
    local tx = (logW_ - tw) * 0.5
    local ty = 10

    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, tx, ty, tw, th, 6)
    if remaining <= 10 then
        local pulse = math.abs(math.sin(hudElapsedTime_ * 3)) * 100 + 50
        nvgFillColor(vg_, nvgRGBA(180, 30, 30, math.floor(pulse) + 100))
    else
        nvgFillColor(vg_, nvgRGBA(50, 38, 30, 210))
    end
    nvgFill(vg_)

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 18)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    if remaining <= 10 then
        nvgFillColor(vg_, nvgRGBA(255, 80, 60, 255))
    else
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    end
    nvgText(vg_, tx + tw * 0.5, ty + th * 0.5, timeStr)
end

-- ============================================================================
-- 会话分数（右上角）
-- ============================================================================

function HUD.DrawSessionScores()
    local scores = nil
    local clientMod = _G.ClientModule
    if clientMod and clientMod.GetSessionScores then
        scores = clientMod.GetSessionScores()
    elseif gameManager_ then
        -- 单机模式
        local hp = gameManager_.GetHumanPlayer and gameManager_.GetHumanPlayer()
        if hp and hp.session then
            scores = {
                heightScore = hp.session.heightScore or 0,
                killScore = hp.session.killScore or 0,
                pickupScore = hp.session.pickupScore or 0,
                totalScore = hp.session.totalScore or 0,
            }
        end
    end
    if not scores then return end

    local x = logW_ - 16
    local startY = 16
    local lineH = 18

    -- 总分标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 120))
    nvgText(vg_, x + 1, startY + 1, tostring(scores.totalScore))
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    nvgText(vg_, x, startY, tostring(scores.totalScore))

    -- 分项
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)

    local details = {
        { label = "高度", value = scores.heightScore, r = 120, g = 200, b = 255 },
        { label = "击杀", value = scores.killScore,   r = 255, g = 120, b = 100 },
        { label = "拾取", value = scores.pickupScore,  r = 100, g = 255, b = 150 },
    }
    for i, d in ipairs(details) do
        local y = startY + 22 + (i - 1) * lineH
        local text = d.label .. " " .. d.value
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 100))
        nvgText(vg_, x + 1, y + 1, text)
        nvgFillColor(vg_, nvgRGBA(d.r, d.g, d.b, 220))
        nvgText(vg_, x, y, text)
    end
end

-- ============================================================================
-- 排行榜（左下角，紧凑样式）
-- ============================================================================

function HUD.DrawLeaderboard()
    local board = nil
    if gameManager_ and gameManager_.leaderboard then
        board = gameManager_.leaderboard
    end
    if not board or #board == 0 then return end

    local panelX = 12
    local panelY = logH_ - 12
    local lineH = 18
    local maxShow = math.min(#board, 8)

    -- 从底部往上画
    local totalH = lineH * maxShow + 24
    panelY = panelY - totalH

    -- 半透明背景
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, panelX - 4, panelY - 4, 150, totalH + 8, 6)
    nvgFillColor(vg_, nvgRGBA(20, 12, 8, 140))
    nvgFill(vg_)

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 220, 140, 200))
    nvgText(vg_, panelX, panelY, "排行榜")

    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)

    local mySlot = 0
    local clientMod = _G.ClientModule
    if clientMod and clientMod.GetMySlot then
        mySlot = clientMod.GetMySlot()
    end

    for i = 1, maxShow do
        local entry = board[i]
        local y = panelY + 18 + (i - 1) * lineH
        local colorIdx = ((entry.index - 1) % Config.NumPlayerColors) + 1
        local pc = Config.PlayerColors[colorIdx]
        local r = math.floor(pc.r * 255)
        local g = math.floor(pc.g * 255)
        local b = math.floor(pc.b * 255)

        local prefix = "#" .. i .. " "
        local label = entry.isHuman and "P" .. entry.index or "AI"
        local scoreStr = " " .. entry.score

        -- 高亮本机玩家
        if entry.index == mySlot then
            nvgFontFace(vg_, "bold")
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
        else
            nvgFontFace(vg_, "sans")
            nvgFillColor(vg_, nvgRGBA(r, g, b, 220))
        end

        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgText(vg_, panelX, y, prefix .. label .. scoreStr)
    end
end

-- ============================================================================
-- 结算页面
-- ============================================================================

function HUD.DrawResults()
    -- 半透明覆盖
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(30, 18, 10, 200))
    nvgFill(vg_)

    local cx = logW_ * 0.5
    local cy = logH_ * 0.5

    -- 获取最终分数
    local scores = nil
    local clientMod = _G.ClientModule
    if clientMod and clientMod.GetFinalScores then
        scores = clientMod.GetFinalScores()
    elseif gameManager_ then
        local hp = gameManager_.GetHumanPlayer and gameManager_.GetHumanPlayer()
        if hp and hp.session then
            scores = {
                heightScore = hp.session.heightScore or 0,
                killScore = hp.session.killScore or 0,
                pickupScore = hp.session.pickupScore or 0,
                totalScore = hp.session.totalScore or 0,
            }
        end
    end
    if not scores then scores = { heightScore = 0, killScore = 0, pickupScore = 0, totalScore = 0 } end

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 42)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, cx + 2, cy - 100 + 2, "会话结束!")
    nvgFillColor(vg_, nvgRGBA(255, 200, 50, 255))
    nvgText(vg_, cx, cy - 100, "会话结束!")

    -- 总分（大字号）
    nvgFontSize(vg_, 56)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
    nvgText(vg_, cx + 2, cy - 45 + 2, tostring(scores.totalScore))
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
    nvgText(vg_, cx, cy - 45, tostring(scores.totalScore))

    nvgFontSize(vg_, 14)
    nvgFillColor(vg_, nvgRGBA(200, 180, 140, 180))
    nvgText(vg_, cx, cy - 15, "总分")

    -- 分数明细
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 18)

    local detailY = cy + 10
    local detailGap = 28
    local details = {
        { label = "高度分",  value = scores.heightScore, r = 120, g = 200, b = 255 },
        { label = "击杀分",  value = scores.killScore,   r = 255, g = 120, b = 100 },
        { label = "拾取分",  value = scores.pickupScore,  r = 100, g = 255, b = 150 },
    }
    for i, d in ipairs(details) do
        local y = detailY + (i - 1) * detailGap
        nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(200, 190, 170, 200))
        nvgText(vg_, cx - 10, y, d.label)

        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(d.r, d.g, d.b, 255))
        nvgText(vg_, cx + 10, y, tostring(d.value))
    end

    -- 排行榜预览（右侧）
    local board = gameManager_ and gameManager_.leaderboard or {}
    if #board > 0 then
        local boardX = cx + 160
        local boardY = cy - 80
        local boardLineH = 22

        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 14)
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg_, nvgRGBA(255, 220, 140, 200))
        nvgText(vg_, boardX, boardY, "排行榜")

        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        local maxShow = math.min(#board, 10)

        local mySlot = 0
        if clientMod and clientMod.GetMySlot then
            mySlot = clientMod.GetMySlot()
        end

        for i = 1, maxShow do
            local entry = board[i]
            local y = boardY + 20 + (i - 1) * boardLineH
            local colorIdx = ((entry.index - 1) % Config.NumPlayerColors) + 1
            local pc = Config.PlayerColors[colorIdx]
            local r = math.floor(pc.r * 255)
            local g = math.floor(pc.g * 255)
            local b = math.floor(pc.b * 255)

            local label = entry.isHuman and "P" .. entry.index or "AI"
            local text = "#" .. i .. " " .. label .. "  " .. entry.score

            if entry.index == mySlot then
                nvgFontFace(vg_, "bold")
                nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
            else
                nvgFontFace(vg_, "sans")
                nvgFillColor(vg_, nvgRGBA(r, g, b, 220))
            end
            nvgText(vg_, boardX, y, text)
        end
    end

    -- 按钮区域
    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    local btnW = 140
    local btnH = 50
    local btnGap = 20
    local totalBtnW = btnW * 2 + btnGap
    local btnStartX = cx - totalBtnW * 0.5
    local btnY = cy + 110

    -- 再来一局
    local bx1 = btnStartX
    local h1 = mx >= bx1 and mx <= bx1 + btnW and my >= btnY and my <= btnY + btnH
    if HUD.DrawRubberButton(bx1, btnY, btnW, btnH, "再来一局", 242, 56, 46, h1) then
        if clientMod and clientMod.RequestRestart then
            clientMod.RequestRestart()
        elseif _G.StandaloneModule and _G.StandaloneModule.RequestRestart then
            _G.StandaloneModule.RequestRestart()
        end
    end

    -- 退出（回主菜单 — 持久世界中退出即断开连接）
    local bx2 = btnStartX + btnW + btnGap
    local h2 = mx >= bx2 and mx <= bx2 + btnW and my >= btnY and my <= btnY + btnH
    if HUD.DrawRubberButton(bx2, btnY, btnW, btnH, "退出", 120, 100, 90, h2) then
        -- 退出连接（引擎 API）
        if network then
            network:Disconnect(100)
        end
    end
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

function HUD.DrawWorldIndicators()
    if playerModule_ == nil then return end

    for _, p in ipairs(playerModule_.list) do
        if p.alive and p.node then
            local pos = p.node.position
            local colorIdx = ((p.index - 1) % Config.NumPlayerColors) + 1

            -- 冲刺冷却环
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

            -- 蓄力警告区域
            if p.charging then
                local sx, sy = Camera.WorldToScreen(pos.x, pos.y, logW_, logH_)
                local maxWorldRadius = Config.ExplosionRadius * Config.BlockSize
                local currentWorldRadius = maxWorldRadius * p.chargeProgress
                local screenRadius = Camera.WorldSizeToScreen(currentWorldRadius, logH_)

                local pc = Config.PlayerColors[colorIdx]
                local pr = math.floor(pc.r * 255)
                local pg = math.floor(pc.g * 255)
                local pb = math.floor(pc.b * 255)

                local freq = 4 + p.chargeProgress * 12
                local pulse = math.abs(math.sin(hudElapsedTime_ * freq)) * 0.4 + 0.2

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

    HUD.DrawDestroyedBlockGhosts()
end

--- 绘制被炸方块的轮廓和重生进度条
function HUD.DrawDestroyedBlockGhosts()
    if mapModule_ == nil then return end

    local blocks = mapModule_.GetDestroyedBlocks()
    if #blocks == 0 then return end

    local bs = Config.BlockSize
    local blockScreenSize = Camera.WorldSizeToScreen(bs, logH_)
    if blockScreenSize < 3 then return end

    local cornerR = blockScreenSize * 0.18
    local elapsedTime = time:GetElapsedTime()

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
        local alpha = 80 + math.floor(math.abs(math.sin(elapsedTime * 3 + info.x * 0.7)) * 40)

        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, drawX, drawY, drawSize, drawSize, cornerR)
        nvgStrokeColor(vg_, nvgRGBA(200, 200, 220, alpha))
        nvgStrokeWidth(vg_, 2.0)
        nvgStroke(vg_)

        if progress > 0.01 then
            local pAlpha = 160 + math.floor(progress * 95)
            local acx = sx
            local acy = sy
            local radius = drawSize * 0.3
            local startA = -math.pi * 0.5
            local endA = startA + math.pi * 2 * progress
            nvgBeginPath(vg_)
            nvgArc(vg_, acx, acy, radius, startA, endA, NVG_CW)
            nvgStrokeColor(vg_, nvgRGBA(120, 200, 255, pAlpha))
            nvgStrokeWidth(vg_, 3.0)
            nvgStroke(vg_)
        end
    end
end

-- ============================================================================
-- 能量条（世界空间，玩家头顶）
-- ============================================================================

function HUD.DrawEnergyBars()
    if playerModule_ == nil then return end

    for _, p in ipairs(playerModule_.list) do
        if not p.alive or not p.node then goto continueBar end

        local pos = p.node.position
        local colorIdx = ((p.index - 1) % Config.NumPlayerColors) + 1
        local color = Config.PlayerColors[colorIdx]
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

        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, barW, barH, cornerR)
        nvgFillColor(vg_, nvgRGBA(30, 20, 15, 180))
        nvgFill(vg_)

        local fillW = barW * math.min(1, p.energy)
        if fillW > 0.5 then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, bx, by, fillW, barH, cornerR)
            if p.energy >= 1.0 then
                local pulse = math.abs(math.sin(hudElapsedTime_ * 4)) * 55 + 200
                nvgFillColor(vg_, nvgRGBA(255, 40, 30, math.floor(pulse)))
            else
                nvgFillColor(vg_, nvgRGBA(180, 220, 255, 210))
            end
            nvgFill(vg_)
        end

        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, barW, barH, cornerR)
        nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 60))
        nvgStrokeWidth(vg_, 1.0)
        nvgStroke(vg_)

        ::continueBar::
    end
end

-- ============================================================================
-- 击杀分值面板 + 浮动文字动效
-- ============================================================================

function HUD.ConsumeKillEvents()
    if gameManager_ == nil then return end

    for _, evt in ipairs(gameManager_.killEvents) do
        local killerIdx = evt.killerIndex
        local multiKill = evt.multiKillCount
        local streak = evt.killStreak

        -- 动态弹跳计时器
        killBounceTimers_[killerIdx] = KILL_BOUNCE_DURATION

        local colorIdx = ((killerIdx - 1) % Config.NumPlayerColors) + 1
        local pc = Config.PlayerColors[colorIdx]
        local cr = math.floor(pc.r * 255)
        local cg = math.floor(pc.g * 255)
        local cb = math.floor(pc.b * 255)

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

    -- 更新弹跳计时器（动态 key）
    for idx, t in pairs(killBounceTimers_) do
        if t > 0 then
            killBounceTimers_[idx] = t - dt
            if killBounceTimers_[idx] < 0 then killBounceTimers_[idx] = 0 end
        end
    end
end

--- 绘制击杀面板（左上角，动态玩家数）
function HUD.DrawKillScorePanel()
    if gameManager_ == nil or playerModule_ == nil then return end
    if #playerModule_.list == 0 then return end

    local panelX = 12
    local panelY = 12
    local lineH = 22
    local headerH = 20
    local panelW = 120

    -- 仅显示有击杀记录或存活的玩家
    local visiblePlayers = {}
    for _, p in ipairs(playerModule_.list) do
        if p.alive or (p.session and p.session.killScore and p.session.killScore > 0) then
            table.insert(visiblePlayers, p)
        end
    end
    if #visiblePlayers == 0 then return end

    local maxShow = math.min(#visiblePlayers, 8)

    local totalH = headerH + maxShow * lineH + 4
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, panelX - 4, panelY - 4, panelW + 8, totalH + 8, 6)
    nvgFillColor(vg_, nvgRGBA(20, 12, 8, 140))
    nvgFill(vg_)

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 160))
    nvgText(vg_, panelX, panelY, "击杀")

    for vi = 1, maxShow do
        local p = visiblePlayers[vi]
        local y = panelY + headerH + (vi - 1) * lineH
        local colorIdx = ((p.index - 1) % Config.NumPlayerColors) + 1
        local pc = Config.PlayerColors[colorIdx]
        local r = math.floor(pc.r * 255)
        local g = math.floor(pc.g * 255)
        local b = math.floor(pc.b * 255)

        local kills = (p.session and p.session.killScore) and math.floor(p.session.killScore / Config.KillScore) or 0

        -- 玩家色块
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, panelX, y + 4, 10, 10, 2)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgFill(vg_)

        -- 弹跳动画
        local bounceT = killBounceTimers_[p.index] or 0
        local isAnimating = bounceT > 0

        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

        local label = p.isHuman and ("P" .. p.index) or "AI"
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 220))
        nvgText(vg_, panelX + 14, y + 9, label)

        -- 击杀数字
        local numScale = 1.0
        if isAnimating then
            local bp = 1.0 - (bounceT / KILL_BOUNCE_DURATION)
            local elastic = 1.0 + math.sin(bp * math.pi * 3) * math.exp(-bp * 4) * 0.6
            numScale = elastic
        end

        local numX = panelX + 46
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
        nvgText(vg_, numX + 1, numY + 1 - shakeY, tostring(kills))
        if isAnimating then
            nvgFillColor(vg_, nvgRGBA(math.min(255, r + 60), math.min(255, g + 60), math.min(255, b + 60), 255))
        else
            nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        end
        nvgText(vg_, numX, numY - shakeY, tostring(kills))

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
            nvgText(vg_, numX + 20 + plusOffX + 1, numY + plusOffY + 1, "+1")
            nvgFillColor(vg_, nvgRGBA(255, 255, 80, math.floor(plusAlpha * 255)))
            nvgText(vg_, numX + 20 + plusOffX, numY + plusOffY, "+1")
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

        local glowA = math.floor(alpha * 60)
        nvgFillColor(vg_, nvgRGBA(ft.r, ft.g, ft.b, glowA))
        nvgText(vg_, drawX, drawY + 3, ft.text)
        nvgText(vg_, drawX, drawY - 3, ft.text)
        nvgText(vg_, drawX + 3, drawY, ft.text)
        nvgText(vg_, drawX - 3, drawY, ft.text)

        nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 200)))
        nvgText(vg_, drawX + 2, drawY + 2, ft.text)

        nvgFillColor(vg_, nvgRGBA(ft.r, ft.g, ft.b, math.floor(alpha * 255)))
        nvgText(vg_, drawX, drawY, ft.text)

        local hlA = math.floor(alpha * 60)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, hlA))
        nvgText(vg_, drawX, drawY - 1, ft.text)

        slot = slot + 1
    end
end

-- ============================================================================
-- 动画背景图案（连接/等待界面用）
-- ============================================================================

function HUD.DrawAnimatedBgPattern(palette)
    local bt, bb = palette.bgTop, palette.bgBottom
    local bgPaint = nvgLinearGradient(vg_, 0, 0, logW_, logH_,
        nvgRGBA(bt[1], bt[2], bt[3], 255),
        nvgRGBA(bb[1], bb[2], bb[3], 255))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillPaint(vg_, bgPaint)
    nvgFill(vg_)

    local accent = palette.accent or { bt[1] + 18, bt[2] + 18, bt[3] + 22, 90 }
    local tile = palette.tile or 80
    local speed = palette.speed or 30
    local spinSpeed = palette.spinSpeed or 0.3
    local t = (time and time.GetElapsedTime) and time:GetElapsedTime() or os.clock()
    local offX = -((t * speed) % tile)
    local offY =  ((t * speed) % (tile * 2))
    local cols = math.ceil(logW_ / tile) + 3
    local rows = math.ceil(logH_ / tile) + 4
    local spin = t * spinSpeed

    nvgFillColor(vg_, nvgRGBA(accent[1], accent[2], accent[3], accent[4] or 90))
    local sz = tile * 0.22
    local baseRot = math.pi * 0.25

    local angle = baseRot + spin
    local cosA = math.cos(angle)
    local sinA = math.sin(angle)
    local dx1 = -sz * cosA - (-sz) * sinA
    local dy1 = -sz * sinA + (-sz) * cosA
    local dx2 =  sz * cosA - (-sz) * sinA
    local dy2 =  sz * sinA + (-sz) * cosA
    local dx3 =  sz * cosA -   sz  * sinA
    local dy3 =  sz * sinA +   sz  * cosA
    local dx4 = -sz * cosA -   sz  * sinA
    local dy4 = -sz * sinA +   sz  * cosA

    nvgBeginPath(vg_)
    local halfTile = tile * 0.5
    for ri = -2, rows do
        local rowOdd = (ri % 2 ~= 0) and halfTile or 0
        local baseY = ri * tile + offY
        for ci = -2, cols do
            local ccx = ci * tile + offX + rowOdd
            local ccy = baseY
            nvgMoveTo(vg_, ccx + dx1, ccy + dy1)
            nvgLineTo(vg_, ccx + dx2, ccy + dy2)
            nvgLineTo(vg_, ccx + dx3, ccy + dy3)
            nvgLineTo(vg_, ccx + dx4, ccy + dy4)
            nvgClosePath(vg_)
        end
    end
    nvgFill(vg_)
end

-- ============================================================================
-- Toast 提示
-- ============================================================================

function HUD.DrawToast()
    local clientMod = _G.ClientModule
    if not clientMod then return end
    local msg, timer = clientMod.GetToast()
    if not msg or msg == "" or timer <= 0 then return end

    local alpha = math.min(1.0, timer) * 255

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 20)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    local tw = nvgTextBounds(vg_, 0, 0, msg)
    local padX = 20
    local padY = 8
    local ty = 40
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, logW_ * 0.5 - tw * 0.5 - padX, ty - 14 - padY, tw + padX * 2, 28 + padY * 2, 10)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.6)))
    nvgFill(vg_)

    nvgFillColor(vg_, nvgRGBA(255, 220, 140, math.floor(alpha)))
    nvgText(vg_, logW_ * 0.5, ty, msg)
end

-- ============================================================================
-- 橡胶按钮
-- ============================================================================

function HUD.DrawRubberButton(x, y, w, h, label, baseR, baseG, baseB, hovered)
    local cornerR = h * 0.35

    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x + 2, y + 4, w, h, cornerR)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, hovered and 100 or 70))
    nvgFill(vg_)

    local br = hovered and math.min(255, baseR + 30) or baseR
    local bg = hovered and math.min(255, baseG + 30) or baseG
    local bb = hovered and math.min(255, baseB + 30) or baseB
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillColor(vg_, nvgRGBA(br, bg, bb, 255))
    nvgFill(vg_)

    local darkPaint = nvgLinearGradient(vg_, x, y + h * 0.6, x, y + h,
        nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 0, 0, 80))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillPaint(vg_, darkPaint)
    nvgFill(vg_)

    local glossPaint = nvgLinearGradient(vg_, x, y, x, y + h * 0.45,
        nvgRGBA(255, 255, 255, hovered and 110 or 80), nvgRGBA(255, 255, 255, 0))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillPaint(vg_, glossPaint)
    nvgFill(vg_)

    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    local darkR = math.floor(baseR * 0.5)
    local darkG = math.floor(baseG * 0.5)
    local darkB = math.floor(baseB * 0.5)
    nvgStrokeColor(vg_, nvgRGBA(darkR, darkG, darkB, hovered and 200 or 140))
    nvgStrokeWidth(vg_, 2)
    nvgStroke(vg_)

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.floor(h * 0.42))
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 120))
    nvgText(vg_, x + w * 0.5 + 1, y + h * 0.52 + 1, label)

    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
    nvgText(vg_, x + w * 0.5, y + h * 0.52, label)

    if cachedMousePress_ and hovered then
        dbg_btnReturnTrue_ = dbg_btnReturnTrue_ + 1
        dbg_lastAction_ = "BTN:" .. label
        dbg_lastActionTime_ = os.clock()
        return true
    end
    return false
end

-- ============================================================================
-- FPS 显示
-- ============================================================================

function HUD.DrawFpsHud()
    if not debugVisible_ then return end

    fpsRenderFrames_ = fpsRenderFrames_ + 1
    local now = time:GetElapsedTime()
    if fpsLastSample_ < 0 then fpsLastSample_ = now end
    local elapsed = now - fpsLastSample_
    if elapsed >= 1.0 then
        fpsRenderValue_ = math.floor(fpsRenderFrames_ / elapsed + 0.5)
        local measured = _G.NetSendFps
        if measured and measured > 0 then
            fpsNetValue_ = math.floor(measured + 0.5)
        elseif network and network.GetUpdateFps then
            fpsNetValue_ = network:GetUpdateFps()
        else
            fpsNetValue_ = 0
        end
        fpsRenderFrames_ = 0
        fpsLastSample_ = now
    end

    nvgSave(vg_)
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)

    local pad = 8
    local lineH = 16
    local boxW = 130
    local boxH = lineH * 2 + pad * 2
    local boxX = logW_ - boxW - 8
    local boxY = logH_ - boxH - 8

    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, boxX, boxY, boxW, boxH, 4)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
    nvgFill(vg_)

    local rR, rG, rB = 120, 255, 120
    if fpsRenderValue_ < 30 then rR, rG, rB = 255, 80, 80
    elseif fpsRenderValue_ < 50 then rR, rG, rB = 255, 220, 80 end
    nvgFillColor(vg_, nvgRGBA(rR, rG, rB, 255))
    nvgText(vg_, boxX + boxW - pad, boxY + pad + lineH, "Render: " .. fpsRenderValue_ .. " fps")

    local nR, nG, nB = 120, 255, 255
    if fpsNetValue_ < 20 then nR, nG, nB = 255, 80, 80
    elseif fpsNetValue_ < 45 then nR, nG, nB = 255, 220, 80 end
    nvgFillColor(vg_, nvgRGBA(nR, nG, nB, 255))
    nvgText(vg_, boxX + boxW - pad, boxY + pad + lineH * 2, "Net:    " .. fpsNetValue_ .. " fps")

    nvgRestore(vg_)
end

-- ============================================================================
-- 调试覆盖层
-- ============================================================================

function HUD.DrawDebugOverlay()
    if not debugVisible_ then return end
    nvgSave(vg_)

    nvgBeginPath(vg_)
    nvgRect(vg_, 4, 4, 460, 460)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgFill(vg_)

    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 13)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)

    local dy = 10
    local function line(text, r, g, b)
        nvgFillColor(vg_, nvgRGBA(r or 220, g or 220, b or 220, 255))
        nvgText(vg_, 10, dy, text)
        dy = dy + 15
    end

    line("[DEBUG INFO]", 255, 255, 0)

    local clientMod = _G.ClientModule
    if clientMod then
        local connStr = "NOT CONNECTED"
        local cr, cg = 255, 100
        if clientMod.IsConnected and clientMod.IsConnected() then
            connStr = "CONNECTED"
            cr, cg = 100, 255
        end
        line("Server: " .. connStr, cr, cg, 100)
        line("ClientState: " .. (clientMod.GetState and clientMod.GetState() or "?"), 200, 200, 200)
        line("MySlot: " .. (clientMod.GetMySlot and clientMod.GetMySlot() or "?"), 200, 200, 200)
    else
        line("Mode: Standalone", 200, 200, 200)
    end

    line("BtnReturnTrue: " .. dbg_btnReturnTrue_, 200, 200, 200)

    local actElapsed = os.clock() - dbg_lastActionTime_
    local actColor = actElapsed < 3 and 255 or 150
    line("LastAction: " .. dbg_lastAction_, actColor, actColor, 100)

    -- 玩家列表
    if playerModule_ then
        dy = dy + 5
        line("[PLAYERS " .. #playerModule_.list .. "]", 255, 200, 100)
        for _, p in ipairs(playerModule_.list) do
            local sessionStr = "inactive"
            if p.session and p.session.active then
                sessionStr = string.format("active T=%.0f H=%d K=%d P=%d Total=%d",
                    p.session.timer, p.session.heightScore, p.session.killScore,
                    p.session.pickupScore, p.session.totalScore)
            end
            local posStr = "no node"
            if p.node then
                local pos = p.node.position
                posStr = string.format("(%.1f, %.1f)", pos.x, pos.y)
            end
            local label = (p.isHuman and "H" or "AI") .. p.index
            line(label .. " " .. posStr .. " " .. sessionStr,
                p.alive and 120 or 255, p.alive and 255 or 100, 120)
        end
    end

    -- 网络事件日志
    dy = dy + 4
    line("[NET EVENT LOG]", 255, 180, 0)

    if clientMod and clientMod.GetNetLog then
        local netLog = clientMod.GetNetLog()
        if #netLog == 0 then
            line("  (no events yet)", 150, 150, 150)
        else
            local now = os.clock()
            local startIdx = math.max(1, #netLog - 10)
            for i = #netLog, startIdx, -1 do
                local entry = netLog[i]
                local age = now - entry.time
                local ageStr = string.format("%.1fs", age)
                local logAlpha = age < 30 and 255 or 120
                local r = math.floor(entry.r * logAlpha / 255)
                local g = math.floor(entry.g * logAlpha / 255)
                local b = math.floor(entry.b * logAlpha / 255)
                line("[" .. ageStr .. "] " .. entry.msg, r, g, b)
            end
        end
    end

    -- 点击指示器
    local elapsed = os.clock() - dbg_lastPressTime_
    if dbg_lastPressTime_ > 0 and elapsed < 1.0 then
        nvgBeginPath(vg_)
        nvgRect(vg_, 420, 10, 24, 24)
        nvgFillColor(vg_, nvgRGBA(0, 255, 0, math.floor(255 * (1.0 - elapsed))))
        nvgFill(vg_)
    end

    nvgRestore(vg_)
end

-- ============================================================================
-- FX 诊断面板
-- ============================================================================

function HUD.DrawFXDiagPanel()
    local entries = FXDiag.GetEntries()
    if #entries == 0 then return end

    nvgSave(vg_)

    local panelW = 380
    local lineH = 14
    local pad = 6
    local maxLines = 20
    local startIdx = math.max(1, #entries - maxLines + 1)
    local visibleCount = #entries - startIdx + 1
    local panelH = visibleCount * lineH + pad * 2 + lineH
    local panelX = logW_ - panelW - 8
    local panelY = 8

    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, panelX, panelY, panelW, panelH, 4)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200))
    nvgFill(vg_)

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 13)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 220, 0, 255))
    nvgText(vg_, panelX + pad, panelY + pad, "[FX DIAG] " .. #entries .. " msgs")

    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    local fxDy = panelY + pad + lineH
    local now = os.clock()
    for i = #entries, startIdx, -1 do
        local e = entries[i]
        local age = now - e.time
        local ageStr = string.format("%.1fs", age)
        local fxAlpha = age < 30 and 255 or 100
        local r = math.floor(e.r * fxAlpha / 255)
        local g = math.floor(e.g * fxAlpha / 255)
        local b = math.floor(e.b * fxAlpha / 255)
        nvgFillColor(vg_, nvgRGBA(r, g, b, fxAlpha))
        nvgText(vg_, panelX + pad, fxDy, "[" .. ageStr .. "] " .. e.msg)
        fxDy = fxDy + lineH
    end

    nvgRestore(vg_)
end

return HUD

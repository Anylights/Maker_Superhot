-- ============================================================================
-- HUD.lua - NanoVG 游戏 HUD
-- 显示：能量条、分数、倒计时、回合计时器、状态覆盖层
-- 世界空间指示器：冲刺冷却环、爆炸警告区域
-- 使用 NanoVG Mode B（系统逻辑分辨率）
-- ============================================================================

local Config = require("Config")
local Camera = require("Camera")
local LevelManager = require("LevelManager")

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
local levelEditorRef_ = nil

-- 菜单按钮点击结果（每帧检测后存储，获取后清除）
local menuButtonClicked_ = nil  -- "startGame" | "editor" | nil



-- 标题图片句柄
local titleImage_ = -1
local titleImageW_ = 0
local titleImageH_ = 0

-- 关卡列表状态
local levelListCache_ = {}       -- 缓存的关卡列表
local levelListAction_ = nil     -- 最近一次点击动作 { action="play"|"edit"|"delete"|"new"|"back", filename=... }
local levelListScroll_ = 0       -- 滚动偏移
local testPlayExitClicked_ = false  -- 试玩退出按钮是否被点击
local persistClicked_ = false  -- "保存到工程"按钮是否被点击

-- 关卡列表 toast 系统（独立于联机 toast）
local levelListToast_ = nil     -- toast 消息文本
local levelListToastTimer_ = 0  -- 剩余显示时间

-- 帧缓存：鼠标点击状态（在 Update 阶段缓存，供 NanoVG 渲染阶段的按钮使用）
local cachedMousePress_ = false
local cachedMouseLogX_ = 0
local cachedMouseLogY_ = 0

--- 在 Update 阶段缓存鼠标输入状态（GetMouseButtonPress 在渲染阶段不可靠）
--- 必须由 Client.HandleUpdate / Standalone.HandleUpdate 在每帧开头调用
function HUD.CacheInput()
    cachedMousePress_ = input:GetMouseButtonPress(MOUSEB_LEFT)
    if cachedMousePress_ then
        cachedMouseLogX_ = input.mousePosition.x / dpr_
        cachedMouseLogY_ = input.mousePosition.y / dpr_
    end
    -- G 或 TAB 键切换 AI 寻路可视化
    if input:GetKeyPress(KEY_G) or input:GetKeyPress(KEY_TAB) then
        HUD.aiDebugVisible = not HUD.aiDebugVisible
        print("[HUD] AI debug visualization toggled: " .. tostring(HUD.aiDebugVisible))
    end
end

-- AI 寻路调试可视化开关（G 键切换，默认开启便于调试）
HUD.aiDebugVisible = true

-- 动画
local countdownScale_ = 1.0
local flashAlpha_ = 0

-- 击杀动效系统
local killFloatTexts_ = {}           -- 屏幕中央浮动文字（双杀/三杀等大文字）
local KILL_FLOAT_DURATION = 2.0      -- 浮动文字持续时间（秒）
local lastRenderTime_ = 0            -- 上一帧时间（用于计算 dt）
-- 每个玩家的 "+1" 弹跳动画状态
local killBounceTimers_ = { 0, 0, 0, 0 }  -- 弹跳计时器
local KILL_BOUNCE_DURATION = 0.8           -- +1 弹跳动画时长

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
        -- nvgImageSize 对外部图片可能返回错误值(如16x16)，用实际像素尺寸兜底
        if titleImageW_ <= 16 or titleImageH_ <= 16 then
            titleImageW_ = 1024
            titleImageH_ = 434
        end
        print("[HUD] Title image loaded: " .. titleImageW_ .. "x" .. titleImageH_)
    else
        print("[HUD] Warning: title image not found, fallback to text")
    end

    -- 订阅渲染事件（NanoVG 事件需要以 vg_ 为事件源）
    SubscribeToEvent(vg_, "NanoVGRender", "HandleNanoVGRender")
    SubscribeToEvent("ScreenMode", "HandleScreenMode_HUD")

    print("[HUD] Initialized")
end

--- 设置关卡编辑器引用
---@param editorRef table LevelEditor 模块
function HUD.SetLevelEditor(editorRef)
    levelEditorRef_ = editorRef
end

--- 获取 NanoVG 上下文（供 LevelEditor 共享）
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
---@return string|nil -- "startGame" | "editor" | nil
function HUD.GetMenuButtonClicked()
    local v = menuButtonClicked_
    menuButtonClicked_ = nil
    return v
end

--- 刷新关卡列表缓存
function HUD.RefreshLevelList()
    levelListCache_ = LevelManager.List()
    levelListScroll_ = 0
end

--- 获取关卡列表中最近一次用户动作，获取后自动清除
---@return table|nil -- { action="play"|"edit"|"delete"|"new"|"back", filename=string|nil }
function HUD.GetLevelListAction()
    local a = levelListAction_
    levelListAction_ = nil
    return a
end

--- 检查试玩退出按钮是否被点击（获取后自动清除）
---@return boolean
function HUD.IsTestPlayExitClicked()
    local v = testPlayExitClicked_
    testPlayExitClicked_ = false
    return v
end

--- 检查"保存到工程"按钮是否被点击（获取后自动清除）
---@return boolean
function HUD.IsPersistClicked()
    local v = persistClicked_
    persistClicked_ = false
    return v
end

--- 显示关卡列表 toast
---@param msg string 消息文本
---@param duration number|nil 显示时间（秒），默认 4
function HUD.ShowLevelListToast(msg, duration)
    levelListToast_ = msg
    levelListToastTimer_ = duration or 4.0
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

    -- 注意：鼠标点击状态已在 HUD.CacheInput()（Update 阶段）中缓存
    -- GetMouseButtonPress 在渲染阶段不可靠，不要在此调用

    -- 计算帧间隔（用于浮动文字动画）
    local now = os.clock()
    local renderDt = now - lastRenderTime_
    if renderDt > 0.1 then renderDt = 0.016 end  -- 首帧/异常保护
    lastRenderTime_ = now

    -- 更新浮动文字计时
    HUD.UpdateKillFloats(renderDt)

    nvgBeginFrame(vg_, logW_, logH_, dpr_)

    local state = gameManager_ and gameManager_.state or "racing"

    -- 主菜单
    if state == "menu" then
        HUD.DrawMenu()
        nvgEndFrame(vg_)
        return
    end

    -- 关卡列表
    if state == "levelList" then
        HUD.DrawLevelList()
        nvgEndFrame(vg_)
        return
    end

    -- 关卡编辑器
    if state == "editor" then
        if levelEditorRef_ then
            levelEditorRef_.SetResolution(logW_, logH_)
            levelEditorRef_.Draw()
        end
        nvgEndFrame(vg_)
        return
    end

    -- 开场镜头动画（intro 状态单独处理）
    if state == "intro" then
        HUD.DrawBackground()
        HUD.DrawIntro()
        nvgEndFrame(vg_)
        return
    end

    -- 温暖渐变背景（所有游戏状态共用）
    HUD.DrawBackground()

    -- 世界空间指示器（在 HUD 元素下面绘制）
    if state == "racing" then
        HUD.DrawWorldIndicators()
        HUD.DrawAIDebug()
    end

    HUD.DrawEnergyBars()
    HUD.DrawScores()

    if state == "racing" then
        HUD.DrawRoundTimer()
    end

    HUD.DrawRoundInfo()

    -- 击杀分值面板（比赛进行时显示）
    if state == "racing" or state == "countdown" then
        HUD.DrawKillScorePanel()
    end

    -- 消费击杀事件 + 绘制浮动文字
    HUD.ConsumeKillEvents()
    HUD.DrawKillFloatTexts()

    -- 试玩模式下绘制退出按钮
    if gameManager_ and gameManager_.testPlayMode then
        HUD.DrawTestPlayExitButton()
    end

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
-- 渐变背景
-- ============================================================================

--- 绘制半透明山丘剪影（叠加在 3D 渐变背景之上）
--- 注意：不画不透明填充！渐变由 3D 背景面片提供，NanoVG 只叠加装饰
function HUD.DrawBackground()
    -- 简约山丘剪影（远景层，半透明）
    local t = (os.clock() or 0) * 0.02  -- 极慢平移视差
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

-- ============================================================================
-- AI 寻路调试可视化（F2 切换）
-- ============================================================================

--- 玩家颜色（用于区分 AI 路径）
local AI_DEBUG_COLORS = {
    { 0.30, 0.70, 1.00 },  -- P1 蓝
    { 1.00, 0.40, 0.40 },  -- P2 红
    { 0.40, 0.95, 0.50 },  -- P3 绿
    { 1.00, 0.85, 0.30 },  -- P4 黄
}

--- 绘制 AI 寻路可视化：每个 AI 一条粗折线，从当前位置连接到所有未访问的路径目标
local _aiDbgFrameCount_ = 0
function HUD.DrawAIDebug()
    if not HUD.aiDebugVisible then return end

    local AIController = package.loaded["AIController"]
    _aiDbgFrameCount_ = _aiDbgFrameCount_ + 1
    if _aiDbgFrameCount_ % 120 == 1 then
        local hasMod = AIController ~= nil
        local hasFn = AIController and AIController.GetDebugInfo ~= nil
        local hasPM = playerModule_ ~= nil
        print(string.format("[AIDbg] frame=%d AIController=%s GetDebugInfo=%s playerModule=%s",
            _aiDbgFrameCount_, tostring(hasMod), tostring(hasFn), tostring(hasPM)))
    end
    if not AIController or not AIController.GetDebugInfo then return end
    if not playerModule_ then return end

    local debugList = AIController.GetDebugInfo()
    if _aiDbgFrameCount_ % 120 == 1 then
        print(string.format("[AIDbg] debugList count=%d", #debugList))
        for i, info in ipairs(debugList) do
            print(string.format("  [%d] playerIdx=%s pathLen=%s pathIdx=%s",
                i, tostring(info.playerIdx), tostring(info.path and #info.path or "nil"),
                tostring(info.pathIdx)))
        end
    end

    for _, info in ipairs(debugList) do
        local idx = info.playerIdx or 1
        local col = AI_DEBUG_COLORS[idx] or { 1, 1, 1 }
        local r, g, b = col[1] * 255, col[2] * 255, col[3] * 255

        -- 取 AI 当前位置作为起点
        local p = playerModule_.list[idx]
        if p and p.node and info.path and #info.path > 0 then
            local pos = p.node.position
            local startSX, startSY = Camera.WorldToScreen(pos.x, pos.y, logW_, logH_)

            -- 收集折线点：当前位置 → 路径上 pathIdx 之后的所有目标平台
            local points = { { x = startSX, y = startSY } }
            local startIdx = math.max(1, info.pathIdx or 1)
            for i = startIdx, #info.path do
                local pt = info.path[i]
                local sx, sy = Camera.WorldToScreen(pt.x, pt.y, logW_, logH_)
                table.insert(points, { x = sx, y = sy })
            end

            if #points >= 2 then
                -- 黑色描边（增强可见度）
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

                -- 每个目标节点画大圆点 + 序号
                for i = 2, #points do
                    local pt = points[i]
                    -- 黑色描边圆
                    nvgBeginPath(vg_)
                    nvgCircle(vg_, pt.x, pt.y, 12)
                    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 220))
                    nvgFill(vg_)
                    -- 玩家颜色填充
                    nvgBeginPath(vg_)
                    nvgCircle(vg_, pt.x, pt.y, 9)
                    nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
                    nvgFill(vg_)
                    -- 序号
                    nvgFontFace(vg_, "sans")
                    nvgFontSize(vg_, 13)
                    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
                    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                    nvgText(vg_, pt.x, pt.y, tostring(i - 1))
                end

                -- 起点（AI 当前位置）画一个空心圆环标记
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
    nvgText(vg_, 13, 13, "[F2] AI 寻路可视化 ON  (折线=A* 路径，数字=步骤顺序，圆环=AI 当前位置)")
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    nvgText(vg_, 12, 12, "[F2] AI 寻路可视化 ON  (折线=A* 路径，数字=步骤顺序，圆环=AI 当前位置)")
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

            -- ----- 蓄力警告区域（大小随 chargeProgress 动态变化，颜色跟随玩家） -----
            if p.charging then
                local sx, sy = Camera.WorldToScreen(pos.x, pos.y, logW_, logH_)
                local maxWorldRadius = Config.ExplosionRadius * Config.BlockSize
                local currentWorldRadius = maxWorldRadius * p.chargeProgress
                local screenRadius = Camera.WorldSizeToScreen(currentWorldRadius, logH_)

                -- 玩家颜色
                local pc = Config.PlayerColors[p.index]
                local pr = math.floor(pc.r * 255)
                local pg = math.floor(pc.g * 255)
                local pb = math.floor(pc.b * 255)

                -- 闪烁频率随蓄力进度加快
                local freq = 4 + p.chargeProgress * 12
                local pulse = math.abs(math.sin(os.clock() * freq)) * 0.4 + 0.2

                -- 半透明玩家色填充（30%~50%不透明度，随脉冲闪烁）
                local fillAlpha = math.floor(52 + pulse * 127)  -- 77~128 (≈30%~50%)
                nvgBeginPath(vg_)
                nvgCircle(vg_, sx, sy, screenRadius)
                nvgFillColor(vg_, nvgRGBA(pr, pg, pb, fillAlpha))
                nvgFill(vg_)

                -- 玩家色虚线描边
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

        -- 世界坐标转屏幕坐标（角色头顶上方）
        local headY = pos.y + 0.75
        local sx, sy = Camera.WorldToScreen(pos.x, headY, logW_, logH_)

        -- 进度条尺寸基于世界空间，自适应缩放
        local barWorldW = 1.1  -- 世界单位宽度（略大于1个方块）
        local barW = Camera.WorldSizeToScreen(barWorldW, logH_)
        if barW < 24 then barW = 24 end
        local barH = math.max(5, math.min(10, barW * 0.14))
        local cornerR = barH * 0.4
        local bx = sx - barW * 0.5
        local by = sy - barH - 2

        -- 背景（深色半透明）
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
                -- 充满闪烁（危险红）
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

        -- 已完成标记
        if p.finished then
            nvgFontFace(vg_, "bold")
            nvgFontSize(vg_, math.max(10, barH * 2.5))
            nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
            nvgFillColor(vg_, nvgRGBA(50, 255, 80, 255))
            nvgText(vg_, sx, by - 2, "#" .. p.finishOrder)
        end

        ::continueBar::
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

--- 绘制回合信息（顶部中央偏下）
function HUD.DrawRoundInfo()
    if gameManager_ == nil then return end

    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(120, 90, 70, 200))

    local roundText = "ROUND " .. gameManager_.round
    nvgText(vg_, logW_ * 0.5, 46, roundText)
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

        -- 触发该玩家的 "+1" 弹跳
        killBounceTimers_[killerIdx] = KILL_BOUNCE_DURATION

        -- 玩家颜色
        local pc = Config.PlayerColors[killerIdx]
        local cr = math.floor(pc.r * 255)
        local cg = math.floor(pc.g * 255)
        local cb = math.floor(pc.b * 255)

        -- 双杀及以上 → 屏幕中央大字动效
        if multiKill >= 2 then
            local mainText = Config.MultiKillTexts[multiKill] or Config.MultiKillTexts[5]
            if multiKill > 5 then mainText = Config.MultiKillTexts[5] end
            table.insert(killFloatTexts_, {
                text = mainText,
                r = cr, g = cg, b = cb,
                timer = KILL_FLOAT_DURATION,
                duration = KILL_FLOAT_DURATION,
                kind = "multi",  -- 类型标记
            })
        end

        -- 连杀 ≥3 → 额外大字
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

    -- 清空事件队列
    gameManager_.killEvents = {}
end

--- 更新动效计时器
---@param dt number
function HUD.UpdateKillFloats(dt)
    -- 更新浮动文字
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

    -- 更新 +1 弹跳计时
    for p = 1, Config.NumPlayers do
        if killBounceTimers_[p] > 0 then
            killBounceTimers_[p] = killBounceTimers_[p] - dt
            if killBounceTimers_[p] < 0 then killBounceTimers_[p] = 0 end
        end
    end
end

--- 绘制左上角击杀面板
function HUD.DrawKillScorePanel()
    if gameManager_ == nil or playerModule_ == nil then return end

    -- 试玩模式下退出按钮占用左上角，面板下移
    local panelX = 12
    local panelY = 12
    if gameManager_.testPlayMode then
        panelY = 60
    end

    local lineH = 24
    local headerH = 22
    local panelW = 130

    -- 半透明背景
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

        local kills = gameManager_.killScores[i] or 0

        -- 玩家色块
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, panelX, y + 4, 10, 10, 2)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgFill(vg_)

        -- 击杀数
        local bounceT = killBounceTimers_[i]
        local isAnimating = bounceT > 0

        -- 击杀数字：有弹跳时放大
        local numScale = 1.0
        if isAnimating then
            local bp = 1.0 - (bounceT / KILL_BOUNCE_DURATION)  -- 0→1
            -- 弹性缓动：先急速放大到1.6x，再弹回，带两次反弹
            local elastic = 1.0 + math.sin(bp * math.pi * 3) * math.exp(-bp * 4) * 0.6
            numScale = elastic
        end

        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

        -- 基础文字 "P1 击杀"
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 14)
        local label = "P" .. i
        nvgFillColor(vg_, nvgRGBA(r, g, b, 220))
        nvgText(vg_, panelX + 14, y + 10, label)

        -- 击杀数字（带弹跳缩放）
        local numX = panelX + 38
        local numY = y + 10
        local numSize = math.floor(16 * numScale)
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, numSize)
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

        -- 数字上下抖动偏移
        local shakeY = 0
        if isAnimating then
            local bp = 1.0 - (bounceT / KILL_BOUNCE_DURATION)
            shakeY = math.sin(bp * math.pi * 5) * math.exp(-bp * 3) * 4
        end

        -- 阴影
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 160))
        nvgText(vg_, numX + 1, numY + 1 - shakeY, tostring(kills))
        -- 数字
        if isAnimating then
            -- 动画中用更亮的颜色
            nvgFillColor(vg_, nvgRGBA(math.min(255, r + 60), math.min(255, g + 60), math.min(255, b + 60), 255))
        else
            nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        end
        nvgText(vg_, numX, numY - shakeY, tostring(kills))

        -- "+1" 浮出动画
        if isAnimating then
            local bp = 1.0 - (bounceT / KILL_BOUNCE_DURATION)  -- 0→1
            -- 快速淡入，慢淡出
            local plusAlpha
            if bp < 0.1 then
                plusAlpha = bp / 0.1
            elseif bp > 0.5 then
                plusAlpha = (1.0 - bp) / 0.5
            else
                plusAlpha = 1.0
            end
            plusAlpha = math.max(0, math.min(1, plusAlpha))

            -- 向右上方飘出
            local plusOffX = bp * 25
            local plusOffY = -bp * 18
            -- 初始弹跳放大
            local plusScale = 1.0
            if bp < 0.2 then
                plusScale = 1.0 + (1.0 - bp / 0.2) * 0.8  -- 1.8x→1x
            end

            local plusSize = math.floor(18 * plusScale)
            nvgFontFace(vg_, "bold")
            nvgFontSize(vg_, plusSize)
            nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

            -- 发光
            nvgFillColor(vg_, nvgRGBA(255, 255, 100, math.floor(plusAlpha * 80)))
            nvgText(vg_, numX + 22 + plusOffX + 1, numY + plusOffY + 1, "+1")
            -- 主文字
            nvgFillColor(vg_, nvgRGBA(255, 255, 80, math.floor(plusAlpha * 255)))
            nvgText(vg_, numX + 22 + plusOffX, numY + plusOffY, "+1")
        end
    end
end

--- 绘制屏幕中央击杀浮动大字（双杀/三杀/连杀等）
function HUD.DrawKillFloatTexts()
    local cx = logW_ * 0.5
    local baseY = logH_ * 0.35

    -- 从上往下堆叠多条消息
    local slot = 0
    for _, ft in ipairs(killFloatTexts_) do
        local progress = 1.0 - (ft.timer / ft.duration)  -- 0→1

        -- 淡入淡出
        local alpha
        if progress < 0.08 then
            alpha = progress / 0.08
        elseif progress > 0.55 then
            alpha = (1.0 - progress) / 0.45
        else
            alpha = 1.0
        end
        alpha = math.max(0, math.min(1, alpha))

        -- 弹性缩放：入场弹大→稳定→出场缩小
        local scale
        if progress < 0.15 then
            -- 入场：从 2.0x 弹性回到 1.0x
            local t = progress / 0.15
            scale = 2.0 - t * 1.0 + math.sin(t * math.pi * 2) * (1.0 - t) * 0.3
        elseif progress > 0.7 then
            -- 出场缩小
            local t = (progress - 0.7) / 0.3
            scale = 1.0 - t * 0.3
        else
            scale = 1.0
        end

        -- 抖动（入场时强烈，逐渐平息）
        local shakeX, shakeY = 0, 0
        if progress < 0.3 then
            local intensity = (1.0 - progress / 0.3) * 3
            shakeX = math.sin(progress * 80) * intensity
            shakeY = math.cos(progress * 60) * intensity * 0.7
        end

        local y = baseY + slot * 50

        -- 字号
        local baseFontSize = 36
        if ft.kind == "streak" then baseFontSize = 30 end
        local fontSize = math.floor(baseFontSize * scale)

        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, fontSize)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        local drawX = cx + shakeX
        local drawY = y + shakeY

        -- 多层发光
        local glowA = math.floor(alpha * 60)
        nvgFillColor(vg_, nvgRGBA(ft.r, ft.g, ft.b, glowA))
        nvgText(vg_, drawX, drawY + 3, ft.text)
        nvgText(vg_, drawX, drawY - 3, ft.text)
        nvgText(vg_, drawX + 3, drawY, ft.text)
        nvgText(vg_, drawX - 3, drawY, ft.text)

        -- 黑色描边
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 200)))
        nvgText(vg_, drawX + 2, drawY + 2, ft.text)

        -- 主文字
        nvgFillColor(vg_, nvgRGBA(ft.r, ft.g, ft.b, math.floor(alpha * 255)))
        nvgText(vg_, drawX, drawY, ft.text)

        -- 白色高光（上半部分）
        local hlA = math.floor(alpha * 60)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, hlA))
        nvgText(vg_, drawX, drawY - 1, ft.text)

        slot = slot + 1
    end
end

-- ============================================================================
-- 状态覆盖层
-- ============================================================================

--- 开场镜头动画覆盖层
function HUD.DrawIntro()
    if gameManager_ == nil then return end

    local phase = gameManager_.GetIntroPhase()
    local textAlpha = gameManager_.GetIntroTextAlpha()

    -- 半透明暗角（轻微，不遮挡地图观看）
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(20, 12, 8, 60))
    nvgFill(vg_)

    -- 阶段 1：聚焦终点 → 显示 "终点" 提示
    if phase == 1 then
        -- 底部居中提示标签
        local labelAlpha = 220
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 28)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        -- 阴影
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
        nvgText(vg_, logW_ * 0.5 + 2, logH_ * 0.82 + 2, "终点")

        -- 金色文字
        nvgFillColor(vg_, nvgRGBA(255, 200, 50, labelAlpha))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.82, "终点")

        -- 小箭头指示（向上三角）
        local arrowX = logW_ * 0.5
        local arrowY = logH_ * 0.77
        local arrowSize = 8
        nvgBeginPath(vg_)
        nvgMoveTo(vg_, arrowX, arrowY - arrowSize)
        nvgLineTo(vg_, arrowX - arrowSize, arrowY + arrowSize * 0.5)
        nvgLineTo(vg_, arrowX + arrowSize, arrowY + arrowSize * 0.5)
        nvgClosePath(vg_)
        nvgFillColor(vg_, nvgRGBA(255, 200, 50, 180))
        nvgFill(vg_)
    end

    -- 阶段 2：平移到起点 → 显示 "起点" 提示
    if phase == 2 then
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 28)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
        nvgText(vg_, logW_ * 0.5 + 2, logH_ * 0.82 + 2, "起点")

        nvgFillColor(vg_, nvgRGBA(100, 255, 120, 220))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.82, "起点")
    end

    -- 阶段 3/4：放大 + 显示 "更快到达终点!" 文字（阶段4拉远时淡出）
    if phase >= 3 and textAlpha > 0.01 then
        local alpha = math.floor(textAlpha * 255)

        -- 大号主题文字（居中）
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 52)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        -- 发光效果（模糊阴影）
        local glowAlpha = math.floor(textAlpha * 80)
        nvgFillColor(vg_, nvgRGBA(255, 100, 30, glowAlpha))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.45 + 3, "更快到达终点!")
        nvgText(vg_, logW_ * 0.5, logH_ * 0.45 - 3, "更快到达终点!")

        -- 阴影
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(textAlpha * 180)))
        nvgText(vg_, logW_ * 0.5 + 3, logH_ * 0.45 + 3, "更快到达终点!")

        -- 主文字（火红色）
        nvgFillColor(vg_, nvgRGBA(255, 90, 40, alpha))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.45, "更快到达终点!")

        -- 副标题
        nvgFontSize(vg_, 20)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, math.floor(textAlpha * 180)))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.55, "ROUND " .. (gameManager_.round or 1))
    end
end

--- 倒计时覆盖层
function HUD.DrawCountdown()
    if gameManager_ == nil then return end

    -- 半透明暖色背景
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(40, 25, 15, 100))
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
    nvgFillColor(vg_, nvgRGBA(220, 200, 170, 200))
    nvgText(vg_, logW_ * 0.5, logH_ * 0.5 + 80, "Get Ready!")
end

--- 回合结束覆盖层
function HUD.DrawRoundEnd()
    if gameManager_ == nil then return end

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(40, 25, 15, 140))
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
    nvgFillColor(vg_, nvgRGBA(35, 22, 15, 215))
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

        -- 背景条（暖棕）
        local bx = logW_ * 0.5 - barMaxW * 0.5
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, y, barMaxW, barH, 4)
        nvgFillColor(vg_, nvgRGBA(55, 40, 30, 190))
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
    nvgFillColor(vg_, nvgRGBA(180, 160, 140, 180))
    nvgText(vg_, logW_ * 0.5, logH_ - 30, "Next round starting soon...")
end

--- 比赛结束覆盖层
function HUD.DrawMatchEnd()
    if gameManager_ == nil then return end

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(30, 18, 10, 225))
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
    nvgFillColor(vg_, nvgRGBA(180, 160, 140, 180))
    nvgText(vg_, logW_ * 0.5, logH_ - 30, "New match starting soon...")
end

--- 绘制橡胶材质按钮（5 层 NanoVG 效果）
---@param x number 左上角 X
---@param y number 左上角 Y
---@param w number 宽度
---@param h number 高度
---@param label string 按钮文字
---@param baseR number 基色 R (0-255)
---@param baseG number 基色 G (0-255)
---@param baseB number 基色 B (0-255)
---@param hovered boolean 鼠标悬停
---@return boolean clicked 是否被点击
function HUD.DrawRubberButton(x, y, w, h, label, baseR, baseG, baseB, hovered)
    local cornerR = h * 0.35

    -- 1) 阴影
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x + 2, y + 4, w, h, cornerR)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, hovered and 100 or 70))
    nvgFill(vg_)

    -- 2) 基色填充（悬停时稍亮）
    local br = hovered and math.min(255, baseR + 30) or baseR
    local bg = hovered and math.min(255, baseG + 30) or baseG
    local bb = hovered and math.min(255, baseB + 30) or baseB
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillColor(vg_, nvgRGBA(br, bg, bb, 255))
    nvgFill(vg_)

    -- 3) 底部暗色渐变（橡胶深度感）
    local darkPaint = nvgLinearGradient(vg_, x, y + h * 0.6, x, y + h,
        nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 0, 0, 80))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillPaint(vg_, darkPaint)
    nvgFill(vg_)

    -- 4) 顶部高光（橡胶光泽）
    local glossPaint = nvgLinearGradient(vg_, x, y, x, y + h * 0.45,
        nvgRGBA(255, 255, 255, hovered and 110 or 80), nvgRGBA(255, 255, 255, 0))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillPaint(vg_, glossPaint)
    nvgFill(vg_)

    -- 5) 边框描边
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

    -- 点击检测（使用帧缓存的鼠标状态）
    if cachedMousePress_ and hovered then
        return true
    end
    return false
end

--- 主菜单界面
function HUD.DrawMenu()

    -- 全屏背景渐变（暖色日落）
    local bgPaint = nvgLinearGradient(vg_, 0, 0, logW_, logH_,
        nvgRGBA(250, 217, 179, 255), nvgRGBA(224, 166, 153, 255))
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
        nvgFillColor(vg_, nvgRGBA(255, 255, 220, math.floor(alpha)))
        nvgFill(vg_)
    end

    local cx = logW_ * 0.5
    local cy = logH_ * 0.38  -- 标题偏上

    -- ======== 标题图片 ========
    -- titleBottom 记录标题区域底部 Y 坐标，用于后续元素布局
    local titleBottom = cy + 40  -- 默认值（文字降级时使用）

    if titleImage_ > 0 and titleImageW_ > 0 then
        -- 按宽度等比缩放，不超过屏幕宽度 55%
        local maxW = logW_ * 0.55
        local imgScale = maxW / titleImageW_
        local drawW = titleImageW_ * imgScale
        local drawH = titleImageH_ * imgScale
        local imgX = cx - drawW * 0.5
        local imgY = cy - drawH * 0.5

        -- 轻微浮动动画
        local floatY = math.sin(t * 1.2) * 4
        imgY = imgY + floatY

        -- 发光底衬
        local glowA = math.floor(math.abs(math.sin(t * 1.5)) * 30 + 20)
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, imgX - 10, imgY - 6, drawW + 20, drawH + 12, 16)
        nvgFillColor(vg_, nvgRGBA(255, 80, 40, glowA))
        nvgFill(vg_)

        -- 绘制图片
        local imgPaint = nvgImagePattern(vg_, imgX, imgY, drawW, drawH, 0, titleImage_, 1.0)
        nvgBeginPath(vg_)
        nvgRect(vg_, imgX, imgY, drawW, drawH)
        nvgFillPaint(vg_, imgPaint)
        nvgFill(vg_)

        titleBottom = imgY + drawH
    else
        -- 降级：文字标题
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 72)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
        nvgText(vg_, cx + 3, cy + 3, Config.Title)
        nvgFillColor(vg_, nvgRGBA(255, 90, 40, 255))
        nvgText(vg_, cx, cy, Config.Title)
    end

    -- ======== 副标题 ========
    local subtitleY = titleBottom + 14
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(220, 200, 180, 180))
    nvgText(vg_, cx, subtitleY, "2.5D 平台竞速派对")

    -- ======== 橡胶按钮（横向排列） ========
    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    local btnW = 140
    local btnH = 52
    local btnGap = 14
    local btnY = subtitleY + 24

    local buttons = {
        { label = "开始游戏",   r = 242, g = 56, b = 46,  id = "startGame" },    -- 番茄红
        { label = "关卡编辑器", r = 51,  g = 122, b = 242, id = "editor" },       -- 宝蓝
    }

    local totalW = btnW * #buttons + btnGap * (#buttons - 1)
    local btnStartX = cx - totalW * 0.5

    for idx, btn in ipairs(buttons) do
        local bx = btnStartX + (idx - 1) * (btnW + btnGap)
        local hovered = mx >= bx and mx <= bx + btnW and my >= btnY and my <= btnY + btnH
        local clicked = HUD.DrawRubberButton(bx, btnY, btnW, btnH, btn.label, btn.r, btn.g, btn.b, hovered)
        if clicked then
            menuButtonClicked_ = btn.id
        end
    end

    -- ======== 底部玩家颜色指示 ========
    local dotY = btnY + btnH + 30
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
        nvgFillColor(vg_, nvgRGBA(100, 70, 50, 200))
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        local label = i == 1 and "P1 你" or ("P" .. i)
        nvgText(vg_, dx, dotY + 12, label)
    end

    -- ======== 操作说明（紧凑版） ========
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(120, 90, 70, 160))
    nvgText(vg_, cx, logH_ - 10, "A/D:移动  空格:跳跃  Shift:冲刺  鼠标左键:蓄力爆炸")
end



-- ============================================================================
-- 关卡列表 UI
-- ============================================================================

--- 绘制关卡列表界面
function HUD.DrawLevelList()
    -- 全屏背景（与主菜单统一）
    local bgPaint = nvgLinearGradient(vg_, 0, 0, logW_, logH_,
        nvgRGBA(250, 217, 179, 255), nvgRGBA(224, 166, 153, 255))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillPaint(vg_, bgPaint)
    nvgFill(vg_)

    local cx = logW_ * 0.5

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 36)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(180, 100, 30, 255))
    nvgText(vg_, cx, 40, "关卡编辑器")

    -- 关卡数量提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgFillColor(vg_, nvgRGBA(120, 90, 70, 200))
    nvgText(vg_, cx, 65, "共 " .. #levelListCache_ .. " 个关卡")

    -- 列表区域
    local listX = cx - 200
    local listW = 400
    local listY = 85
    local itemH = 50
    local itemGap = 6
    local listMaxH = logH_ - 150  -- 留出底部按钮空间

    -- 列表背景
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, listX - 10, listY - 5, listW + 20, listMaxH + 10, 8)
    nvgFillColor(vg_, nvgRGBA(60, 40, 30, 140))
    nvgFill(vg_)

    -- 滚轮控制滚动
    local wheel = input:GetMouseMoveWheel()
    if wheel ~= 0 then
        levelListScroll_ = levelListScroll_ - wheel * 40
        local maxScroll = math.max(0, #levelListCache_ * (itemH + itemGap) - listMaxH)
        levelListScroll_ = math.max(0, math.min(maxScroll, levelListScroll_))
    end

    -- 裁剪区域（NanoVG scissor）
    nvgSave(vg_)
    nvgScissor(vg_, listX - 10, listY - 5, listW + 20, listMaxH + 10)

    -- 绘制关卡项
    local btnW = 50
    local btnH = 28
    local btnGap = 6

    for i, entry in ipairs(levelListCache_) do
        local iy = listY + (i - 1) * (itemH + itemGap) - levelListScroll_

        -- 跳过不可见项
        if iy + itemH < listY - 5 or iy > listY + listMaxH + 5 then
            goto continueItem
        end

        -- 项背景
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, listX, iy, listW, itemH, 6)
        nvgFillColor(vg_, nvgRGBA(50, 35, 25, 180))
        nvgFill(vg_)

        -- 关卡名称
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 16)
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(240, 230, 220, 240))
        nvgText(vg_, listX + 12, iy + itemH * 0.5, entry.name or entry.filename)

        -- 文件名（小字）
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 11)
        nvgFillColor(vg_, nvgRGBA(160, 140, 120, 150))
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgText(vg_, listX + 12, iy + itemH * 0.5 + 14, entry.filename)

        -- 操作按钮（从右到左：删除、修改、试玩）
        local bx = listX + listW - 12
        local by = iy + (itemH - btnH) * 0.5

        -- 鼠标逻辑坐标（使用帧缓存）
        local mx = cachedMousePress_ and cachedMouseLogX_ or (input.mousePosition.x / dpr_)
        local my = cachedMousePress_ and cachedMouseLogY_ or (input.mousePosition.y / dpr_)
        local clicked = cachedMousePress_

        -- 删除按钮
        bx = bx - btnW
        local delHover = mx >= bx and mx <= bx + btnW and my >= by and my <= by + btnH
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, btnW, btnH, 4)
        nvgFillColor(vg_, delHover and nvgRGBA(180, 50, 40, 200) or nvgRGBA(120, 40, 30, 160))
        nvgFill(vg_)
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(255, 220, 200, delHover and 255 or 200))
        nvgText(vg_, bx + btnW * 0.5, by + btnH * 0.5, "删除")
        if clicked and delHover then
            levelListAction_ = { action = "delete", filename = entry.filename }
        end

        -- 修改按钮
        bx = bx - btnW - btnGap
        local editHover = mx >= bx and mx <= bx + btnW and my >= by and my <= by + btnH
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, btnW, btnH, 4)
        nvgFillColor(vg_, editHover and nvgRGBA(80, 120, 60, 200) or nvgRGBA(60, 90, 45, 160))
        nvgFill(vg_)
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(220, 255, 200, editHover and 255 or 200))
        nvgText(vg_, bx + btnW * 0.5, by + btnH * 0.5, "修改")
        if clicked and editHover then
            levelListAction_ = { action = "edit", filename = entry.filename }
        end

        -- 试玩按钮
        bx = bx - btnW - btnGap
        local playHover = mx >= bx and mx <= bx + btnW and my >= by and my <= by + btnH
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, btnW, btnH, 4)
        nvgFillColor(vg_, playHover and nvgRGBA(60, 100, 160, 200) or nvgRGBA(40, 70, 120, 160))
        nvgFill(vg_)
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(200, 220, 255, playHover and 255 or 200))
        nvgText(vg_, bx + btnW * 0.5, by + btnH * 0.5, "试玩")
        if clicked and playHover then
            levelListAction_ = { action = "play", filename = entry.filename }
        end

        ::continueItem::
    end

    -- 空列表提示
    if #levelListCache_ == 0 then
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 18)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(200, 190, 180, 200))
        nvgText(vg_, cx, listY + listMaxH * 0.4, "还没有保存的关卡")
        nvgFontSize(vg_, 14)
        nvgText(vg_, cx, listY + listMaxH * 0.4 + 28, "点击下方\"新建关卡\"开始创作！")
    end

    nvgRestore(vg_)  -- 恢复裁剪

    -- 底部按钮栏（3个按钮）
    local bottomY = logH_ - 55
    local bbtnW = 120
    local bbtnH = 36
    local bbtnGap = 14
    local totalBtnW = bbtnW * 3 + bbtnGap * 2
    local btnStartX = cx - totalBtnW * 0.5

    -- 鼠标逻辑坐标（使用帧缓存）
    local mx = cachedMousePress_ and cachedMouseLogX_ or (input.mousePosition.x / dpr_)
    local my = cachedMousePress_ and cachedMouseLogY_ or (input.mousePosition.y / dpr_)
    local clicked = cachedMousePress_

    -- "新建关卡" 按钮
    local newX = btnStartX
    local newHover = mx >= newX and mx <= newX + bbtnW and my >= bottomY and my <= bottomY + bbtnH
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, newX, bottomY, bbtnW, bbtnH, 8)
    nvgFillColor(vg_, newHover and nvgRGBA(80, 140, 60, 220) or nvgRGBA(55, 100, 40, 180))
    nvgFill(vg_)
    nvgStrokeColor(vg_, nvgRGBA(120, 200, 80, newHover and 180 or 100))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(220, 255, 200, newHover and 255 or 220))
    nvgText(vg_, newX + bbtnW * 0.5, bottomY + bbtnH * 0.5, "新建关卡")
    if clicked and newHover then
        levelListAction_ = { action = "new" }
    end

    -- "保存到工程" 按钮（金色醒目）
    local persistX = btnStartX + bbtnW + bbtnGap
    local persistHover = mx >= persistX and mx <= persistX + bbtnW and my >= bottomY and my <= bottomY + bbtnH
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, persistX, bottomY, bbtnW, bbtnH, 8)
    nvgFillColor(vg_, persistHover and nvgRGBA(160, 120, 30, 230) or nvgRGBA(120, 90, 20, 190))
    nvgFill(vg_)
    nvgStrokeColor(vg_, nvgRGBA(255, 210, 80, persistHover and 200 or 120))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 15)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 240, 180, persistHover and 255 or 220))
    nvgText(vg_, persistX + bbtnW * 0.5, bottomY + bbtnH * 0.5, "保存到工程")
    if clicked and persistHover then
        persistClicked_ = true
    end

    -- "返回菜单" 按钮
    local backX = btnStartX + (bbtnW + bbtnGap) * 2
    local backHover = mx >= backX and mx <= backX + bbtnW and my >= bottomY and my <= bottomY + bbtnH
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, backX, bottomY, bbtnW, bbtnH, 8)
    nvgFillColor(vg_, backHover and nvgRGBA(80, 60, 45, 220) or nvgRGBA(55, 38, 25, 180))
    nvgFill(vg_)
    nvgStrokeColor(vg_, nvgRGBA(180, 150, 110, backHover and 150 or 80))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(240, 220, 190, backHover and 255 or 200))
    nvgText(vg_, backX + bbtnW * 0.5, bottomY + bbtnH * 0.5, "返回菜单")
    if clicked and backHover then
        levelListAction_ = { action = "back" }
    end

    -- ESC 快捷键返回
    if input:GetKeyPress(KEY_ESCAPE) then
        levelListAction_ = { action = "back" }
    end

    -- Toast 提示（屏幕上方居中，自动消失）
    if levelListToast_ and levelListToastTimer_ > 0 then
        local now = os.clock()
        -- 用渲染帧间隔近似 dt
        local renderDt = now - lastRenderTime_
        if renderDt > 0.1 then renderDt = 0.016 end
        levelListToastTimer_ = levelListToastTimer_ - renderDt
        if levelListToastTimer_ <= 0 then
            levelListToast_ = nil
        else
            local alpha = math.min(1.0, levelListToastTimer_) * 255
            -- 支持多行：按 \n 分割
            local lines = {}
            for line in levelListToast_:gmatch("[^\n]+") do
                table.insert(lines, line)
            end
            local lineH = 22
            local totalH = #lines * lineH + 16
            local maxW = 0
            nvgFontFace(vg_, "bold")
            nvgFontSize(vg_, 16)
            for _, line in ipairs(lines) do
                local tw = nvgTextBounds(vg_, 0, 0, line)
                if tw > maxW then maxW = tw end
            end
            local boxW = maxW + 40
            local boxX = cx - boxW * 0.5
            local boxY = 75
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, boxX, boxY, boxW, totalH, 8)
            nvgFillColor(vg_, nvgRGBA(40, 30, 20, math.floor(alpha * 0.85)))
            nvgFill(vg_)
            nvgStrokeColor(vg_, nvgRGBA(255, 210, 80, math.floor(alpha * 0.6)))
            nvgStrokeWidth(vg_, 1.5)
            nvgStroke(vg_)
            nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg_, nvgRGBA(255, 240, 180, math.floor(alpha)))
            for li, line in ipairs(lines) do
                nvgText(vg_, cx, boxY + 8 + (li - 0.5) * lineH, line)
            end
        end
    end
end

-- ============================================================================
-- 试玩退出按钮
-- ============================================================================

--- 绘制试玩模式退出按钮（左上角）
function HUD.DrawTestPlayExitButton()
    local btnW = 100
    local btnH = 32
    local btnX = 12
    local btnY = 12

    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_
    local hovered = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH

    -- 背景
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, btnX, btnY, btnW, btnH, 6)
    nvgFillColor(vg_, hovered and nvgRGBA(180, 60, 40, 220) or nvgRGBA(120, 40, 30, 180))
    nvgFill(vg_)

    nvgStrokeColor(vg_, nvgRGBA(255, 120, 80, hovered and 200 or 100))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)

    -- 文字
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 230, 210, hovered and 255 or 220))
    nvgText(vg_, btnX + btnW * 0.5, btnY + btnH * 0.5, "退出试玩")

    -- "试玩中" 标签
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 11)
    nvgFillColor(vg_, nvgRGBA(255, 200, 100, 160))
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgText(vg_, btnX, btnY + btnH + 4, "试玩模式")

    -- 点击检测（使用帧缓存的鼠标状态）
    if cachedMousePress_ and hovered then
        testPlayExitClicked_ = true
    end
end

return HUD

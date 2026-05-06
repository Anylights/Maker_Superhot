-- ============================================================================
-- HUD.lua - NanoVG 游戏 HUD
-- 显示：能量条、分数、倒计时、回合计时器、状态覆盖层
-- 世界空间指示器：冲刺冷却环、爆炸警告区域
-- 使用 NanoVG Mode B（系统逻辑分辨率）
-- ============================================================================

local Config = require("Config")
local Camera = require("Camera")
local LevelManager = require("LevelManager")
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

-- 帧缓存：鼠标点击状态（在 Update 阶段缓存，供 NanoVG 渲染阶段的按钮使用）
local cachedMousePress_ = false
local cachedMouseLogX_ = 0
local cachedMouseLogY_ = 0
local prevMouseDown_ = false   -- 上一帧鼠标左键是否按下
local cacheInputCalledThisFrame_ = false  -- 本帧是否已调用 CacheInput

-- 调试变量（画面可视化用）
local dbg_cacheInputCount_ = 0       -- CacheInput 总调用次数
local dbg_cacheInputMissed_ = 0      -- 渲染阶段补调次数（说明 Update 没调到）
local dbg_lastPressTime_ = 0         -- 上次检测到 press 的时间
local dbg_mouseDownRaw_ = false      -- GetMouseButtonDown 原始值
local dbg_lastClickX_ = 0            -- 上次点击 X
local dbg_lastClickY_ = 0            -- 上次点击 Y
local dbg_lastAction_ = "none"       -- 上次触发的动作
local dbg_lastActionTime_ = 0        -- 上次动作时间
local dbg_btnReturnTrue_ = 0         -- DrawRubberButton 返回 true 的次数

-- 帧率监测（每秒采样一次）
local fpsRenderFrames_ = 0
local fpsLastSample_ = -1            -- -1 表示尚未初始化
local fpsRenderValue_ = 0            -- 显示用的渲染 FPS
local fpsNetValue_ = 0               -- 显示用的网络发送 FPS

-- 调试信息总开关（F2 切换）
local debugVisible_ = false
local prevF2Down_ = false

--- 在 Update 阶段缓存鼠标输入状态
--- 使用 GetMouseButtonDown + 前帧状态差分，彻底规避 GetMouseButtonPress 时序问题
--- 必须由 Client.HandleUpdate / Standalone.HandleUpdate 在每帧开头调用
function HUD.CacheInput()
    cacheInputCalledThisFrame_ = true
    dbg_cacheInputCount_ = dbg_cacheInputCount_ + 1
    local down = input:GetMouseButtonDown(MOUSEB_LEFT)
    dbg_mouseDownRaw_ = down
    -- press = 本帧按下 且 上一帧未按下（手动实现 press 检测）
    cachedMousePress_ = down and not prevMouseDown_
    prevMouseDown_ = down
    if cachedMousePress_ then
        cachedMouseLogX_ = input.mousePosition.x / dpr_
        cachedMouseLogY_ = input.mousePosition.y / dpr_
        dbg_lastPressTime_ = os.clock()
        dbg_lastClickX_ = cachedMouseLogX_
        dbg_lastClickY_ = cachedMouseLogY_
    end

    -- F2 切换调试信息显示（边沿触发）
    local f2Down = input:GetKeyDown(KEY_F2)
    if f2Down and not prevF2Down_ then
        debugVisible_ = not debugVisible_
    end
    prevF2Down_ = f2Down
end

--- 调试信息是否可见（供外部判断）
function HUD.IsDebugVisible()
    return debugVisible_
end

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
    -- Astroon 主题：统一使用阿里妈妈方圆体
    fontNormal_ = nvgCreateFont(vg_, "sans", "Fonts/AlimamaFangYuanTi.ttf")
    fontBold_ = nvgCreateFont(vg_, "bold", "Fonts/AlimamaFangYuanTi.ttf")

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

    -- 安全回退：如果 Update 阶段没调用 CacheInput，在渲染阶段补调
    -- 这修复了 Module.HandleUpdate 链断裂导致完全无法点击的 bug
    if not cacheInputCalledThisFrame_ then
        HUD.CacheInput()
        dbg_cacheInputMissed_ = dbg_cacheInputMissed_ + 1
    end
    cacheInputCalledThisFrame_ = false  -- 重置，为下一帧准备

    -- 计算帧间隔（用于浮动文字动画）
    local now = time:GetElapsedTime()
    local renderDt = now - lastRenderTime_
    if renderDt > 0.1 then renderDt = 0.016 end  -- 首帧/异常保护
    lastRenderTime_ = now
    -- 缓存引擎时间供本帧所有动画脉冲使用（替代 os.clock()）
    hudElapsedTime_ = now

    -- 更新浮动文字计时
    HUD.UpdateKillFloats(renderDt)

    nvgBeginFrame(vg_, logW_, logH_, dpr_)

    -- 帧率监控（覆盖所有界面分支，最先采样最准）
    HUD.DrawFpsHud()

    local state = gameManager_ and gameManager_.state or "racing"

    -- 联机客户端：根据 clientState 路由额外界面
    local clientMod = _G.ClientModule
    if clientMod then
        local cs = clientMod.GetState()
        if cs == "quickMatching" then
            HUD.DrawQuickMatching()
            HUD.DrawToast()
            nvgEndFrame(vg_)
            return
        elseif cs == "friendMenu" or cs == "creatingRoom" then
            HUD.DrawFriendMenu()
            HUD.DrawToast()
            nvgEndFrame(vg_)
            return
        elseif cs == "roomWaiting" then
            HUD.DrawRoomWaiting()
            HUD.DrawToast()
            nvgEndFrame(vg_)
            return
        elseif cs == "roomJoining" then
            HUD.DrawRoomJoining()
            HUD.DrawToast()
            nvgEndFrame(vg_)
            return
        end
        -- cs == "menu" or "playing" → 走下方正常路径
    end

    -- 主菜单
    if state == "menu" then
        HUD.DrawMenu()
        if clientMod then HUD.DrawToast() end
        nvgEndFrame(vg_)
        return
    end

    -- 匹配界面（单机）
    if state == "matching" then
        HUD.DrawMatching()
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

    -- FX 诊断面板（常驻右上角，有消息时自动显示）
    HUD.DrawFXDiagPanel()

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
--- 矢量化几何动态背景（铺满屏幕、缓慢斜向循环移动）
--- @param palette table {bgTop, bgBottom, shapes={{r,g,b,a}, ...}}
function HUD.DrawAnimatedBgPattern(palette)
    -- 1. 纯色/微渐变底色
    local bt, bb = palette.bgTop, palette.bgBottom
    local bgPaint = nvgLinearGradient(vg_, 0, 0, logW_, logH_,
        nvgRGBA(bt[1], bt[2], bt[3], 255),
        nvgRGBA(bb[1], bb[2], bb[3], 255))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillPaint(vg_, bgPaint)
    nvgFill(vg_)

    -- 2. 圆角矩形瓦片：错位栅格 + 整体向左下平移 + 缓慢自转
    -- ⚠️ 无缝循环关键：奇偶行半格错位时，垂直周期是 2*tile
    local accent = palette.accent or { bt[1] + 10, bt[2] + 10, bt[3] + 15, 40 }
    local tile = palette.tile or 80              -- 瓦片间距（逻辑像素）
    local speed = palette.speed or 30            -- 平移速度（逻辑像素/秒）
    local spinSpeed = palette.spinSpeed or 0.3   -- 自转角速度（弧度/秒）
    local t = (time and time.GetElapsedTime) and time:GetElapsedTime() or os.clock()
    local offX = -((t * speed) % tile)
    local offY =  ((t * speed) % (tile * 2))
    local cols = math.ceil(logW_ / tile) + 3
    local rows = math.ceil(logH_ / tile) + 4
    local spin = t * spinSpeed

    -- 颜色与背景接近，低对比度
    local accentAlpha = accent[4] or 40
    nvgFillColor(vg_, nvgRGBA(accent[1], accent[2], accent[3], accentAlpha))
    local sz = tile * 0.30                        -- 矩形半尺寸（适中大小）
    local cornerR = sz * 0.30                     -- 圆角半径
    local spinDeg = math.deg(math.pi * 0.25 + spin)  -- 45° 基础 + 自转

    -- 逐个绘制圆角矩形（需要 save/translate/rotate 才能使用 nvgRoundedRect）
    local halfTile = tile * 0.5
    for ri = -2, rows do
        local rowOdd = (ri % 2 ~= 0) and halfTile or 0
        local baseY = ri * tile + offY
        for ci = -2, cols do
            local cx = ci * tile + offX + rowOdd
            local cy = baseY
            nvgSave(vg_)
            nvgTranslate(vg_, cx, cy)
            nvgRotate(vg_, math.rad(spinDeg))
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, -sz, -sz, sz * 2, sz * 2, cornerR)
            nvgFill(vg_)
            nvgRestore(vg_)
        end
    end
end

function HUD.DrawBackground()
    -- 背景已由 Background.lua 在 3D 场景中渲染（渐变底色 + 动态菱形）
    -- 此函数保留为空，供调用点兼容
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
                local pulse = math.abs(math.sin(hudElapsedTime_ * freq)) * 0.4 + 0.2

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

--- 绘制被炸方块的轮廓和重生进度条（优化版：用实线圆角矩形 + 进度弧替代虚线）
function HUD.DrawDestroyedBlockGhosts()
    if mapModule_ == nil then return end

    local blocks = mapModule_.GetDestroyedBlocks()
    if #blocks == 0 then return end

    local bs = Config.BlockSize
    local blockScreenSize = Camera.WorldSizeToScreen(bs, logH_)
    -- 太小了就不画
    if blockScreenSize < 3 then return end

    -- 圆角半径：方块屏幕尺寸的 18%
    local cornerR = blockScreenSize * 0.18
    local elapsedTime = time:GetElapsedTime()

    for _, info in ipairs(blocks) do
        -- 网格坐标转世界坐标（中心）
        local wx = (info.x - 1) * bs + bs * 0.5
        local wy = (info.y - 1) * bs + bs * 0.5
        local sx, sy = Camera.WorldToScreen(wx, wy, logW_, logH_)

        local halfS = blockScreenSize * 0.5

        -- 稍微内缩
        local inset = blockScreenSize * 0.06
        local drawSize = blockScreenSize - inset * 2
        local drawX = sx - halfS + inset
        local drawY = sy - halfS + inset

        local progress = 1.0 - (info.timer / info.totalTime)  -- 0→1
        local alpha = 80 + math.floor(math.abs(math.sin(elapsedTime * 3 + info.x * 0.7)) * 40)

        -- 1) 灰色实线轮廓（底层，圆角矩形，单次 path）
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, drawX, drawY, drawSize, drawSize, cornerR)
        nvgStrokeColor(vg_, nvgRGBA(200, 200, 220, alpha))
        nvgStrokeWidth(vg_, 2.0)
        nvgStroke(vg_)

        -- 2) 进度弧（中心圆弧，简单高效替代沿边框走的虚线进度）
        if progress > 0.01 then
            local pAlpha = 160 + math.floor(progress * 95)
            local cx = sx
            local cy = sy
            local radius = drawSize * 0.3
            local startA = -math.pi * 0.5
            local endA = startA + math.pi * 2 * progress
            nvgBeginPath(vg_)
            nvgArc(vg_, cx, cy, radius, startA, endA, NVG_CW)
            nvgStrokeColor(vg_, nvgRGBA(120, 200, 255, pAlpha))
            nvgStrokeWidth(vg_, 3.0)
            nvgStroke(vg_)
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
        nvgFillColor(vg_, nvgRGBA(42, 31, 94, 180))  -- Astroon $surface
        nvgFill(vg_)

        -- 能量填充
        local fillW = barW * math.min(1, p.energy)
        if fillW > 0.5 then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, bx, by, fillW, barH, cornerR)
            if p.energy >= 1.0 then
                -- 充满闪烁（危险红）
                local pulse = math.abs(math.sin(hudElapsedTime_ * 4)) * 55 + 200
                nvgFillColor(vg_, nvgRGBA(255, 40, 30, math.floor(pulse)))
            else
                nvgFillColor(vg_, nvgRGBA(74, 139, 245, 210))  -- Astroon $secondary 蓝色
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
    nvgText(vg_, x, startY, "积分")

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

        -- 已到达终点标记
        local p = playerModule_.list[i]
        if p and p.finished then
            nvgFillColor(vg_, nvgRGBA(255, 215, 0, 255))
            nvgText(vg_, x - 60, y, "🏁")
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
        local pulse = math.abs(math.sin(hudElapsedTime_ * 3)) * 100 + 50
        nvgFillColor(vg_, nvgRGBA(180, 30, 30, math.floor(pulse) + 100))
    else
        nvgFillColor(vg_, nvgRGBA(42, 31, 94, 210))  -- Astroon $surface
    end
    nvgFill(vg_)

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 20)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    if remaining <= 10 then
        nvgFillColor(vg_, nvgRGBA(255, 71, 87, 255))  -- Astroon $error
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
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 136))  -- Astroon $textSecondary

    local totalRounds = gameManager_.numRounds or Config.NumRounds
    local roundText = "ROUND " .. gameManager_.round .. " / " .. totalRounds
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
    nvgFillColor(vg_, nvgRGBA(42, 31, 94, 150))  -- Astroon $surface
    nvgFill(vg_)

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 160))
    nvgText(vg_, panelX, panelY, "击杀")

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
    nvgFillColor(vg_, nvgRGBA(26, 17, 64, 60))  -- Astroon $background
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
        nvgFillColor(vg_, nvgRGBA(255, 213, 79, labelAlpha))  -- Astroon $primary
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
        nvgFillColor(vg_, nvgRGBA(255, 213, 79, 180))  -- Astroon $primary
        nvgFill(vg_)
    end

    -- 阶段 2：平移到起点 → 显示 "起点" 提示
    if phase == 2 then
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 28)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
        nvgText(vg_, logW_ * 0.5 + 2, logH_ * 0.82 + 2, "起点")

        nvgFillColor(vg_, nvgRGBA(46, 204, 113, 220))  -- Astroon $success
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
        nvgFillColor(vg_, nvgRGBA(255, 213, 79, glowAlpha))  -- Astroon $primary glow
        nvgText(vg_, logW_ * 0.5, logH_ * 0.45 + 3, "更快到达终点!")
        nvgText(vg_, logW_ * 0.5, logH_ * 0.45 - 3, "更快到达终点!")

        -- 阴影
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(textAlpha * 180)))
        nvgText(vg_, logW_ * 0.5 + 3, logH_ * 0.45 + 3, "更快到达终点!")

        -- 主文字（Astroon 金色）
        nvgFillColor(vg_, nvgRGBA(255, 213, 79, alpha))  -- Astroon $primary
        nvgText(vg_, logW_ * 0.5, logH_ * 0.45, "更快到达终点!")

        -- 副标题：回合数（字号加大）
        nvgFontSize(vg_, 44)
        -- 阴影
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(textAlpha * 200)))
        nvgText(vg_, logW_ * 0.5 + 3, logH_ * 0.58 + 3, "第 " .. (gameManager_.round or 1) .. " 回合")
        -- 主文字（Astroon 青色）
        nvgFillColor(vg_, nvgRGBA(61, 214, 232, math.floor(textAlpha * 240)))  -- Astroon $accent
        nvgText(vg_, logW_ * 0.5, logH_ * 0.58, "第 " .. (gameManager_.round or 1) .. " 回合")
    end
end

--- 倒计时覆盖层
function HUD.DrawCountdown()
    if gameManager_ == nil then return end

    -- 半透明深紫背景
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(26, 17, 64, 100))  -- Astroon $background
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
        nvgFillColor(vg_, nvgRGBA(46, 204, 113, 255))  -- Astroon $success
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, "出发!")
    else
        nvgFillColor(vg_, nvgRGBA(255, 213, 79, 255))  -- Astroon $primary
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, tostring(num))
    end

    -- 提示
    nvgFontSize(vg_, 18)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 136))  -- Astroon $textSecondary
    nvgText(vg_, logW_ * 0.5, logH_ * 0.5 + 80, "准备就绪!")
end

--- 回合结束覆盖层
function HUD.DrawRoundEnd()
    if gameManager_ == nil then return end

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(26, 17, 64, 140))  -- Astroon $background
    nvgFill(vg_)

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 48)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, logW_ * 0.5 + 2, logH_ * 0.5 - 18, "回合结束")
    nvgFillColor(vg_, nvgRGBA(255, 213, 79, 255))  -- Astroon $primary
    nvgText(vg_, logW_ * 0.5, logH_ * 0.5 - 20, "回合结束")

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
    nvgFillColor(vg_, nvgRGBA(26, 17, 64, 215))  -- Astroon $background
    nvgFill(vg_)

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 36)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    nvgText(vg_, logW_ * 0.5, logH_ * 0.3, "排名")

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

    -- 动态最大分数：取所有玩家中的最高分，至少为 1
    local maxScore = 1
    for i = 1, Config.NumPlayers do
        if gameManager_.scores[i] > maxScore then
            maxScore = gameManager_.scores[i]
        end
    end

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
        nvgFillColor(vg_, nvgRGBA(42, 31, 94, 190))  -- Astroon $surface
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
        nvgText(vg_, bx + 8, y + barH * 0.5, tostring(score) .. " pts")
    end

    -- 提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))  -- Astroon $textMuted
    nvgText(vg_, logW_ * 0.5, logH_ - 30, "下一回合即将开始...")
end

--- 比赛结束覆盖层
function HUD.DrawMatchEnd()
    if gameManager_ == nil then return end

    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(26, 17, 64, 225))  -- Astroon $background
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
        local pulse = math.abs(math.sin(hudElapsedTime_ * 2)) * 30 + 20
        nvgBeginPath(vg_)
        nvgCircle(vg_, logW_ * 0.5, logH_ * 0.4, 100 + pulse)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 40))
        nvgFill(vg_)

        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
        nvgText(vg_, logW_ * 0.5 + 3, logH_ * 0.35 + 3, "胜者!")
        nvgFillColor(vg_, nvgRGBA(255, 215, 0, 255))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.35, "胜者!")

        nvgFontSize(vg_, 36)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, "玩家 " .. winner)

        nvgFontSize(vg_, 20)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 200))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.58, "积分: " .. gameManager_.scores[winner])
    end

    -- 提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))  -- Astroon $textMuted
    nvgText(vg_, logW_ * 0.5, logH_ - 30, "新比赛即将开始...")
end

--- 右下角帧率显示（渲染 FPS / 网络发送 FPS）
--- 每秒采样一次：渲染 FPS 自统计，网络 FPS 从 _G.NetSendFps 读取
function HUD.DrawFpsHud()
    if not debugVisible_ then return end
    -- 采样累计（使用引擎 wall-clock 时间，os.clock 在 WASM 下不可靠）
    fpsRenderFrames_ = fpsRenderFrames_ + 1
    local now = time:GetElapsedTime()
    if fpsLastSample_ < 0 then
        fpsLastSample_ = now
    end
    local elapsed = now - fpsLastSample_
    if elapsed >= 1.0 then
        fpsRenderValue_ = math.floor(fpsRenderFrames_ / elapsed + 0.5)
        -- 网络发送频率：优先使用 _G.NetSendFps（Client 实测），否则回退引擎配置
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

    -- 绘制
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

    -- 半透明背景
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, boxX, boxY, boxW, boxH, 4)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
    nvgFill(vg_)

    -- 渲染 FPS（绿色 / 黄色 / 红色 阈值着色）
    local rR, rG, rB = 120, 255, 120
    if fpsRenderValue_ < 30 then rR, rG, rB = 255, 80, 80
    elseif fpsRenderValue_ < 50 then rR, rG, rB = 255, 220, 80 end
    nvgFillColor(vg_, nvgRGBA(rR, rG, rB, 255))
    nvgText(vg_, boxX + boxW - pad, boxY + pad + lineH, "Render: " .. fpsRenderValue_ .. " fps")

    -- 网络发送 FPS
    local nR, nG, nB = 120, 255, 255
    if fpsNetValue_ < 20 then nR, nG, nB = 255, 80, 80
    elseif fpsNetValue_ < 45 then nR, nG, nB = 255, 220, 80 end
    nvgFillColor(vg_, nvgRGBA(nR, nG, nB, 255))
    nvgText(vg_, boxX + boxW - pad, boxY + pad + lineH * 2, "Net:    " .. fpsNetValue_ .. " fps")

    nvgRestore(vg_)
end

--- 画面调试覆盖层（左上角显示输入/连接状态）
function HUD.DrawDebugOverlay()
    if not debugVisible_ then return end
    nvgSave(vg_)

    -- 半透明黑底（加大高度以容纳网络日志）
    nvgBeginPath(vg_)
    nvgRect(vg_, 4, 4, 460, 560)
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

    -- 连接状态（最重要，放最前面）
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
    else
        line("ClientModule: nil", 255, 100, 100)
    end

    -- 按钮命中追踪
    line("BtnReturnTrue: " .. dbg_btnReturnTrue_, 200, 200, 200)

    -- 上次动作
    local actElapsed = os.clock() - dbg_lastActionTime_
    local actColor = actElapsed < 3 and 255 or 150
    line("LastAction: " .. dbg_lastAction_, actColor, actColor, 100)

    -- 实时点击指示器（点击后 1 秒内闪烁绿色方块）
    local elapsed = os.clock() - dbg_lastPressTime_
    if dbg_lastPressTime_ > 0 and elapsed < 1.0 then
        nvgBeginPath(vg_)
        nvgRect(vg_, 420, 10, 24, 24)
        nvgFillColor(vg_, nvgRGBA(0, 255, 0, math.floor(255 * (1.0 - elapsed))))
        nvgFill(vg_)
    end

    -- ======== 网络事件日志（核心调试信息）========
    dy = dy + 4
    line("[NET EVENT LOG]", 255, 180, 0)

    if clientMod and clientMod.GetNetLog then
        local netLog = clientMod.GetNetLog()
        if #netLog == 0 then
            line("  (no events yet)", 150, 150, 150)
        else
            local now = os.clock()
            -- 显示最近的日志条目（从最新到最旧）
            local startIdx = math.max(1, #netLog - 15)  -- 最多显示 16 条
            for i = #netLog, startIdx, -1 do
                local entry = netLog[i]
                local age = now - entry.time
                local ageStr = string.format("%.1fs", age)
                -- 超过 30 秒的日志变暗
                local alpha = age < 30 and 255 or 120
                local r = math.floor(entry.r * alpha / 255)
                local g = math.floor(entry.g * alpha / 255)
                local b = math.floor(entry.b * alpha / 255)
                line("[" .. ageStr .. "] " .. entry.msg, r, g, b)
            end
        end
    else
        line("  GetNetLog not available", 255, 100, 100)
    end

    nvgRestore(vg_)
end

--- FX 诊断面板（右上角常驻显示，不受 F2 控制）
--- 显示 FXDiag 环形缓冲区中的诊断消息
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
    local panelH = visibleCount * lineH + pad * 2 + lineH  -- +lineH for title
    local panelX = logW_ - panelW - 8
    local panelY = 8

    -- 半透明黑底
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, panelX, panelY, panelW, panelH, 4)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200))
    nvgFill(vg_)

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 13)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 220, 0, 255))
    nvgText(vg_, panelX + pad, panelY + pad, "[FX DIAG] " .. #entries .. " msgs")

    -- 日志条目（从最新到最旧）
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    local dy = panelY + pad + lineH
    local now = os.clock()
    for i = #entries, startIdx, -1 do
        local e = entries[i]
        local age = now - e.time
        local ageStr = string.format("%.1fs", age)
        -- 超过 30 秒的日志变暗
        local alpha = age < 30 and 255 or 100
        local r = math.floor(e.r * alpha / 255)
        local g = math.floor(e.g * alpha / 255)
        local b = math.floor(e.b * alpha / 255)
        nvgFillColor(vg_, nvgRGBA(r, g, b, alpha))
        nvgText(vg_, panelX + pad, dy, "[" .. ageStr .. "] " .. e.msg)
        dy = dy + lineH
    end

    nvgRestore(vg_)
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
    -- Astroon 风格：胶囊按钮 + 渐变填充 + 发光阴影
    local pillR = h * 0.5  -- 胶囊圆角（pill radius）

    -- 计算渐变终点色（略深 ~30%）
    local endR = math.floor(baseR * 0.7)
    local endG = math.floor(baseG * 0.7)
    local endB = math.floor(baseB * 0.7)

    -- 1) 发光阴影（Astroon glow shadow）
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x - 4, y - 2, w + 8, h + 10, pillR + 4)
    nvgFillColor(vg_, nvgRGBA(endR, endG, endB, hovered and 100 or 60))
    nvgFill(vg_)

    -- 2) 渐变填充（从 base → 深色）
    local br = hovered and math.min(255, baseR + 20) or baseR
    local bg2 = hovered and math.min(255, baseG + 20) or baseG
    local bb = hovered and math.min(255, baseB + 20) or baseB
    local gradPaint = nvgLinearGradient(vg_, x, y, x, y + h,
        nvgRGBA(br, bg2, bb, 255), nvgRGBA(endR, endG, endB, 255))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, pillR)
    nvgFillPaint(vg_, gradPaint)
    nvgFill(vg_)

    -- 3) 顶部高光条（微妙光泽）
    local glossPaint = nvgLinearGradient(vg_, x, y, x, y + h * 0.4,
        nvgRGBA(255, 255, 255, hovered and 80 or 50), nvgRGBA(255, 255, 255, 0))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h * 0.5, pillR)
    nvgFillPaint(vg_, glossPaint)
    nvgFill(vg_)

    -- 4) 边框描边（半透明白色）
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, pillR)
    nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, hovered and 60 or 24))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)

    -- 文字阴影
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.floor(h * 0.42))
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 100))
    nvgText(vg_, x + w * 0.5 + 1, y + h * 0.52 + 1, label)

    -- 文字
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
    nvgText(vg_, x + w * 0.5, y + h * 0.52, label)

    -- 点击检测（使用帧缓存的鼠标状态）
    if cachedMousePress_ and hovered then
        dbg_btnReturnTrue_ = dbg_btnReturnTrue_ + 1
        dbg_lastAction_ = "BTN:" .. label
        dbg_lastActionTime_ = os.clock()
        return true
    end
    return false
end

--- 主菜单界面
function HUD.DrawMenu()
    -- Astroon 宇宙紫调：深紫渐变底色
    HUD.DrawAnimatedBgPattern({
        bgTop    = { 45, 27, 105 },    -- #2D1B69 backgroundMid
        bgBottom = { 26, 17, 64 },     -- #1A1140 background
        accent   = { 60, 45, 130, 35 }, -- 接近背景的淡紫，低对比
    })
    local t = os.clock()

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

        -- 绘制图片（圆角）
        local imgRadius = 16
        local imgPaint = nvgImagePattern(vg_, imgX, imgY, drawW, drawH, 0, titleImage_, 1.0)
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, imgX, imgY, drawW, drawH, imgRadius)
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
        nvgFillColor(vg_, nvgRGBA(255, 213, 79, 255))  -- Astroon $primary 金色
        nvgText(vg_, cx, cy, Config.Title)
    end

    -- ======== 橡胶按钮（横向排列） ========
    local subtitleY = titleBottom + 14  -- 保留为按钮基准 Y
    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    local btnW = 140
    local btnH = 52
    local btnGap = 14
    local btnY = subtitleY + 24

    -- 根据是否联机模式决定按钮列表
    local isOnline = (_G.ClientModule ~= nil)
    local buttons
    if isOnline then
        buttons = {
            { label = "快速开始",   r = 255, g = 213, b = 79,  id = "quickStart" },  -- Astroon $primary 金色
            { label = "与朋友玩",   r = 61,  g = 214, b = 232, id = "friendPlay" },  -- Astroon $accent 青色
            { label = "关卡编辑器", r = 74,  g = 139, b = 245, id = "editor" },      -- Astroon $secondary 蓝色
        }
    else
        buttons = {
            { label = "开始游戏",   r = 255, g = 213, b = 79,  id = "startGame" },   -- Astroon $primary 金色
            { label = "关卡编辑器", r = 74,  g = 139, b = 245, id = "editor" },      -- Astroon $secondary 蓝色
        }
    end

    local totalW = btnW * #buttons + btnGap * (#buttons - 1)
    local btnStartX = cx - totalW * 0.5

    for idx, btn in ipairs(buttons) do
        local bx = btnStartX + (idx - 1) * (btnW + btnGap)
        local hovered = mx >= bx and mx <= bx + btnW and my >= btnY and my <= btnY + btnH
        local clicked = HUD.DrawRubberButton(bx, btnY, btnW, btnH, btn.label, btn.r, btn.g, btn.b, hovered)
        if clicked then
            menuButtonClicked_ = btn.id
            dbg_lastAction_ = "MENU:" .. btn.id
            dbg_lastActionTime_ = os.clock()
        end
    end

    -- 独立点击追踪（主菜单）
    if cachedMousePress_ then
        local hitBtn = "MISS"
        for idx, btn in ipairs(buttons) do
            local bx = btnStartX + (idx - 1) * (btnW + btnGap)
            if mx >= bx and mx <= bx + btnW and my >= btnY and my <= btnY + btnH then
                hitBtn = "HIT:" .. btn.label
            end
        end
        dbg_lastAction_ = "MENU_CLICK@" .. math.floor(mx) .. "," .. math.floor(my) .. " " .. hitBtn
        dbg_lastActionTime_ = os.clock()
    end

    -- 调试覆盖层（F2 切换）
    HUD.DrawDebugOverlay()
end

--- 匹配界面（正在寻找对手 + 旋转放大镜 + 玩家槽位）
function HUD.DrawMatching()
    if gameManager_ == nil then return end

    -- Astroon 深紫色调
    HUD.DrawAnimatedBgPattern({
        bgTop    = { 45, 27, 105 },    -- #2D1B69 backgroundMid
        bgBottom = { 26, 17, 64 },     -- #1A1140 background
        accent   = { 55, 40, 125, 35 }, -- 接近背景的淡紫，低对比
    })
    local t = os.clock()

    local cx = logW_ * 0.5
    local cy = logH_ * 0.38

    -- ======== 旋转放大镜图标 ========
    local angle = t * 2.5  -- 旋转速度
    local magR = 22         -- 放大镜圆半径
    local handleLen = 18    -- 手柄长度
    local lineW = 4

    nvgSave(vg_)
    nvgTranslate(vg_, cx, cy)
    nvgRotate(vg_, angle)

    -- 镜片圆
    nvgBeginPath(vg_)
    nvgCircle(vg_, 0, 0, magR)
    nvgStrokeColor(vg_, nvgRGBA(255, 213, 79, 220))
    nvgStrokeWidth(vg_, lineW)
    nvgStroke(vg_)

    -- 镜片内半透明填充
    nvgBeginPath(vg_)
    nvgCircle(vg_, 0, 0, magR - lineW * 0.5)
    nvgFillColor(vg_, nvgRGBA(255, 213, 79, 30))
    nvgFill(vg_)

    -- 镜片高光弧
    nvgBeginPath(vg_)
    nvgArc(vg_, 0, 0, magR * 0.65, -math.pi * 0.8, -math.pi * 0.2, NVG_CW)
    nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 80))
    nvgStrokeWidth(vg_, 2)
    nvgStroke(vg_)

    -- 手柄
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, magR * 0.7, magR * 0.7)
    nvgLineTo(vg_, magR * 0.7 + handleLen * 0.7, magR * 0.7 + handleLen * 0.7)
    nvgStrokeColor(vg_, nvgRGBA(180, 150, 55, 220))
    nvgStrokeWidth(vg_, lineW + 1)
    nvgLineCap(vg_, NVG_ROUND)
    nvgStroke(vg_)

    nvgRestore(vg_)

    -- ======== 匹配状态文字 ========
    local dots = string.rep(".", (math.floor(t * 2) % 4))
    local searchText = "正在准备比赛" .. dots

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 28)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 阴影
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 160))
    nvgText(vg_, cx + 2, cy + 60 + 2, searchText)
    -- 主文字
    nvgFillColor(vg_, nvgRGBA(255, 213, 79, 255))
    nvgText(vg_, cx, cy + 60, searchText)

    -- ======== 玩家槽位（4 格，逐渐填充） ========
    local slots = gameManager_.GetMatchingSlots()
    local totalSlots = Config.NumPlayers
    local slotSize = 40
    local slotGap = 16
    local slotTotalW = slotSize * totalSlots + slotGap * (totalSlots - 1)
    local slotStartX = cx - slotTotalW * 0.5
    local slotY = cy + 110

    for i = 1, totalSlots do
        local sx = slotStartX + (i - 1) * (slotSize + slotGap)
        local filled = i <= slots

        -- 槽位背景
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, sx, slotY, slotSize, slotSize, 8)
        if filled then
            local pc = Config.PlayerColors[i]
            local pr = math.floor(pc.r * 255)
            local pg = math.floor(pc.g * 255)
            local pb = math.floor(pc.b * 255)
            nvgFillColor(vg_, nvgRGBA(pr, pg, pb, 220))
        else
            nvgFillColor(vg_, nvgRGBA(60, 50, 110, 120))
        end
        nvgFill(vg_)

        -- 边框
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, sx, slotY, slotSize, slotSize, 8)
        if filled then
            nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 120))
        else
            -- 未填充的槽位边框闪烁
            local pulse = math.abs(math.sin(t * 3 + i * 0.8)) * 60 + 40
            nvgStrokeColor(vg_, nvgRGBA(61, 214, 232, math.floor(pulse)))
        end
        nvgStrokeWidth(vg_, 2)
        nvgStroke(vg_)

        -- 标签
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 14)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        if filled then
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
            local label = i == 1 and "你" or "玩家"
            nvgText(vg_, sx + slotSize * 0.5, slotY + slotSize * 0.5, label)
        else
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))
            nvgText(vg_, sx + slotSize * 0.5, slotY + slotSize * 0.5, "?")
        end
    end

    -- 槽位进度文字
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 136))
    nvgText(vg_, cx, slotY + slotSize + 10, slots .. " / " .. totalSlots .. " 玩家")

    -- ======== 匹配完成提示 ========
    if gameManager_.IsMatchingComplete() then
        local flashA = math.floor(math.abs(math.sin(t * 5)) * 100 + 155)
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 24)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(46, 204, 113, flashA))
        nvgText(vg_, cx, slotY + slotSize + 40, "匹配成功！即将开始...")
    end

    -- ======== ESC 提示 ========
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))
    nvgText(vg_, cx, logH_ - 12, "按 ESC 取消匹配")
end

-- ============================================================================
-- 关卡列表 UI
-- ============================================================================

--- 绘制关卡列表界面
function HUD.DrawLevelList()
    -- 全屏背景（Astroon 深紫渐变）
    local bgPaint = nvgLinearGradient(vg_, 0, 0, logW_, logH_,
        nvgRGBA(45, 27, 105, 255), nvgRGBA(26, 17, 64, 255))  -- Astroon backgroundMid → background
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillPaint(vg_, bgPaint)
    nvgFill(vg_)

    local cx = logW_ * 0.5

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 36)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 213, 79, 255))  -- Astroon $primary
    nvgText(vg_, cx, 40, "关卡编辑器")

    -- 关卡数量提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 136))  -- Astroon $textSecondary
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
    nvgFillColor(vg_, nvgRGBA(42, 31, 94, 140))  -- Astroon $surface
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
        nvgFillColor(vg_, nvgRGBA(42, 31, 94, 180))
        nvgFill(vg_)

        -- 关卡名称
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 16)
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
        nvgText(vg_, listX + 12, iy + itemH * 0.5, entry.name or entry.filename)

        -- 文件名（小字）
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 11)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))
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
        nvgFillColor(vg_, delHover and nvgRGBA(255, 71, 87, 220) or nvgRGBA(180, 50, 60, 160))
        nvgFill(vg_)
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, delHover and 255 or 220))
        nvgText(vg_, bx + btnW * 0.5, by + btnH * 0.5, "删除")
        if clicked and delHover then
            levelListAction_ = { action = "delete", filename = entry.filename }
        end

        -- 修改按钮
        bx = bx - btnW - btnGap
        local editHover = mx >= bx and mx <= bx + btnW and my >= by and my <= by + btnH
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, btnW, btnH, 4)
        nvgFillColor(vg_, editHover and nvgRGBA(46, 204, 113, 220) or nvgRGBA(35, 150, 85, 160))
        nvgFill(vg_)
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, editHover and 255 or 220))
        nvgText(vg_, bx + btnW * 0.5, by + btnH * 0.5, "修改")
        if clicked and editHover then
            levelListAction_ = { action = "edit", filename = entry.filename }
        end

        -- 试玩按钮
        bx = bx - btnW - btnGap
        local playHover = mx >= bx and mx <= bx + btnW and my >= by and my <= by + btnH
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, btnW, btnH, 4)
        nvgFillColor(vg_, playHover and nvgRGBA(74, 139, 245, 220) or nvgRGBA(55, 105, 185, 160))
        nvgFill(vg_)
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, playHover and 255 or 220))
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
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 136))
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
    nvgFillColor(vg_, newHover and nvgRGBA(46, 204, 113, 220) or nvgRGBA(35, 150, 85, 180))
    nvgFill(vg_)
    nvgStrokeColor(vg_, nvgRGBA(46, 204, 113, newHover and 180 or 100))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, newHover and 255 or 220))
    nvgText(vg_, newX + bbtnW * 0.5, bottomY + bbtnH * 0.5, "新建关卡")
    if clicked and newHover then
        levelListAction_ = { action = "new" }
    end

    -- "保存到工程" 按钮（金色醒目）
    local persistX = btnStartX + bbtnW + bbtnGap
    local persistHover = mx >= persistX and mx <= persistX + bbtnW and my >= bottomY and my <= bottomY + bbtnH
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, persistX, bottomY, bbtnW, bbtnH, 8)
    nvgFillColor(vg_, persistHover and nvgRGBA(255, 213, 79, 230) or nvgRGBA(180, 150, 55, 190))
    nvgFill(vg_)
    nvgStrokeColor(vg_, nvgRGBA(255, 213, 79, persistHover and 200 or 120))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 15)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, persistHover and 255 or 220))
    nvgText(vg_, persistX + bbtnW * 0.5, bottomY + bbtnH * 0.5, "保存到工程")
    if clicked and persistHover then
        persistClicked_ = true
    end

    -- "返回菜单" 按钮
    local backX = btnStartX + (bbtnW + bbtnGap) * 2
    local backHover = mx >= backX and mx <= backX + bbtnW and my >= bottomY and my <= bottomY + bbtnH
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, backX, bottomY, bbtnW, bbtnH, 8)
    nvgFillColor(vg_, backHover and nvgRGBA(60, 50, 110, 220) or nvgRGBA(42, 31, 94, 180))
    nvgFill(vg_)
    nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, backHover and 80 or 40))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, backHover and 255 or 200))
    nvgText(vg_, backX + bbtnW * 0.5, bottomY + bbtnH * 0.5, "返回菜单")
    if clicked and backHover then
        levelListAction_ = { action = "back" }
    end

    -- ESC 快捷键返回
    if input:GetKeyPress(KEY_ESCAPE) then
        levelListAction_ = { action = "back" }
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
    nvgFillColor(vg_, hovered and nvgRGBA(255, 71, 87, 220) or nvgRGBA(180, 50, 60, 180))
    nvgFill(vg_)

    nvgStrokeColor(vg_, nvgRGBA(255, 71, 87, hovered and 200 or 100))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)

    -- 文字
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, hovered and 255 or 220))
    nvgText(vg_, btnX + btnW * 0.5, btnY + btnH * 0.5, "退出试玩")

    -- "试玩中" 标签
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 11)
    nvgFillColor(vg_, nvgRGBA(255, 213, 79, 160))
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgText(vg_, btnX, btnY + btnH + 4, "试玩模式")

    -- 点击检测（使用帧缓存的鼠标状态）
    if cachedMousePress_ and hovered then
        testPlayExitClicked_ = true
    end
end

-- ============================================================================
-- 联机 UI 界面（Client 专用）
-- ============================================================================

--- 绘制全屏暗色背景（联机界面通用）
local function drawOnlineBg()
    HUD.DrawAnimatedBgPattern({
        bgTop    = { 45, 27, 105 },    -- #2D1B69 backgroundMid
        bgBottom = { 26, 17, 64 },     -- #1A1140 background
        accent   = { 58, 42, 128, 30 }, -- 接近背景的淡紫，低对比
    })
end

--- Toast 提示（屏幕顶部，3 秒自动消失）
function HUD.DrawToast()
    local clientMod = _G.ClientModule
    if not clientMod then return end
    local msg, timer = clientMod.GetToast()
    if not msg or msg == "" or timer <= 0 then return end

    local alpha = math.min(1.0, timer) * 255

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 20)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 背景条
    local tw = nvgTextBounds(vg_, 0, 0, msg)
    local padX = 20
    local padY = 8
    local ty = 40
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, logW_ * 0.5 - tw * 0.5 - padX, ty - 14 - padY, tw + padX * 2, 28 + padY * 2, 10)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.6)))
    nvgFill(vg_)

    nvgFillColor(vg_, nvgRGBA(255, 213, 79, math.floor(alpha)))
    nvgText(vg_, logW_ * 0.5, ty, msg)
end

--- 快速匹配界面
function HUD.DrawQuickMatching()
    drawOnlineBg()

    local clientMod = _G.ClientModule
    local playerCount, humanCount = 0, 0
    if clientMod then
        playerCount, humanCount = clientMod.GetQuickMatchInfo()
    end

    local cx = logW_ * 0.5
    local cy = logH_ * 0.38
    local t = os.clock()

    -- 旋转放大镜（复用匹配界面的视觉）
    local angle = t * 2.5
    local magR = 22
    local handleLen = 18
    local lineW = 4

    nvgSave(vg_)
    nvgTranslate(vg_, cx, cy)
    nvgRotate(vg_, angle)

    nvgBeginPath(vg_)
    nvgCircle(vg_, 0, 0, magR)
    nvgStrokeColor(vg_, nvgRGBA(255, 220, 140, 220))
    nvgStrokeWidth(vg_, lineW)
    nvgStroke(vg_)

    nvgBeginPath(vg_)
    nvgCircle(vg_, 0, 0, magR - lineW * 0.5)
    nvgFillColor(vg_, nvgRGBA(255, 230, 180, 30))
    nvgFill(vg_)

    nvgBeginPath(vg_)
    nvgMoveTo(vg_, magR * 0.7, magR * 0.7)
    nvgLineTo(vg_, magR * 0.7 + handleLen * 0.7, magR * 0.7 + handleLen * 0.7)
    nvgStrokeColor(vg_, nvgRGBA(200, 170, 110, 220))
    nvgStrokeWidth(vg_, lineW + 1)
    nvgLineCap(vg_, NVG_ROUND)
    nvgStroke(vg_)

    nvgRestore(vg_)

    -- 状态文字
    local dots = string.rep(".", (math.floor(t * 2) % 4))
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 28)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 160))
    nvgText(vg_, cx + 2, cy + 60 + 2, "正在匹配" .. dots)
    nvgFillColor(vg_, nvgRGBA(255, 213, 79, 255))
    nvgText(vg_, cx, cy + 60, "正在匹配" .. dots)

    -- 玩家槽位
    local totalSlots = Config.NumPlayers
    local slotSize = 40
    local slotGap = 16
    local slotTotalW = slotSize * totalSlots + slotGap * (totalSlots - 1)
    local slotStartX = cx - slotTotalW * 0.5
    local slotY = cy + 110

    for i = 1, totalSlots do
        local sx = slotStartX + (i - 1) * (slotSize + slotGap)
        local filled = i <= playerCount

        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, sx, slotY, slotSize, slotSize, 8)
        if filled then
            local pc = Config.PlayerColors[i]
            nvgFillColor(vg_, nvgRGBA(math.floor(pc.r * 255), math.floor(pc.g * 255), math.floor(pc.b * 255), 220))
        else
            nvgFillColor(vg_, nvgRGBA(60, 50, 110, 120))
        end
        nvgFill(vg_)

        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, sx, slotY, slotSize, slotSize, 8)
        if filled then
            nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 120))
        else
            local pulse = math.abs(math.sin(t * 3 + i * 0.8)) * 60 + 40
            nvgStrokeColor(vg_, nvgRGBA(61, 214, 232, math.floor(pulse)))
        end
        nvgStrokeWidth(vg_, 2)
        nvgStroke(vg_)

        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 14)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        if filled then
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
            local label = (i <= humanCount) and "玩家" or "AI"
            nvgText(vg_, sx + slotSize * 0.5, slotY + slotSize * 0.5, label)
        else
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))
            nvgText(vg_, sx + slotSize * 0.5, slotY + slotSize * 0.5, "?")
        end
    end

    -- 进度文字
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 136))
    nvgText(vg_, cx, slotY + slotSize + 10, playerCount .. " / " .. totalSlots .. " 玩家")

    -- ESC 提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))
    nvgText(vg_, cx, logH_ - 12, "按 ESC 取消匹配")
end

--- 与朋友玩子菜单
function HUD.DrawFriendMenu()
    drawOnlineBg()

    local clientMod = _G.ClientModule
    local cx = logW_ * 0.5
    local cy = logH_ * 0.35

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 36)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 120))
    nvgText(vg_, cx + 2, cy + 2, "与朋友玩")
    nvgFillColor(vg_, nvgRGBA(255, 213, 79, 255))
    nvgText(vg_, cx, cy, "与朋友玩")

    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    local btnW = 160
    local btnH = 52
    local btnGap = 20
    local totalW = btnW * 2 + btnGap
    local btnStartX = cx - totalW * 0.5
    local btnY = cy + 60

    -- 开房间
    local bx1 = btnStartX
    local h1 = mx >= bx1 and mx <= bx1 + btnW and my >= btnY and my <= btnY + btnH
    if HUD.DrawRubberButton(bx1, btnY, btnW, btnH, "开房间", 242, 160, 46, h1) then
        dbg_lastAction_ = "ACT:RequestCreateRoom"
        dbg_lastActionTime_ = os.clock()
        if clientMod then clientMod.RequestCreateRoom() end
    end

    -- 加入房间
    local bx2 = btnStartX + btnW + btnGap
    local h2 = mx >= bx2 and mx <= bx2 + btnW and my >= btnY and my <= btnY + btnH
    if HUD.DrawRubberButton(bx2, btnY, btnW, btnH, "加入房间", 46, 190, 86, h2) then
        dbg_lastAction_ = "ACT:EnterJoinRoom"
        dbg_lastActionTime_ = os.clock()
        if clientMod then clientMod.EnterJoinRoom() end
    end

    -- 返回按钮
    local backW = 100
    local backH = 40
    local backX = cx - backW * 0.5
    local backY = btnY + btnH + 30
    local hBack = mx >= backX and mx <= backX + backW and my >= backY and my <= backY + backH
    if HUD.DrawRubberButton(backX, backY, backW, backH, "返回", 120, 100, 90, hBack) then
        dbg_lastAction_ = "ACT:BackToMenu"
        dbg_lastActionTime_ = os.clock()
        if clientMod then clientMod.BackToMenu() end
    end

    -- 独立点击追踪（不依赖 DrawRubberButton 返回值）
    if cachedMousePress_ then
        local hitInfo = "MISS"
        if h1 then hitInfo = "HIT:开房间"
        elseif h2 then hitInfo = "HIT:加入房间"
        elseif hBack then hitInfo = "HIT:返回"
        end
        dbg_lastAction_ = "CLICK@" .. math.floor(mx) .. "," .. math.floor(my) .. " " .. hitInfo
        dbg_lastActionTime_ = os.clock()

        -- 显示按钮边界供核对
        dbg_lastAction_ = dbg_lastAction_ ..
            " btn1:[" .. math.floor(bx1) .. "-" .. math.floor(bx1+btnW) ..
            "," .. math.floor(btnY) .. "-" .. math.floor(btnY+btnH) .. "]"
    end

    -- 调试覆盖层
    HUD.DrawDebugOverlay()

    -- ESC 提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))
    nvgText(vg_, cx, logH_ - 12, "按 ESC 返回主菜单")
end

--- 房间等待页（房主和普通成员共用）
function HUD.DrawRoomWaiting()
    drawOnlineBg()

    local clientMod = _G.ClientModule
    local roomCode, playerCount, aiCount, total, isHost = "", 0, 0, 0, false
    if clientMod then
        roomCode, playerCount, aiCount, total, isHost = clientMod.GetRoomInfo()
    end

    local cx = logW_ * 0.5
    local cy = logH_ * 0.25

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 28)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 213, 79, 255))
    nvgText(vg_, cx, cy, isHost and "你的房间" or "等待房主开始")

    -- 房间码
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 48)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    local t = os.clock()
    local codeAlpha = math.floor(math.abs(math.sin(t * 1.5)) * 30 + 225)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, codeAlpha))
    nvgText(vg_, cx, cy + 50, roomCode)

    -- 房间码提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 136))
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgText(vg_, cx, cy + 78, "分享房间码给朋友")

    -- 玩家槽位
    local totalSlots = Config.NumPlayers
    local slotSize = 40
    local slotGap = 16
    local slotTotalW = slotSize * totalSlots + slotGap * (totalSlots - 1)
    local slotStartX = cx - slotTotalW * 0.5
    local slotY = cy + 110

    for i = 1, totalSlots do
        local sx = slotStartX + (i - 1) * (slotSize + slotGap)
        local filled = (i <= playerCount + aiCount)
        local isAI = (i > playerCount and filled)

        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, sx, slotY, slotSize, slotSize, 8)
        if filled then
            local pc = Config.PlayerColors[i]
            nvgFillColor(vg_, nvgRGBA(math.floor(pc.r * 255), math.floor(pc.g * 255), math.floor(pc.b * 255), 220))
        else
            nvgFillColor(vg_, nvgRGBA(42, 31, 94, 120))
        end
        nvgFill(vg_)

        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, sx, slotY, slotSize, slotSize, 8)
        nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, filled and 120 or 60))
        nvgStrokeWidth(vg_, 2)
        nvgStroke(vg_)

        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 13)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        if filled then
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
            nvgText(vg_, sx + slotSize * 0.5, slotY + slotSize * 0.5, isAI and "AI" or "P" .. i)
        else
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))
            nvgText(vg_, sx + slotSize * 0.5, slotY + slotSize * 0.5, "空位")
        end
    end

    -- 状态文字
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 136))
    nvgText(vg_, cx, slotY + slotSize + 10, total .. " / " .. totalSlots .. " 玩家")

    -- 按钮区域
    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    local btnY2 = slotY + slotSize + 40

    if isHost then
        -- 房主：开始游戏 / 添加 AI / 解散房间
        local btnW = 120
        local btnH = 44
        local btnGap2 = 14
        local totalBtnW = btnW * 3 + btnGap2 * 2
        local bsx = cx - totalBtnW * 0.5

        local b1x = bsx
        local b1h = mx >= b1x and mx <= b1x + btnW and my >= btnY2 and my <= btnY2 + btnH
        if HUD.DrawRubberButton(b1x, btnY2, btnW, btnH, "开始游戏", 242, 56, 46, b1h) then
            if clientMod then clientMod.RequestStartGame() end
        end

        local b2x = bsx + btnW + btnGap2
        local canAddAI = (total < Config.NumPlayers)
        local b2h = canAddAI and mx >= b2x and mx <= b2x + btnW and my >= btnY2 and my <= btnY2 + btnH
        if canAddAI then
            if HUD.DrawRubberButton(b2x, btnY2, btnW, btnH, "添加AI", 46, 190, 86, b2h) then
                if clientMod then clientMod.RequestAddAI() end
            end
        else
            HUD.DrawRubberButton(b2x, btnY2, btnW, btnH, "已满", 80, 70, 60, false)
        end

        local b3x = bsx + (btnW + btnGap2) * 2
        local b3h = mx >= b3x and mx <= b3x + btnW and my >= btnY2 and my <= btnY2 + btnH
        if HUD.DrawRubberButton(b3x, btnY2, btnW, btnH, "解散房间", 120, 100, 90, b3h) then
            if clientMod then clientMod.RequestDismissRoom() end
        end
    else
        -- 普通成员：离开房间
        local btnW = 120
        local btnH = 44
        local bx = cx - btnW * 0.5
        local bh = mx >= bx and mx <= bx + btnW and my >= btnY2 and my <= btnY2 + btnH
        if HUD.DrawRubberButton(bx, btnY2, btnW, btnH, "离开房间", 120, 100, 90, bh) then
            if clientMod then clientMod.RequestLeaveRoom() end
        end
    end

    -- ESC 提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))
    local escHint = isHost and "按 ESC 解散房间" or "按 ESC 离开房间"
    nvgText(vg_, cx, logH_ - 12, escHint)
end

--- 加入房间页（输入房间码）
function HUD.DrawRoomJoining()
    drawOnlineBg()

    local clientMod = _G.ClientModule
    local roomInput = ""
    if clientMod then
        roomInput = clientMod.GetRoomCodeInput()
    end

    local cx = logW_ * 0.5
    local cy = logH_ * 0.35

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 28)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 213, 79, 255))
    nvgText(vg_, cx, cy, "输入房间码")

    -- 输入框区域
    local codeLen = Config.RoomCodeLength
    local boxSize = 44
    local boxGap = 10
    local totalBoxW = boxSize * codeLen + boxGap * (codeLen - 1)
    local boxStartX = cx - totalBoxW * 0.5
    local boxY = cy + 50

    local t = os.clock()

    for i = 1, codeLen do
        local bx = boxStartX + (i - 1) * (boxSize + boxGap)
        local ch = i <= #roomInput and string.sub(roomInput, i, i) or ""
        local hasCh = (ch ~= "")
        local isCursor = (i == #roomInput + 1)

        -- 框背景
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, boxY, boxSize, boxSize, 8)
        nvgFillColor(vg_, nvgRGBA(42, 31, 94, 200))
        nvgFill(vg_)

        -- 框边框（当前输入位闪烁）
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, boxY, boxSize, boxSize, 8)
        if isCursor then
            local cursorA = math.floor(math.abs(math.sin(t * 4)) * 150 + 100)
            nvgStrokeColor(vg_, nvgRGBA(255, 213, 79, cursorA))
        elseif hasCh then
            nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 150))
        else
            nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 40))
        end
        nvgStrokeWidth(vg_, 2)
        nvgStroke(vg_)

        -- 字符
        if hasCh then
            nvgFontFace(vg_, "bold")
            nvgFontSize(vg_, 28)
            nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
            nvgText(vg_, bx + boxSize * 0.5, boxY + boxSize * 0.5, ch)
        end
    end

    -- 提示文字
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 14)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 136))
    nvgText(vg_, cx, boxY + boxSize + 12, "输入数字键，Backspace 删除，Enter 确认")

    -- 按钮
    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    local btnW = 120
    local btnH = 44
    local btnGap2 = 16
    local totalBtnW = btnW * 2 + btnGap2
    local btnStartX = cx - totalBtnW * 0.5
    local btnY = boxY + boxSize + 44

    -- 加入
    local b1x = btnStartX
    local b1h = mx >= b1x and mx <= b1x + btnW and my >= btnY and my <= btnY + btnH
    if HUD.DrawRubberButton(b1x, btnY, btnW, btnH, "加入", 46, 190, 86, b1h) then
        if clientMod then clientMod.RequestJoinRoom() end
    end

    -- 返回
    local b2x = btnStartX + btnW + btnGap2
    local b2h = mx >= b2x and mx <= b2x + btnW and my >= btnY and my <= btnY + btnH
    if HUD.DrawRubberButton(b2x, btnY, btnW, btnH, "返回", 120, 100, 90, b2h) then
        if clientMod then clientMod.EnterFriendMenu() end
    end

    -- ESC 提示
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 85))
    nvgText(vg_, cx, logH_ - 12, "按 ESC 返回")
end

return HUD

-- ============================================================================
-- HUD.lua - NanoVG 游戏 HUD（大地图攀登模式）
-- 显示：能量条、分数排行、倒计时、游戏计时器、结算画面、云端排行榜
-- 世界空间指示器：冲刺冷却环、爆炸警告区域
-- 使用 NanoVG Mode B（系统逻辑分辨率）
-- 设计令牌：Astroon v1.1.0 主题
-- ============================================================================

local Config = require("Config")
local Camera = require("Camera")
local Theme = require("Theme")
local RandomEvent = require("RandomEvent")
local ShopUI = require("ShopUI")
local Economy = require("Economy")
local CharacterClass = require("CharacterClass")

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
local uiScale_ = 1.0          -- UI 缩放因子（手机横屏≈0.5，桌面=1.0）
local isMobileHUD_ = false     -- 小屏幕标记（调整条目数、触摸目标等）

-- 字体句柄
local fontNormal_ = -1
local fontBold_ = -1
local fontCJK_ = -1

-- 模块引用（由 main 注入）
local playerModule_ = nil
local gameManager_ = nil

-- 菜单按钮点击结果
local menuButtonClicked_ = nil  -- "startGame" | "shop" | nil

-- 商店状态
local shopOpen_ = false

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
local renderDt_ = 0
-- 每个玩家的弹跳动画状态
local killBounceTimers_ = {}
for i = 1, Config.NumPlayers do killBounceTimers_[i] = 0 end
local KILL_BOUNCE_DURATION = 0.8

-- 浮动加分数字队列（在玩家头顶浮起的 +10、+50 等）
local scorePopups_ = {}
local SCORE_POPUP_DURATION = 1.2

-- ============================================================================
-- 玩家昵称系统
-- ============================================================================

-- 随机昵称池（模拟真实TapTap玩家取名风格）
local NICKNAME_POOL = {
    -- 纯英文/英文ID
    "Skywalker", "NoobMaster", "xDarkKnightx", "ProGamer99",
    "Shadow_X", "EzClap", "gg_wp", "Zephyr",
    "FLAVOR", "Neko", "Astro", "vvvv",
    "Lux", "RNGesus", "copium", "haxx0r",
    -- 默认昵称/数字ID（很多人不改名）
    "TapTap用户3847", "用户7291", "taptap_58023", "玩家62917",
    "user_38471", "tap_91204", "Guest_4826", "Player7750",
    -- 中英混搭
    "Zzz困了", "awsl太强", "rush冲冲冲", "carry全场",
    "duck不必", "gg开", "ez局", "afk挂机中",
    "solo王", "buff叠满", "lag卡了", "fps战士",
    -- 纯中文（少量）
    "摸鱼达人", "咸鱼", "懒得取名", "路过",
    "踏雪寻梅", "长安故人", "大橘", "柠檬茶",
    -- 带符号/特殊格式
    "____", "xXx_Pro_xXx", "★星辰★", "·暗影·",
    ".jpg", "404NotFound", "0x00FF", "nullptr",
    -- 简短随意
    "aaa", "qwer", "emm", "www",
    "6", "嗯", "ok", "test",
    -- 带数字的名字
    "小明2号", "zero0", "player1", "第5人",
    "3cm", "7号", "No.13", "R2D2",
}
local playerNicknames_ = {}  -- [playerIndex] = "昵称"

--- 为所有玩家分配昵称
local function assignNicknames()
    playerNicknames_ = {}
    playerNicknames_[1] = "你"  -- 默认先显示"你"，异步获取TapTap昵称后替换

    -- 异步获取当前用户的 TapTap 昵称
    if clientCloud and clientCloud.userId then
        GetUserNickname({
            userIds = { clientCloud.userId },
            onSuccess = function(nicknames)
                if nicknames and #nicknames > 0 then
                    local nick = nicknames[1].nickname
                    if nick and nick ~= "" then
                        playerNicknames_[1] = nick
                        print("[HUD] Player nickname: " .. nick)
                    end
                end
            end,
            onError = function(errorCode)
                print("[HUD] Failed to get user nickname, keeping default")
            end
        })
    end

    -- 打乱昵称池（Fisher-Yates）
    local pool = {}
    for i, name in ipairs(NICKNAME_POOL) do pool[i] = name end
    for i = #pool, 2, -1 do
        local j = math.random(1, i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    -- 为 AI 分配不重复昵称
    for i = 2, Config.NumPlayers do
        playerNicknames_[i] = pool[((i - 2) % #pool) + 1]
    end
end

-- ============================================================================
-- 状态反馈浮字系统（砸晕/爆炸文字）
-- ============================================================================

local statusFloats_ = {}        -- 世界空间浮字列表
local STATUS_FLOAT_DURATION = 1.5
-- 每个玩家上一帧的状态快照（用于检测状态变化）
local prevPlayerStates_ = {}    -- [playerIndex] = { stunTimer, charging, explodeRecovery }

--- 添加状态反馈浮字
---@param worldX number
---@param worldY number
---@param text string
---@param r number 颜色 R (0-255)
---@param g number 颜色 G
---@param b number 颜色 B
---@param fontSize number|nil
local function addStatusFloat(worldX, worldY, text, r, g, b, fontSize)
    table.insert(statusFloats_, {
        wx = worldX, wy = worldY,
        text = text,
        r = r or 255, g = g or 255, b = b or 50,
        fontSize = fontSize or 18,
        startTime = time.elapsedTime,
        duration = STATUS_FLOAT_DURATION,
    })
end

--- 检测玩家状态变化并生成浮字
local function detectPlayerStateChanges()
    if playerModule_ == nil then return end
    for _, p in ipairs(playerModule_.list) do
        if p.alive and p.node then
            local prev = prevPlayerStates_[p.index]
            if prev == nil then
                prev = { stunTimer = 0, charging = false, explodeRecovery = 0 }
                prevPlayerStates_[p.index] = prev
            end
            local pos = p.node.position

            -- 被砸晕：stunTimer 从 0 变为 >0
            if p.stunTimer > 0 and prev.stunTimer <= 0 then
                addStatusFloat(pos.x, pos.y + 1.0, "砸晕！",
                    Theme.warning[1], Theme.warning[2], Theme.warning[3], 22)
            end

            -- 爆炸释放：explodeRecovery 从 0 变为 >0
            if p.explodeRecovery > 0 and prev.explodeRecovery <= 0 then
                addStatusFloat(pos.x, pos.y + 1.2, "超级红温！",
                    Theme.error[1], Theme.error[2], Theme.error[3], 26)
            end

            -- 更新快照
            prev.stunTimer = p.stunTimer
            prev.charging = p.charging
            prev.explodeRecovery = p.explodeRecovery
        end
    end
end

--- 添加浮动加分数字（供外部调用）
---@param worldX number 世界坐标 X
---@param worldY number 世界坐标 Y
---@param text string 显示文字（如 "+50"）
---@param r number 颜色 R（0-255）
---@param g number 颜色 G
---@param b number 颜色 B
---@param fontSize number|nil 字号（默认 20）
function HUD.AddScorePopup(worldX, worldY, text, r, g, b, fontSize)
    table.insert(scorePopups_, {
        wx = worldX, wy = worldY,
        text = text,
        r = r or 255, g = g or 255, b = b or 50,
        fontSize = fontSize or 20,
        startTime = time.elapsedTime,
        duration = SCORE_POPUP_DURATION,
    })
end

-- 云端排行榜缓存
local cloudLeaderboard_ = nil
local cloudLeaderboardLoading_ = false
local cloudScoreSubmitted_ = false

-- 今日排行榜缓存
local dailyLeaderboard_ = nil
local dailyLeaderboardLoading_ = false

-- 菜单排行榜 tab: "history" 或 "daily"
local menuLeaderboardTab_ = "history"
-- 菜单是否已加载过排行榜
local menuLeaderboardLoaded_ = false
-- 菜单排行榜滚动偏移（手机端）
local menuScrollY_ = 0
local menuScrollTouchId_ = nil  -- 跟踪中的触摸 ID
local menuScrollLastY_ = 0     -- 上一帧触摸 Y
local menuScrollVel_ = 0       -- 滚动惯性速度

-- ============================================================================
-- 便利：Theme 颜色快捷方法
-- ============================================================================

--- 用 Theme 颜色设置 NanoVG 填充色
local function fillTheme(token, alpha)
    nvgFillColor(vg_, nvgRGBA(Theme.rgba(token, alpha)))
end

--- 用 Theme 颜色设置 NanoVG 描边色
local function strokeTheme(token, alpha)
    nvgStrokeColor(vg_, nvgRGBA(Theme.rgba(token, alpha)))
end

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
    -- 阿里妈妈方圆体（VF 已转换为静态字体，覆盖英文+中文）
    fontNormal_ = nvgCreateFont(vg_, "sans", "Fonts/AlimamaFangYuanTi-Static.ttf")
    fontBold_ = nvgCreateFont(vg_, "bold", "Fonts/AlimamaFangYuanTi-Static.ttf")
    fontCJK_ = fontNormal_

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

    -- 分配玩家昵称
    assignNicknames()

    -- 订阅渲染事件
    SubscribeToEvent(vg_, "NanoVGRender", "HandleNanoVGRender")
    SubscribeToEvent("ScreenMode", "HandleScreenMode_HUD")

    print("[HUD] Initialized (Astroon Theme)")
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

--- 设置商店打开/关闭状态
function HUD.SetShopOpen(open)
    shopOpen_ = open
    if open then
        ShopUI.Reset()
    end
end

--- 获取商店是否打开
function HUD.IsShopOpen()
    return shopOpen_
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
    uiScale_ = math.min(1.0, logH_ / 720)   -- 手机横屏 logH≈360 → 0.5
    isMobileHUD_ = (logH_ < 500)
end

-- ============================================================================
-- 通用绘制工具
-- ============================================================================

--- 绘制毛玻璃面板背景（深紫底 + 微光边框 + 圆角）
local function drawPanel(x, y, w, h, cornerR, alpha)
    cornerR = cornerR or Theme.radiusMd
    alpha = alpha or 200

    -- 面板阴影
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x + 1, y + 2, w, h, cornerR)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.4)))
    nvgFill(vg_)

    -- 面板主体（深紫表面）
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.surface, alpha)))
    nvgFill(vg_)

    -- 顶部微光渐变
    local glossPaint = nvgLinearGradient(vg_, x, y, x, y + h * 0.35,
        nvgRGBA(255, 255, 255, 12), nvgRGBA(255, 255, 255, 0))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillPaint(vg_, glossPaint)
    nvgFill(vg_)

    -- 边框微光
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgStrokeColor(vg_, nvgRGBA(Theme.rgba(Theme.border, 40)))
    nvgStrokeWidth(vg_, 1.0)
    nvgStroke(vg_)
end

-- ============================================================================
-- 渲染
-- ============================================================================

function HandleNanoVGRender(eventType, eventData)
    if vg_ == nil then return end

    -- 计算帧间隔（用于浮动文字动画）
    local now = time.elapsedTime
    local renderDt = now - lastRenderTime_
    if renderDt > 0.1 then renderDt = 0.016 end
    lastRenderTime_ = now
    renderDt_ = renderDt

    -- 更新浮动文字计时
    HUD.UpdateKillFloats(renderDt)

    nvgBeginFrame(vg_, logW_, logH_, dpr_)

    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_
    local state = gameManager_ and gameManager_.state or "playing"

    -- 主菜单 / 商店
    if state == "menu" then
        if shopOpen_ then
            ShopUI.Draw(vg_, logW_, logH_, uiScale_, isMobileHUD_, cachedMousePress_, mx, my)
            local shopBtn = ShopUI.GetButtonClicked()
            if shopBtn == "back" then
                shopOpen_ = false
            end
        else
            HUD.DrawMenu()
        end
        nvgEndFrame(vg_)
        return
    end

    -- 背景叠加（所有游戏状态共用）
    HUD.DrawBackground()

    -- 世界空间指示器（在 HUD 元素下面绘制）
    if state == "playing" then
        HUD.DrawWorldIndicators()
        HUD.DrawAIDebug()
    end

    -- HUD 元素
    HUD.DrawEnergyBars()

    if state == "playing" or state == "countdown" then
        HUD.DrawPlayerScore()
        HUD.DrawScoreRankings()
    end

    if state == "playing" then
        HUD.DrawGameTimer()
        HUD.DrawHeightIndicator()
        RandomEvent.DrawAnnouncement(vg_, logW_, logH_)
    end

    -- 消费击杀事件 + 绘制浮动文字
    HUD.ConsumeKillEvents()
    HUD.DrawKillFloatTexts()
    HUD.DrawScorePopups()

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
-- 背景（已移至 3D 场景层，NanoVG 不再绘制山丘以避免遮挡游戏元素）
-- ============================================================================

function HUD.DrawBackground()
    -- 山丘由 3D 背景平面渲染，NanoVG 层不再绘制
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

    -- 检测状态变化并生成浮字
    detectPlayerStateChanges()

    for _, p in ipairs(playerModule_.list) do
        if p.alive and p.node then
            local pos = p.node.position
            local pc = Config.GetPlayerColor(p.index)
            local pr = math.floor(pc.r * 255)
            local pg = math.floor(pc.g * 255)
            local pb = math.floor(pc.b * 255)

            -- ----- 玩家昵称（头顶上方） -----
            local nameY = pos.y + 1.1
            local nsx, nsy = Camera.WorldToScreen(pos.x, nameY, logW_, logH_)
            local nickname = playerNicknames_[p.index] or ("P" .. p.index)
            local nameFontSize = Camera.WorldSizeToScreen(0.3, logH_)
            nameFontSize = math.max(8, math.min(14, nameFontSize))

            nvgFontFace(vg_, "sans")
            nvgFontSize(vg_, nameFontSize)
            nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)

            -- 名牌背景胶囊
            local nameW = nvgTextBounds(vg_, 0, 0, nickname)
            local padX, padY = 5, 2
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, nsx - nameW * 0.5 - padX, nsy - nameFontSize - padY,
                nameW + padX * 2, nameFontSize + padY * 2, 4)
            nvgFillColor(vg_, nvgRGBA(0, 0, 0, 120))
            nvgFill(vg_)

            -- 名字文字（自己红色，其他白色）
            if p.isHuman then
                nvgFillColor(vg_, nvgRGBA(255, 75, 75, 240))
            else
                nvgFillColor(vg_, nvgRGBA(255, 255, 255, 220))
            end
            nvgText(vg_, nsx, nsy, nickname)

            -- ----- 人类玩家标识箭头（▼ + 光晕） -----
            if p.isHuman then
                local arrowY = nameY + 0.4
                local asx, asy = Camera.WorldToScreen(pos.x, arrowY, logW_, logH_)
                local arrowSize = math.max(6, Camera.WorldSizeToScreen(0.2, logH_))

                -- 光晕（脉冲呼吸效果）
                local pulse = math.abs(math.sin(time.elapsedTime * 2.5)) * 0.4 + 0.6
                local glowR = arrowSize * 2.5
                local glowPaint = nvgRadialGradient(vg_, asx, asy, arrowSize * 0.5, glowR,
                    nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], math.floor(pulse * 80)),
                    nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], 0))
                nvgBeginPath(vg_)
                nvgCircle(vg_, asx, asy, glowR)
                nvgFillPaint(vg_, glowPaint)
                nvgFill(vg_)

                -- 下指三角箭头（金色）
                nvgBeginPath(vg_)
                nvgMoveTo(vg_, asx - arrowSize, asy - arrowSize * 0.4)
                nvgLineTo(vg_, asx + arrowSize, asy - arrowSize * 0.4)
                nvgLineTo(vg_, asx, asy + arrowSize * 0.8)
                nvgClosePath(vg_)
                nvgFillColor(vg_, nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3],
                    math.floor(pulse * 255)))
                nvgFill(vg_)
                -- 描边
                nvgStrokeColor(vg_, nvgRGBA(0, 0, 0, 160))
                nvgStrokeWidth(vg_, 1.5)
                nvgStroke(vg_)
            end

            -- ----- 冲刺冷却环 -----
            if p.dashCooldown > 0 then
                local headY = pos.y + 0.8
                local sx, sy = Camera.WorldToScreen(pos.x, headY, logW_, logH_)
                local ringRadius = Camera.WorldSizeToScreen(0.35, logH_)
                if ringRadius < 4 then ringRadius = 4 end

                local progress = 1.0 - (p.dashCooldown / (p.dashCooldownMax or Config.DashCooldown))
                progress = math.max(0, math.min(1, progress))

                -- 背景环（深紫灰）
                nvgBeginPath(vg_)
                nvgArc(vg_, sx, sy, ringRadius, 0, math.pi * 2, NVG_CW)
                nvgStrokeColor(vg_, nvgRGBA(Theme.rgba(Theme.surface, 120)))
                nvgStrokeWidth(vg_, 2.5)
                nvgStroke(vg_)

                -- 进度环（青色）
                if progress > 0.01 then
                    local startAngle = -math.pi * 0.5
                    local endAngle = startAngle + math.pi * 2 * progress
                    nvgBeginPath(vg_)
                    nvgArc(vg_, sx, sy, ringRadius, startAngle, endAngle, NVG_CW)
                    nvgStrokeColor(vg_, nvgRGBA(Theme.rgba(Theme.accent, 200)))
                    nvgStrokeWidth(vg_, 2.5)
                    nvgStroke(vg_)
                end
            end

            -- ----- 蓄力警告区域 + "红温中" 文字 -----
            if p.charging then
                local sx, sy = Camera.WorldToScreen(pos.x, pos.y, logW_, logH_)
                local maxWorldRadius = Config.ExplosionRadius * Config.BlockSize
                local currentWorldRadius = maxWorldRadius * p.chargeProgress
                local screenRadius = Camera.WorldSizeToScreen(currentWorldRadius, logH_)

                local freq = 4 + p.chargeProgress * 12
                local pulse = math.abs(math.sin(time.elapsedTime * freq)) * 0.4 + 0.2

                local fillAlpha = math.floor(52 + pulse * 127)
                nvgBeginPath(vg_)
                nvgCircle(vg_, sx, sy, screenRadius)
                nvgFillColor(vg_, nvgRGBA(pr, pg, pb, fillAlpha))
                nvgFill(vg_)

                local strokeAlpha = math.floor(pulse * 200 + 55 + p.chargeProgress * 80)
                drawDashedCircle(sx, sy, screenRadius, pr, pg, pb,
                    math.min(255, strokeAlpha), 2.0)

                -- "红温中" 浮字（在蓄力圆圈上方）
                local chargeTextY = pos.y + 1.6
                local ctx, cty = Camera.WorldToScreen(pos.x, chargeTextY, logW_, logH_)
                local ctSize = math.max(12, math.min(20, Camera.WorldSizeToScreen(0.35, logH_)))
                local ctPulse = math.abs(math.sin(time.elapsedTime * 6)) * 0.3 + 0.7

                nvgFontFace(vg_, "bold")
                nvgFontSize(vg_, ctSize)
                nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                -- 阴影
                nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(ctPulse * 180)))
                nvgText(vg_, ctx + 1, cty + 1, "红温中")
                -- 红色闪烁文字
                nvgFillColor(vg_, nvgRGBA(Theme.error[1], Theme.error[2], Theme.error[3],
                    math.floor(ctPulse * 255)))
                nvgText(vg_, ctx, cty, "红温中")
            end

            -- ----- 眩晕文字（持续显示） -----
            if p.stunTimer > 0 then
                local stunTextY = pos.y + 1.3
                local stx, sty = Camera.WorldToScreen(pos.x, stunTextY, logW_, logH_)
                local stSize = math.max(10, math.min(16, Camera.WorldSizeToScreen(0.28, logH_)))
                local wobble = math.sin(time.elapsedTime * 8) * 3

                nvgFontFace(vg_, "bold")
                nvgFontSize(vg_, stSize)
                nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
                nvgText(vg_, stx + 1 + wobble, sty + 1, "💫")
                nvgFillColor(vg_, nvgRGBA(Theme.warning[1], Theme.warning[2], Theme.warning[3], 220))
                nvgText(vg_, stx + wobble, sty, "💫")
            end
        end
    end

    -- ----- 状态反馈浮字（砸晕！/超级红温！） -----
    HUD.DrawStatusFloats()

    -- ----- 被炸方块虚线轮廓 + 重生进度条 -----
    HUD.DrawDestroyedBlockGhosts()
end

--- 绘制状态反馈浮字（砸晕/爆炸触发的一次性浮字）
function HUD.DrawStatusFloats()
    local now = time.elapsedTime
    local i = 1
    while i <= #statusFloats_ do
        local sf = statusFloats_[i]
        local elapsed = now - sf.startTime
        if elapsed >= sf.duration then
            table.remove(statusFloats_, i)
        else
            local progress = elapsed / sf.duration
            local floatUpY = sf.wy + progress * 2.0
            local sx, sy = Camera.WorldToScreen(sf.wx, floatUpY, logW_, logH_)

            -- 淡出
            local alpha = 1.0
            if progress > 0.5 then
                alpha = 1.0 - (progress - 0.5) / 0.5
            end

            -- 弹出缩放
            local scale = 1.0
            if progress < 0.15 then
                local t = progress / 0.15
                scale = 1.8 - 0.8 * t
            end

            -- 抖动效果（前30%）
            local shakeX = 0
            if progress < 0.3 then
                shakeX = math.sin(progress * 60) * (1.0 - progress / 0.3) * 3
            end

            local fontSize = sf.fontSize * scale

            nvgFontFace(vg_, "bold")
            nvgFontSize(vg_, fontSize)
            nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

            -- 阴影
            nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 200)))
            nvgText(vg_, sx + 1 + shakeX, sy + 1, sf.text)
            -- 彩色文字
            nvgFillColor(vg_, nvgRGBA(sf.r, sf.g, sf.b, math.floor(alpha * 255)))
            nvgText(vg_, sx + shakeX, sy, sf.text)

            i = i + 1
        end
    end
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
        local alpha = 80 + math.floor(math.abs(math.sin(time.elapsedTime * 3 + info.x * 0.7)) * 40)

        -- 虚线轮廓（淡紫白）
        nvgStrokeColor(vg_, nvgRGBA(200, 200, 240, alpha))
        nvgStrokeWidth(vg_, 2.5)
        HUD.DrawDashedRoundedRect(drawX, drawY, drawSize, drawSize, cornerR, dashLen, gapLen)

        local segments = HUD.GetRoundedRectSegments(drawX, drawY, drawSize, drawSize, cornerR)
        local totalPerim = 0
        for _, seg in ipairs(segments) do totalPerim = totalPerim + seg.len end
        local filledPerim = totalPerim * progress

        if filledPerim > 0.5 then
            local pAlpha = 160 + math.floor(progress * 95)
            -- 进度环（青色）
            nvgStrokeColor(vg_, nvgRGBA(Theme.rgba(Theme.accent, pAlpha)))
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
    { 0.30, 0.70, 1.00 },
    { 1.00, 0.40, 0.40 },
    { 0.40, 0.95, 0.50 },
    { 1.00, 0.85, 0.30 },
    { 0.85, 0.50, 0.90 },
    { 1.00, 0.65, 0.30 },
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
                nvgBeginPath(vg_)
                nvgMoveTo(vg_, points[1].x, points[1].y)
                for i = 2, #points do
                    nvgLineTo(vg_, points[i].x, points[i].y)
                end
                nvgStrokeColor(vg_, nvgRGBA(0, 0, 0, 220))
                nvgStrokeWidth(vg_, 8)
                nvgStroke(vg_)

                nvgBeginPath(vg_)
                nvgMoveTo(vg_, points[1].x, points[1].y)
                for i = 2, #points do
                    nvgLineTo(vg_, points[i].x, points[i].y)
                end
                nvgStrokeColor(vg_, nvgRGBA(r, g, b, 255))
                nvgStrokeWidth(vg_, 5)
                nvgStroke(vg_)

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
    nvgText(vg_, 13, 13, "[G] AI ON")
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    nvgText(vg_, 12, 12, "[G] AI ON")
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
        local color = Config.GetPlayerColor(p.index)
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

        -- 背景（深紫）
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, barW, barH, cornerR)
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.bg, 200)))
        nvgFill(vg_)

        -- 能量填充
        local fillW = barW * math.min(1, p.energy)
        if fillW > 0.5 then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, bx, by, fillW, barH, cornerR)
            if p.energy >= 1.0 then
                -- 满能量 = 红色脉冲
                local pulse = math.abs(math.sin(time.elapsedTime * 4)) * 55 + 200
                nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.error, math.floor(pulse))))
            else
                -- 充能中 = 蓝色
                nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.secondary, 210)))
            end
            nvgFill(vg_)
        end

        -- 边框微光
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, barW, barH, cornerR)
        nvgStrokeColor(vg_, nvgRGBA(Theme.rgba(Theme.border, 50)))
        nvgStrokeWidth(vg_, 1.0)
        nvgStroke(vg_)

        ::continueBar::
    end
end

--- 绘制实时分数排行（右上角，带面板背景）
function HUD.DrawScoreRankings()
    if gameManager_ == nil or playerModule_ == nil then return end

    local allRankings = gameManager_.GetRankings()
    local s = uiScale_
    -- 手机只显示前5名，桌面前10名
    local maxShow = isMobileHUD_ and 5 or 10
    local rankings = {}
    for i = 1, math.min(maxShow, #allRankings) do
        rankings[i] = allRankings[i]
    end

    -- 手机端紧凑排行（仅排名+名字+分数，单行显示）
    local fontSize = math.max(10, math.floor(13 * s))
    local lineH = math.max(16, math.floor(22 * s))
    local headerH = math.max(16, math.floor(20 * s))
    local padX = math.max(6, math.floor(8 * s))
    local panelW = math.max(90, math.floor(140 * s))
    local panelH = headerH + #rankings * lineH + 4
    local panelX = logW_ - panelW - math.max(6, math.floor(10 * s))
    local panelY = math.max(6, math.floor(10 * s))

    -- 面板背景
    drawPanel(panelX, panelY, panelW, panelH, Theme.radiusMd, 180)

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.max(9, math.floor(11 * s)))
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    fillTheme(Theme.primary, 220)
    nvgText(vg_, panelX + panelW * 0.5, panelY + math.floor(3 * s), "排行")

    for rank, entry in ipairs(rankings) do
        local y = panelY + headerH + (rank - 1) * lineH
        local color = Config.GetPlayerColor(entry.index)
        local r = math.floor(color.r * 255)
        local g = math.floor(color.g * 255)
        local b = math.floor(color.b * 255)

        -- P1 行高亮
        if entry.index == 1 then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, panelX + 3, y, panelW - 6, lineH - 1, 3)
            nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.primary, 25)))
            nvgFill(vg_)
        end

        -- 排名+名字
        local label = playerNicknames_[entry.index] or ("P" .. entry.index)
        -- 手机端截短名称
        local maxNameLen = isMobileHUD_ and 6 or 12
        if #label > maxNameLen then label = label:sub(1, maxNameLen - 1) .. "." end

        nvgFontFace(vg_, entry.index == 1 and "bold" or "sans")
        nvgFontSize(vg_, fontSize)
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        if rank <= 3 then
            nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        else
            nvgFillColor(vg_, nvgRGBA(r, g, b, 200))
        end
        nvgText(vg_, panelX + padX, y + 2, "#" .. rank .. " " .. label)

        -- 分数（右对齐）
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, fontSize)
        nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
        nvgFillColor(vg_, nvgRGBA(r, g, b, 255))
        nvgText(vg_, panelX + panelW - padX, y + 2, tostring(entry.score))
    end
end

--- 绘制游戏计时器（顶部中央，药丸形状）
function HUD.DrawGameTimer()
    if gameManager_ == nil then return end

    local remaining = gameManager_.GetGameTime()
    local minutes = math.floor(remaining / 60)
    local seconds = math.floor(remaining % 60)
    local timeStr = string.format("%d:%02d", minutes, seconds)

    local s = uiScale_
    local tw = math.max(60, math.floor(90 * s))
    local th = math.max(24, math.floor(34 * s))
    local tx = (logW_ - tw) * 0.5
    local ty = math.max(6, math.floor(10 * s))

    local isUrgent = remaining <= 10

    -- 面板背景
    if isUrgent then
        local pulse = math.abs(math.sin(time.elapsedTime * 3)) * 0.3 + 0.7
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, tx, ty, tw, th, Theme.radiusPill)
        nvgFillColor(vg_, nvgRGBA(Theme.error[1], Theme.error[2], Theme.error[3], math.floor(pulse * 220)))
        nvgFill(vg_)
    else
        drawPanel(tx, ty, tw, th, Theme.radiusPill, 200)
    end

    -- 时间图标（小圆 + 指针）
    local iconR = math.max(4, math.floor(6 * s))
    local iconX = tx + math.floor(16 * s)
    local iconY = ty + th * 0.5
    nvgBeginPath(vg_)
    nvgCircle(vg_, iconX, iconY, iconR)
    nvgStrokeColor(vg_, nvgRGBA(Theme.rgba(isUrgent and Theme.text or Theme.accent, 200)))
    nvgStrokeWidth(vg_, math.max(1, 1.5 * s))
    nvgStroke(vg_)
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, iconX, iconY - 1)
    nvgLineTo(vg_, iconX, iconY - iconR * 0.7)
    nvgMoveTo(vg_, iconX, iconY)
    nvgLineTo(vg_, iconX + iconR * 0.5, iconY + 1)
    nvgStroke(vg_)

    -- 时间文字
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.max(13, math.floor(20 * s)))
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    if isUrgent then
        fillTheme(Theme.text, 255)
    else
        fillTheme(Theme.text, 240)
    end
    nvgText(vg_, tx + tw * 0.5 + math.floor(6 * s), ty + th * 0.5, timeStr)
end

--- 绘制高度指示器（左下角）
function HUD.DrawHeightIndicator()
    if playerModule_ == nil then return end

    local p1 = playerModule_.list[1]
    if not p1 or not p1.node then return end

    local currentY = p1.node.position.y
    local maxH = p1.maxHeight or 0
    local heightBlocks = math.floor(currentY / Config.BlockSize)
    local maxBlocks = math.floor(maxH / Config.BlockSize)

    -- 手机端与得分面板使用相同的放大系数
    local s = isMobileHUD_ and (uiScale_ * 1.8) or uiScale_
    local pw = math.floor(100 * s)   -- 宽度与得分面板一致
    local ph = math.floor(44 * s)
    -- 得分面板底部位置（使用相同的 s）
    local scorePanelBottom = math.floor(10 * s) + math.floor(50 * s)
    local x = math.floor(10 * s)
    local y = scorePanelBottom + math.floor(6 * s)

    drawPanel(x, y, pw, ph, Theme.radiusMd, 180)

    -- 上箭头图标
    local arrX = x + math.floor(10 * s)
    local arrY = y + math.floor(16 * s)
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, arrX, arrY)
    nvgLineTo(vg_, arrX + math.floor(5 * s), arrY - math.floor(7 * s))
    nvgLineTo(vg_, arrX + math.floor(10 * s), arrY)
    nvgStrokeColor(vg_, nvgRGBA(Theme.rgba(Theme.accent, 200)))
    nvgStrokeWidth(vg_, math.max(1, 2 * s))
    nvgStroke(vg_)

    -- 当前高度
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.max(12, math.floor(18 * s)))
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    fillTheme(Theme.text, 240)
    nvgText(vg_, arrX + math.floor(14 * s), y + math.floor(6 * s), tostring(heightBlocks))

    -- "最高" 标签
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, math.max(10, math.floor(12 * s)))
    fillTheme(Theme.primary, 180)
    nvgText(vg_, x + math.floor(8 * s), y + math.floor(26 * s), "最高 " .. maxBlocks)
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
        if killerIdx ~= 1 then goto continueEvt end

        -- 计算显示用 killBonus（与 Player.lua 逻辑一致）
        local p1 = playerModule_ and playerModule_.list[1]
        local cpBonus = p1 and (p1.killScoreBonus or 0) or 0
        local killBonus = Config.KillScoreBase + cpBonus
        local multiBonusUnit = Config.MultiKillBonus[2] or 50
        if multiKill >= 2 then
            killBonus = killBonus + multiKill * multiBonusUnit
        end

        local pc = Config.GetPlayerColor(killerIdx)
        local cr = math.floor(pc.r * 255)
        local cg = math.floor(pc.g * 255)
        local cb = math.floor(pc.b * 255)

        local killText = Config.MultiKillTexts[multiKill] or Config.MultiKillTexts[1] or "击杀!"
        if multiKill > 5 then killText = Config.MultiKillTexts[5] end
        local displayText = killText .. " +" .. killBonus
        table.insert(killFloatTexts_, {
            text = displayText,
            r = cr, g = cg, b = cb,
            startTime = time.elapsedTime,
            duration = KILL_FLOAT_DURATION,
            kind = multiKill >= 2 and "multi" or "single",
        })

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
                    r = Theme.primary[1], g = Theme.primary[2], b = Theme.primary[3],
                    startTime = time.elapsedTime,
                    duration = KILL_FLOAT_DURATION,
                    kind = "streak",
                })
            end
        end

        ::continueEvt::
    end

    gameManager_.killEvents = {}

    -- 消费检查点击杀加成事件
    if gameManager_.checkpointBonusEvents then
        for _, evt in ipairs(gameManager_.checkpointBonusEvents) do
            if evt.playerIndex == 1 then
                table.insert(killFloatTexts_, {
                    text = "击杀基础分 +" .. 10,
                    r = Theme.accent[1], g = Theme.accent[2], b = Theme.accent[3],
                    startTime = time.elapsedTime,
                    duration = KILL_FLOAT_DURATION,
                    kind = "streak",
                })
            end
        end
        gameManager_.checkpointBonusEvents = {}
    end
end

--- 更新动效计时器
function HUD.UpdateKillFloats(dt)
    local now = time.elapsedTime
    local i = 1
    while i <= #killFloatTexts_ do
        local ft = killFloatTexts_[i]
        local elapsed = now - ft.startTime
        if elapsed >= ft.duration then
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

--- 绘制左上角玩家总分（带面板背景）
function HUD.DrawPlayerScore()
    if playerModule_ == nil then return end
    local p1 = playerModule_.list[1]
    if not p1 then return end

    -- 手机端面板和字体放大（uiScale_≈0.5 太小），PC 端不变
    local s = isMobileHUD_ and (uiScale_ * 1.8) or uiScale_
    local pw = math.floor(100 * s)
    local ph = math.floor(50 * s)
    local x = math.floor(10 * s)
    local y = math.floor(10 * s)

    drawPanel(x, y, pw, ph, Theme.radiusMd, 180)

    -- "得分" 标签
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.max(10, math.floor(13 * s)))
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    fillTheme(Theme.accent, 180)
    nvgText(vg_, x + math.floor(8 * s), y + math.floor(6 * s), "得分")

    -- 分数数字（金色渐变效果模拟）
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.max(16, math.floor(24 * s)))
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    -- 阴影
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 120))
    nvgText(vg_, x + math.floor(9 * s), y + math.floor(22 * s), tostring(p1.score))
    -- 主文字（金色）
    fillTheme(Theme.primary, 255)
    nvgText(vg_, x + math.floor(8 * s), y + math.floor(21 * s), tostring(p1.score))
end

--- 绘制左上角击杀面板
function HUD.DrawKillScorePanel()
    if gameManager_ == nil or playerModule_ == nil then return end

    local panelX = 12
    local panelY = 12

    if HUD.aiDebugVisible then
        panelY = 32
    end

    local lineH = 22
    local headerH = 20
    local panelW = 120

    local totalH = headerH + Config.NumPlayers * lineH + 4
    drawPanel(panelX - 4, panelY - 4, panelW + 8, totalH + 8, Theme.radiusMd, 180)

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    fillTheme(Theme.primary, 200)
    nvgText(vg_, panelX, panelY, "击杀")

    for i = 1, Config.NumPlayers do
        local y = panelY + headerH + (i - 1) * lineH
        local pc = Config.GetPlayerColor(i)
        local r = math.floor(pc.r * 255)
        local g = math.floor(pc.g * 255)
        local b = math.floor(pc.b * 255)

        local p = playerModule_.list[i]
        local killPts = p and p.killScore or 0

        -- 玩家色块
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, panelX, y + 3, 10, 10, 3)
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

        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 13)
        local label = playerNicknames_[i] or ("P" .. i)
        -- 截断过长昵称（面板空间有限）
        if #label > 12 then label = string.sub(label, 1, 12) end
        nvgFillColor(vg_, nvgRGBA(r, g, b, 220))
        nvgText(vg_, panelX + 14, y + 9, label)

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

            nvgFillColor(vg_, nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], math.floor(plusAlpha * 80)))
            nvgText(vg_, numX + 22 + plusOffX + 1, numY + plusOffY + 1, "+")
            nvgFillColor(vg_, nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], math.floor(plusAlpha * 255)))
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
        local progress = (time.elapsedTime - ft.startTime) / ft.duration

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
-- 世界空间加分浮动数字
-- ============================================================================

function HUD.DrawScorePopups()
    local now = time.elapsedTime
    local i = 1
    while i <= #scorePopups_ do
        local sp = scorePopups_[i]
        local elapsed = now - sp.startTime
        if elapsed >= sp.duration then
            table.remove(scorePopups_, i)
        else
            local progress = elapsed / sp.duration
            local floatY = sp.wy + progress * 1.5
            local sx, sy = Camera.WorldToScreen(sp.wx, floatY, logW_, logH_)

            local alpha = 1.0
            if progress > 0.6 then
                alpha = 1.0 - (progress - 0.6) / 0.4
            end

            local scale = 1.0
            if progress < 0.2 then
                scale = 1.5 - 0.5 * (progress / 0.2)
            end

            local fontSize = sp.fontSize * scale

            nvgFontFace(vg_, "bold")
            nvgFontSize(vg_, fontSize)
            nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

            nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 200)))
            nvgText(vg_, sx + 1, sy + 1, sp.text)

            nvgFillColor(vg_, nvgRGBA(sp.r, sp.g, sp.b, math.floor(alpha * 255)))
            nvgText(vg_, sx, sy, sp.text)

            i = i + 1
        end
    end
end

-- ============================================================================
-- 状态覆盖层
-- ============================================================================

--- 倒计时覆盖层（深紫渐变 + 金色数字）
function HUD.DrawCountdown()
    if gameManager_ == nil then return end

    -- 半透明深紫覆盖
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.bg, 120)))
    nvgFill(vg_)

    local num = gameManager_.GetCountdownNumber()

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 120)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 阴影
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, logW_ * 0.5 + 3, logH_ * 0.5 + 3, tostring(num))

    if num <= 0 then
        -- "GO!" 用绿色
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.success, 255)))
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, "GO!")
    else
        -- 数字用金色
        fillTheme(Theme.primary, 255)
        nvgText(vg_, logW_ * 0.5, logH_ * 0.5, tostring(num))
    end

    -- 副标题
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 18)
    fillTheme(Theme.textSec, 200)
    nvgText(vg_, logW_ * 0.5, logH_ * 0.5 + 80, "向上攀登，争取最高分!")
end

-- ============================================================================
-- 结算画面
-- ============================================================================

--- 绘制结算画面（深紫色调 + 金色强调）
function HUD.DrawResultScreen()
    if gameManager_ == nil then return end

    -- 半透明深紫背景
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.bg, 180)))
    nvgFill(vg_)

    local cx = logW_ * 0.5
    local rankings = gameManager_.GetRankings()

    -- 提交云端分数（仅一次）
    if not cloudScoreSubmitted_ then
        cloudScoreSubmitted_ = true
        HUD.SubmitCloudScore(rankings)
    end

    -- 标题
    local titleFs = math.max(22, math.floor(42 * uiScale_))
    local titleY = math.floor(42 * uiScale_)
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, titleFs)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 获取玩家数据（提前取出，标题下面要用分数）
    local p1Entry = nil
    for _, entry in ipairs(rankings) do
        if entry.index == 1 then p1Entry = entry break end
    end
    local p1Score = p1Entry and p1Entry.score or 0

    local winner = gameManager_.GetWinner()
    if winner == 1 then
        local pulse = math.abs(math.sin(time.elapsedTime * 2)) * 30 + 225
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
        nvgText(vg_, cx + 2, titleY + 2, "你赢了!")
        nvgFillColor(vg_, nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], math.floor(pulse)))
        nvgText(vg_, cx, titleY, "你赢了!")
    else
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
        nvgText(vg_, cx + 2, titleY + 2, "游戏结束")
        fillTheme(Theme.primary, 255)
        nvgText(vg_, cx, titleY, "游戏结束")
    end

    -- 大号分数显示
    local scoreFs = math.max(36, math.floor(64 * uiScale_))
    local scoreY = titleY + titleFs * 0.5 + math.floor(12 * uiScale_)
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, scoreFs)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    -- 阴影
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 120))
    nvgText(vg_, cx + 2, scoreY + 2, tostring(p1Score))
    -- 金色分数
    nvgFillColor(vg_, nvgRGBA(Theme.accent[1], Theme.accent[2], Theme.accent[3], 255))
    nvgText(vg_, cx, scoreY, tostring(p1Score))
    -- "分" 标签
    local scoreLabelY = scoreY + scoreFs + math.floor(2 * uiScale_)
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, math.max(11, math.floor(15 * uiScale_)))
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    fillTheme(Theme.textSec, 160)
    nvgText(vg_, cx, scoreLabelY, "分")

    -- 金币奖励提示
    local coinReward = Economy.RewardFromScore(p1Score)
    if coinReward > 0 then
        local coinY = scoreLabelY + math.floor(18 * uiScale_)
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, math.max(10, math.floor(14 * uiScale_)))
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg_, nvgRGBA(Theme.accent[1], Theme.accent[2], Theme.accent[3], 180))
        nvgText(vg_, cx, coinY, "+" .. coinReward .. " 金币")
    end

    -- 本局战绩（带高亮数字 + 评语）
    if p1Entry then
        local floors = math.floor((p1Entry.heightScore or 0) / Config.HeightScoreUnit)
        local slams = p1Entry.slamHits or 0
        local gotSlmd = p1Entry.gotSlammed or 0
        local dths = p1Entry.deaths or 0
        local kls = p1Entry.kills or 0
        local gotKld = p1Entry.gotKilled or 0
        local falls = math.max(0, dths - gotKld)  -- 失足 = 总死亡 - 被杀

        -- 定义统计行：{ 前文, 数字, 后文, 前文2, 数字2, 后文2 }
        local statLines = {
            { "你爬升了 ", tostring(floors), " 层",    "失足 ", tostring(falls), " 次" },
            { "砸晕了 ",   tostring(slams),  " 人",    "被砸晕 ", tostring(gotSlmd), " 次" },
            { "红温了 ",   tostring(dths),   " 次",    nil, nil, nil },
            { "击杀了 ",   tostring(kls),    " 玩家",  "被爆杀 ", tostring(gotKld), " 次" },
        }

        local lineH = math.floor(24 * uiScale_)
        local startY = scoreLabelY + math.floor(42 * uiScale_)
        local fontSize = math.max(11, math.floor(16 * uiScale_))

        for i, sl in ipairs(statLines) do
            local y = startY + (i - 1) * lineH

            -- 绘制左半：前文 + 高亮数字 + 后文
            nvgFontFace(vg_, "sans")
            nvgFontSize(vg_, fontSize)
            nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)

            -- 计算宽度来居中整行
            local leftPart = sl[1] .. sl[2] .. sl[3]
            local rightPart = sl[4] and (sl[4] .. sl[5] .. sl[6]) or ""
            local sep = sl[4] and "，" or ""
            local fullText = leftPart .. sep .. rightPart

            nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
            local totalW = nvgTextBounds(vg_, 0, 0, fullText)
            local sx = cx - totalW * 0.5

            -- 逐段绘制（文字用浅色，数字用主题色高亮）
            local curX = sx

            -- 前文1
            fillTheme(Theme.textSec, 200)
            curX = nvgText(vg_, curX, y, sl[1])
            -- 高亮数字1
            nvgFontFace(vg_, "bold")
            nvgFillColor(vg_, nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], 255))
            curX = nvgText(vg_, curX, y, sl[2])
            -- 后文1
            nvgFontFace(vg_, "sans")
            fillTheme(Theme.textSec, 200)
            curX = nvgText(vg_, curX, y, sl[3])

            if sl[4] then
                -- 分隔逗号
                fillTheme(Theme.textSec, 120)
                curX = nvgText(vg_, curX, y, "，")
                -- 前文2
                fillTheme(Theme.textSec, 200)
                curX = nvgText(vg_, curX, y, sl[4])
                -- 高亮数字2
                nvgFontFace(vg_, "bold")
                nvgFillColor(vg_, nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], 255))
                curX = nvgText(vg_, curX, y, sl[5])
                -- 后文2
                nvgFontFace(vg_, "sans")
                fillTheme(Theme.textSec, 200)
                curX = nvgText(vg_, curX, y, sl[6])
            end
        end

        -- 调侃评语（按数据特征匹配，每个条件多个候选随机）
        local comment = nil
        local seed = floors + kls * 7 + dths * 13 + slams * 3  -- 伪随机种子

        if dths == 0 and kls >= 5 then
            local pool = {"无敌是多么寂寞", "零死传说，别人都在仰望你", "你是这局的天花板"}
            comment = pool[seed % #pool + 1]
        elseif kls >= 10 then
            local pool = {"杀疯了！你是有多少怨气？", "杀神降临，众生退避", "别杀了，他们已经是残血了"}
            comment = pool[seed % #pool + 1]
        elseif gotSlmd >= 10 then
            local pool = {"我是谁我在哪我要干什么...", "你脑袋上是不是有靶心？", "被砸十次还不跑？勇士！"}
            comment = pool[seed % #pool + 1]
        elseif gotKld >= 5 then
            local pool = {"你确定不是在给别人送分？", "活靶子本人", "经验宝宝：你"}
            comment = pool[seed % #pool + 1]
        elseif dths >= 12 then
            local pool = {"你是不是超级红温？", "建议先深呼吸三次", "键盘还好吗？", "屡败屡战，永不言弃！"}
            comment = pool[seed % #pool + 1]
        elseif falls >= 8 then
            local pool = {"地心引力的忠实信徒", "下面的风景更好看是吧？", "失足八次...你确定有在看屏幕？"}
            comment = pool[seed % #pool + 1]
        elseif slams >= 10 then
            local pool = {"下砸狂魔，无人幸免", "地面在颤抖", "你的屁股是铁做的？"}
            comment = pool[seed % #pool + 1]
        elseif floors >= 50 and dths <= 2 then
            local pool = {"稳如老狗，攀岩大师", "你是壁虎转世吗？", "高处不胜寒，但你无所谓"}
            comment = pool[seed % #pool + 1]
        elseif floors <= 5 and dths >= 5 then
            local pool = {"你是来旅游的吧？", "卡在第一层？需要帮忙吗", "建议先学会走再学跑"}
            comment = pool[seed % #pool + 1]
        elseif kls == 0 and dths == 0 then
            local pool = {"和平主义者，但你确定在玩？", "全程划水大师", "挂机也是一种策略"}
            comment = pool[seed % #pool + 1]
        elseif kls == 0 and dths >= 3 then
            local pool = {"人畜无害小绵羊", "菩萨心肠，送分童子", "不杀生是你的信仰"}
            comment = pool[seed % #pool + 1]
        elseif slams == 0 and gotSlmd >= 3 then
            local pool = {"总是被砸，从不还手", "善良得让人心疼", "你的头很铁，但心更软"}
            comment = pool[seed % #pool + 1]
        elseif kls >= 5 and gotKld == 0 then
            local pool = {"单方面的屠杀", "他们连碰都碰不到你", "猎人与猎物的差距"}
            comment = pool[seed % #pool + 1]
        elseif floors >= 30 then
            local pool = {"勇攀高峰！", "登高望远，豪情万丈", "离天空又近了一步"}
            comment = pool[seed % #pool + 1]
        elseif dths >= 5 and kls >= 3 then
            local pool = {"有来有回，势均力敌", "杀敌一千，自损八百", "这才是真正的乱斗！"}
            comment = pool[seed % #pool + 1]
        else
            local pool = {"再来一局，争取更好！", "热身结束，来真的！", "不错的表现，继续加油"}
            comment = pool[seed % #pool + 1]
        end

        local commentY = startY + #statLines * lineH + math.floor(10 * uiScale_)
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, math.max(10, math.floor(14 * uiScale_)))
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(Theme.accent[1], Theme.accent[2], Theme.accent[3], 200))
        nvgText(vg_, cx, commentY, "「" .. comment .. "」")
    end

    -- 排行榜（仅云端）
    local tableW = math.min(logW_ * 0.85, math.floor(500 * uiScale_))
    local tableX = cx - tableW * 0.5
    -- 排行榜起始 Y 基于分数区域高度动态计算
    local cloudY = scoreLabelY + math.floor(170 * uiScale_)
    HUD.DrawCloudLeaderboard(cx, cloudY, tableW, tableX)

    -- 底部按钮
    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    local btnW = math.max(100, math.floor(140 * uiScale_))
    local btnH = math.max(isMobileHUD_ and 36 or 40, math.floor(46 * uiScale_))
    local btnGap = math.floor(20 * uiScale_)
    -- 确保按钮底边距屏幕底部至少 20px（手机端 uiScale_ 小时不会超出屏幕）
    local btnBottomMargin = math.max(20, math.floor(30 * uiScale_))
    local btnY = logH_ - btnBottomMargin - btnH

    -- "再来一局" 按钮（金色）
    local restartX = cx - btnW - btnGap * 0.5
    local restartHover = mx >= restartX and mx <= restartX + btnW and my >= btnY and my <= btnY + btnH
    local restartClicked = HUD.DrawRubberButton(restartX, btnY, btnW, btnH, "再来一局",
        Theme.primary[1], Theme.primary[2], Theme.primary[3], restartHover)
    if restartClicked then
        resultButtonClicked_ = "restart"
        cloudScoreSubmitted_ = false
        cloudLeaderboard_ = nil
        cloudLeaderboardLoading_ = false
        dailyLeaderboard_ = nil
        dailyLeaderboardLoading_ = false
        menuLeaderboardLoaded_ = false
        -- 重置状态跟踪和浮字
        prevPlayerStates_ = {}
        statusFloats_ = {}
        assignNicknames()  -- 重新分配 AI 昵称
    end

    -- "返回菜单" 按钮（蓝色）
    local menuX = cx + btnGap * 0.5
    local menuHover = mx >= menuX and mx <= menuX + btnW and my >= btnY and my <= btnY + btnH
    local menuClicked = HUD.DrawRubberButton(menuX, btnY, btnW, btnH, "返回菜单",
        Theme.secondary[1], Theme.secondary[2], Theme.secondary[3], menuHover)
    if menuClicked then
        resultButtonClicked_ = "menu"
        cloudScoreSubmitted_ = false
        cloudLeaderboard_ = nil
        cloudLeaderboardLoading_ = false
        dailyLeaderboard_ = nil
        dailyLeaderboardLoading_ = false
        menuLeaderboardLoaded_ = false
        -- 重置状态跟踪和浮字
        prevPlayerStates_ = {}
        statusFloats_ = {}
        assignNicknames()
    end
end

-- ============================================================================
-- 云端排行榜
-- ============================================================================

--- 获取今日日期 key（用于今日排行榜）
local function getTodayKey()
    return "daily_" .. os.date("%Y%m%d")
end

--- 提交玩家分数到云端（历史最高 + 今日最高）
function HUD.SubmitCloudScore(rankings)
    local p1Entry = nil
    for _, entry in ipairs(rankings) do
        if entry.index == 1 then p1Entry = entry break end
    end
    if not p1Entry then return end

    local score = p1Entry.score
    if score <= 0 then return end

    if not clientCloud then
        print("[HUD] clientCloud not available, skipping cloud submit")
        return
    end

    local kills = p1Entry.killScore or 0
    local height = p1Entry.maxHeight or 0
    local dailyKey = getTodayKey()

    clientCloud:Get("high_score", {
        ok = function(values, iscores)
            local oldScore = iscores.high_score or 0
            local oldDaily = iscores[dailyKey] or 0
            local batch = clientCloud:BatchSet()
            -- 历史最高
            if score > oldScore then
                batch:SetInt("high_score", score)
                batch:SetInt("max_height", height)
                batch:SetInt("max_kills", kills)
            end
            -- 今日最高
            if score > oldDaily then
                batch:SetInt(dailyKey, score)
            end
            batch:Add("play_count", 1)
            batch:Save("game result", {
                ok = function()
                    print("[HUD] Cloud score submitted: " .. score .. " kills: " .. kills)
                    HUD.LoadCloudLeaderboard()
                    HUD.LoadDailyLeaderboard()
                end,
                error = function(code, reason)
                    print("[HUD] Cloud submit error: " .. tostring(reason))
                    HUD.LoadCloudLeaderboard()
                    HUD.LoadDailyLeaderboard()
                end
            })
        end,
        error = function(code, reason)
            print("[HUD] Cloud get error: " .. tostring(reason))
            clientCloud:BatchSet()
                :SetInt("high_score", score)
                :SetInt("max_height", height)
                :SetInt("max_kills", kills)
                :SetInt(dailyKey, score)
                :Add("play_count", 1)
                :Save("game result", {
                    ok = function()
                        HUD.LoadCloudLeaderboard()
                        HUD.LoadDailyLeaderboard()
                    end,
                    error = function()
                        HUD.LoadCloudLeaderboard()
                        HUD.LoadDailyLeaderboard()
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

--- 加载今日排行榜
function HUD.LoadDailyLeaderboard()
    if not clientCloud then return end
    if dailyLeaderboardLoading_ then return end

    dailyLeaderboardLoading_ = true
    dailyLeaderboard_ = nil

    local dailyKey = getTodayKey()
    clientCloud:GetRankList(dailyKey, 0, 10, {
        ok = function(rankList)
            local leaderboard = {}
            local userIds = {}
            for i, item in ipairs(rankList) do
                local dailyScore = item.iscore[dailyKey] or 0
                if dailyScore > 0 then
                    table.insert(leaderboard, {
                        rank = #leaderboard + 1,
                        userId = item.userId,
                        score = dailyScore,
                        maxHeight = item.iscore.max_height or 0,
                        playCount = item.iscore.play_count or 0,
                        isMe = item.userId == clientCloud.userId,
                    })
                    table.insert(userIds, item.userId)
                end
            end

            if #userIds == 0 then
                dailyLeaderboard_ = leaderboard
                dailyLeaderboardLoading_ = false
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
                    dailyLeaderboard_ = leaderboard
                    dailyLeaderboardLoading_ = false
                    print("[HUD] Daily leaderboard loaded: " .. #leaderboard .. " entries")
                end,
                onError = function(errorCode)
                    for _, entry in ipairs(leaderboard) do
                        entry.nickname = "玩家"
                    end
                    dailyLeaderboard_ = leaderboard
                    dailyLeaderboardLoading_ = false
                end
            })
        end,
        error = function(code, reason)
            print("[HUD] Daily leaderboard load error: " .. tostring(reason))
            dailyLeaderboardLoading_ = false
        end
    }, "max_height", "play_count")
end

--- 绘制云端排行榜（在结算画面中）
function HUD.DrawCloudLeaderboard(cx, startY, tableW, tableX)
    local s = uiScale_
    -- 标题（金色）
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.max(10, math.floor(16 * s)))
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    fillTheme(Theme.primary, 230)
    nvgText(vg_, cx, startY, "排行榜")

    local contentY = startY + math.floor(24 * s)

    if cloudLeaderboardLoading_ then
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, math.max(10, math.floor(14 * s)))
        fillTheme(Theme.textSec, 180)
        nvgText(vg_, cx, contentY, "加载中...")
        return
    end

    if not cloudLeaderboard_ or #cloudLeaderboard_ == 0 then
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, math.max(10, math.floor(14 * s)))
        fillTheme(Theme.textSec, 180)
        if not clientCloud then
            nvgText(vg_, cx, contentY, "排行榜暂不可用")
        else
            nvgText(vg_, cx, contentY, "暂无数据")
        end
        return
    end

    -- 表头
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.max(8, math.floor(11 * s)))
    fillTheme(Theme.accent, 180)

    local cloudCols = {
        { x = tableX + math.floor(10 * s),  label = "#",    align = NVG_ALIGN_LEFT },
        { x = tableX + math.floor(30 * s),  label = "昵称",  align = NVG_ALIGN_LEFT },
        { x = tableX + tableW * 0.55, label = "最高分", align = NVG_ALIGN_CENTER },
        { x = tableX + tableW * 0.75, label = "最高高度", align = NVG_ALIGN_CENTER },
        { x = tableX + tableW * 0.92, label = "场次", align = NVG_ALIGN_CENTER },
    }
    for _, col in ipairs(cloudCols) do
        nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
        nvgText(vg_, col.x, contentY, col.label)
    end

    local rowH = math.floor(20 * s)
    local maxCloudEntries = isMobileHUD_ and 5 or 10
    for i, entry in ipairs(cloudLeaderboard_) do
        if i > maxCloudEntries then break end
        local y = contentY + math.floor(16 * s) + (i - 1) * rowH

        -- "我" 的行高亮
        if entry.isMe then
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, tableX, y - 2, tableW, rowH, 3)
            nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.primary, 20)))
            nvgFill(vg_)
        end

        nvgFontFace(vg_, entry.isMe and "bold" or "sans")
        nvgFontSize(vg_, math.max(9, math.floor(13 * s)))

        local nameDisplay = entry.nickname or "玩家"
        if entry.isMe then nameDisplay = nameDisplay .. " (我)" end
        local maxCloudNameLen = isMobileHUD_ and 12 or 20
        if #nameDisplay > maxCloudNameLen then nameDisplay = nameDisplay:sub(1, maxCloudNameLen - 2) .. ".." end

        local values = {
            tostring(entry.rank),
            nameDisplay,
            tostring(entry.score),
            tostring(entry.maxHeight),
            tostring(entry.playCount),
        }

        local textColor
        if entry.isMe then
            textColor = nvgRGBA(Theme.rgba(Theme.primary, 255))
        elseif entry.rank == 1 then
            textColor = nvgRGBA(Theme.rgba(Theme.primary, 240))
        elseif entry.rank <= 3 then
            textColor = nvgRGBA(Theme.rgba(Theme.text, 220))
        else
            textColor = nvgRGBA(Theme.rgba(Theme.textSec, 180))
        end

        for ci, col in ipairs(cloudCols) do
            nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
            nvgFillColor(vg_, textColor)
            nvgText(vg_, col.x, y, values[ci])
        end
    end
end

-- ============================================================================
-- 橡胶按钮（Astroon 风格：深色底 + 微光边框 + 高光）
-- ============================================================================

function HUD.DrawRubberButton(x, y, w, h, label, baseR, baseG, baseB, hovered)
    local cornerR = Theme.radiusMd

    -- 阴影
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x + 1, y + 3, w, h, cornerR)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, hovered and 120 or 80))
    nvgFill(vg_)

    -- 基色
    local br = hovered and math.min(255, baseR + 25) or baseR
    local bg = hovered and math.min(255, baseG + 25) or baseG
    local bb = hovered and math.min(255, baseB + 25) or baseB
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
    local glossPaint = nvgLinearGradient(vg_, x, y, x, y + h * 0.4,
        nvgRGBA(255, 255, 255, hovered and 100 or 70), nvgRGBA(255, 255, 255, 0))
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgFillPaint(vg_, glossPaint)
    nvgFill(vg_)

    -- 边框微光
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, h, cornerR)
    nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, hovered and 60 or 30))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)

    -- 文字阴影
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, math.floor(h * 0.38))
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
-- 主菜单（Astroon 深紫主题）
-- ============================================================================

function HUD.DrawMenu()
    -- 深紫渐变背景
    local bgPaint = nvgLinearGradient(vg_, 0, 0, 0, logH_,
        nvgRGBA(Theme.bg[1], Theme.bg[2], Theme.bg[3], 210),
        nvgRGBA(Theme.bgMid[1], Theme.bgMid[2], Theme.bgMid[3], 160))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, 0, logW_, logH_)
    nvgFillPaint(vg_, bgPaint)
    nvgFill(vg_)

    -- 装饰粒子（金色 + 青色微光）
    local t = time.elapsedTime
    for i = 1, 35 do
        local speed = 0.12 + (i % 5) * 0.04
        local px = (math.sin(t * 0.18 + i * 1.7) * 0.5 + 0.5) * logW_
        local py = math.fmod((1.0 - (t * speed * 0.08 + i * 0.13)) % 1.0, 1.0) * logH_
        local alpha = math.abs(math.sin(t * 0.35 + i * 0.8)) * 40 + 10
        local radius = 1.2 + math.sin(t * 0.6 + i) * 0.8

        nvgBeginPath(vg_)
        nvgCircle(vg_, px, py, radius)
        if i % 3 == 0 then
            nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.accent, math.floor(alpha))))
        else
            nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.primary, math.floor(alpha * 0.8))))
        end
        nvgFill(vg_)
    end

    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    -- 首次进入菜单时自动加载排行榜
    if not menuLeaderboardLoaded_ then
        menuLeaderboardLoaded_ = true
        HUD.LoadCloudLeaderboard()
        HUD.LoadDailyLeaderboard()
    end

    if isMobileHUD_ then
        HUD.DrawMenu_Mobile(t, mx, my)
    else
        HUD.DrawMenu_Desktop(t, mx, my)
    end

    -- 底部操作说明（带渐变背景条）
    local tipH = math.floor(28 * uiScale_)
    local tipY = logH_ - tipH
    local tipBg = nvgLinearGradient(vg_, 0, tipY, 0, logH_,
        nvgRGBA(0, 0, 0, 0), nvgRGBA(Theme.bg[1], Theme.bg[2], Theme.bg[3], 120))
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, tipY, logW_, tipH)
    nvgFillPaint(vg_, tipBg)
    nvgFill(vg_)

    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, math.max(9, math.floor(12 * uiScale_)))
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    fillTheme(Theme.textMuted, 140)
    local tipText = isMobileHUD_
        and "摇杆:移动  跳:跳跃  冲:冲刺  砸:下砸  爆:蓄力爆炸"
        or  "A/D:移动  空格:跳跃  Shift:冲刺  S:下砸  鼠标左键:蓄力爆炸"
    nvgText(vg_, logW_ * 0.5, tipY + tipH * 0.5, tipText)
end

-- ============================================================================
-- 手机端主菜单：竖向布局 — 标题(缩小)+按钮 在上方，排行榜在下方可滚动
-- ============================================================================
function HUD.DrawMenu_Mobile(t, mx, my)
    local cx = logW_ * 0.5
    local margin = 12
    local s = uiScale_

    -- ==================== 顶部：标题 + 副标题 + 按钮 ====================
    local titleCy = logH_ * 0.24  -- 标题中心

    local titleBottom = titleCy + 20
    if titleImage_ > 0 and titleImageW_ > 0 then
        -- 标题图片：最大宽度为屏幕 60%，高度限制 30%
        local maxW = logW_ * 0.60
        local maxH = logH_ * 0.30
        local imgScale = math.min(maxW / titleImageW_, maxH / titleImageH_)
        local drawW = titleImageW_ * imgScale
        local drawH = titleImageH_ * imgScale
        local imgX = cx - drawW * 0.5
        local imgY = titleCy - drawH * 0.5
        local floatY = math.sin(t * 1.2) * 2
        imgY = imgY + floatY

        -- 光晕
        local glowCx = imgX + drawW * 0.5
        local glowCy = imgY + drawH * 0.5
        local glowR = math.max(drawW, drawH) * 0.5
        local glowPulse = math.abs(math.sin(t * 1.0)) * 10 + 12
        local glowPaint = nvgRadialGradient(vg_, glowCx, glowCy, glowR * 0.2, glowR,
            nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], math.floor(glowPulse)),
            nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], 0))
        nvgBeginPath(vg_)
        nvgRect(vg_, glowCx - glowR, glowCy - glowR, glowR * 2, glowR * 2)
        nvgFillPaint(vg_, glowPaint)
        nvgFill(vg_)

        local imgPaint = nvgImagePattern(vg_, imgX, imgY, drawW, drawH, 0, titleImage_, 1.0)
        nvgBeginPath(vg_)
        nvgRect(vg_, imgX, imgY, drawW, drawH)
        nvgFillPaint(vg_, imgPaint)
        nvgFill(vg_)
        titleBottom = imgY + drawH
    else
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 34)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
        nvgText(vg_, cx + 1, titleCy + 1, Config.Title)
        fillTheme(Theme.primary, 255)
        nvgText(vg_, cx, titleCy, Config.Title)
        titleBottom = titleCy + 20
    end

    -- 副标题
    local subtitleY = titleBottom + 10
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 11)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    fillTheme(Theme.textSec, 200)
    nvgText(vg_, cx, subtitleY, "大地图攀登挑战 2分钟限时赛")

    -- 当前职业显示
    local classId = Economy.GetSelectedClassId()
    local classDef = CharacterClass.GetById(classId)
    local classLabelY = subtitleY + 16
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 10)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    fillTheme(Theme.textSec, 160)
    local classLabel = "职业: " .. (classDef and (classDef.icon .. " " .. classDef.name) or "街头小子")
    nvgText(vg_, cx, classLabelY, classLabel)

    -- 按钮区域（开始 + 商店 横排）
    local btnW = 100
    local btnH = 34
    local btnGap = 10
    local btnY = classLabelY + 14
    local totalBtnW = btnW * 2 + btnGap
    local btnStartX = cx - totalBtnW * 0.5

    -- 开始游戏按钮
    local startHovered = mx >= btnStartX and mx <= btnStartX + btnW and my >= btnY and my <= btnY + btnH
    local startClicked = HUD.DrawRubberButton(btnStartX, btnY, btnW, btnH, "开始游戏",
        Theme.primary[1], Theme.primary[2], Theme.primary[3], startHovered)
    if startClicked then
        menuButtonClicked_ = "startGame"
    end

    -- 商店按钮
    local shopX = btnStartX + btnW + btnGap
    local shopHovered = mx >= shopX and mx <= shopX + btnW and my >= btnY and my <= btnY + btnH
    local shopClicked = HUD.DrawRubberButton(shopX, btnY, btnW, btnH, "商店",
        Theme.accent[1], Theme.accent[2], Theme.accent[3], shopHovered)
    if shopClicked then
        menuButtonClicked_ = "shop"
    end

    -- ==================== 下方：排行榜（可滚动，居中，较窄）====================
    local lbTopY = btnY + btnH + 14   -- 排行榜区域起始
    local lbBottomY = logH_ - 30      -- 底部提示条上方
    local fullAreaH = lbBottomY - lbTopY
    if fullAreaH < 40 then return end -- 屏幕太小就跳过

    -- 宽度：屏幕宽度的 45%（约为之前全宽的一半）
    local lbW = math.floor(logW_ * 0.45)
    local lbX = math.floor((logW_ - lbW) * 0.5)  -- 居中
    local lbCx = logW_ * 0.5
    -- 高度：可用空间的 2/3
    local lbAreaH = math.floor(fullAreaH * 0.67)
    local lbBottomClamped = lbTopY + lbAreaH

    -- Tab 按钮
    local tabW = 56
    local tabH = 20
    local tabGap = 6
    local tabTotalW = tabW * 2 + tabGap
    local tabX = lbCx - tabTotalW * 0.5
    local tabY = lbTopY

    -- "历史排行" tab
    local histHover = mx >= tabX and mx <= tabX + tabW and my >= tabY and my <= tabY + tabH
    local histActive = menuLeaderboardTab_ == "history"
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, tabX, tabY, tabW, tabH, Theme.radiusSm)
    if histActive then
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.primary, 200)))
    else
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.bgMid, histHover and 180 or 120)))
    end
    nvgFill(vg_)
    nvgFontFace(vg_, histActive and "bold" or "sans")
    nvgFontSize(vg_, 10)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, histActive and 255 or 180))
    nvgText(vg_, tabX + tabW * 0.5, tabY + tabH * 0.5, "历史排行")

    if cachedMousePress_ and histHover and not histActive then
        menuLeaderboardTab_ = "history"
        menuScrollY_ = 0
    end

    -- "今日排行" tab
    local dailyTabX = tabX + tabW + tabGap
    local dailyHover = mx >= dailyTabX and mx <= dailyTabX + tabW and my >= tabY and my <= tabY + tabH
    local dailyActive = menuLeaderboardTab_ == "daily"
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, dailyTabX, tabY, tabW, tabH, Theme.radiusSm)
    if dailyActive then
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.primary, 200)))
    else
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.bgMid, dailyHover and 180 or 120)))
    end
    nvgFill(vg_)
    nvgFontFace(vg_, dailyActive and "bold" or "sans")
    nvgFontSize(vg_, 10)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, dailyActive and 255 or 180))
    nvgText(vg_, dailyTabX + tabW * 0.5, tabY + tabH * 0.5, "今日排行")

    if cachedMousePress_ and dailyHover and not dailyActive then
        menuLeaderboardTab_ = "daily"
        menuScrollY_ = 0
    end

    -- 排行榜内容区
    local contentY = tabY + tabH + 4
    local panelH = lbBottomClamped - contentY
    local currentData = menuLeaderboardTab_ == "history" and cloudLeaderboard_ or dailyLeaderboard_
    local isLoading = menuLeaderboardTab_ == "history" and cloudLeaderboardLoading_ or dailyLeaderboardLoading_

    -- 面板背景
    drawPanel(lbX - 2, contentY - 2, lbW + 4, panelH + 4, Theme.radiusMd, 140)

    if isLoading then
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 11)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        fillTheme(Theme.textSec, 180)
        nvgText(vg_, lbCx, contentY + panelH * 0.5, "加载中...")
        return
    end

    if not currentData or #currentData == 0 then
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 11)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        fillTheme(Theme.textSec, 180)
        nvgText(vg_, lbCx, contentY + panelH * 0.5, clientCloud and "暂无数据" or "排行榜暂不可用")
        return
    end

    -- 表头（固定不动）
    local headerH = 14
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 9)
    fillTheme(Theme.accent, 180)
    local lbCols = {
        { x = lbX + 6,            label = "#",    align = NVG_ALIGN_LEFT },
        { x = lbX + 20,           label = "昵称",  align = NVG_ALIGN_LEFT },
        { x = lbX + lbW * 0.55,   label = "分数",  align = NVG_ALIGN_CENTER },
        { x = lbX + lbW * 0.78,   label = "高度",  align = NVG_ALIGN_CENTER },
        { x = lbX + lbW * 0.95,   label = "场",   align = NVG_ALIGN_CENTER },
    }
    for _, col in ipairs(lbCols) do
        nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
        nvgText(vg_, col.x, contentY + 2, col.label)
    end

    -- 可滚动行区域
    local rowsY = contentY + headerH
    local rowsH = panelH - headerH
    local rowH = 16
    local totalRowsH = #currentData * rowH
    local maxScroll = math.max(0, totalRowsH - rowsH)

    -- 触摸滚动处理
    local numTouches = input.numTouches or 0
    if numTouches > 0 then
        local ts = input:GetTouch(0)
        local ty = ts.position.y / dpr_
        local tx = ts.position.x / dpr_
        -- 检查触摸是否在排行榜区域内
        if tx >= lbX and tx <= lbX + lbW and ty >= rowsY and ty <= rowsY + rowsH then
            if menuScrollTouchId_ == nil then
                -- 开始触摸
                menuScrollTouchId_ = 0
                menuScrollLastY_ = ty
                menuScrollVel_ = 0
            else
                -- 拖动中
                local deltaY = menuScrollLastY_ - ty
                menuScrollY_ = menuScrollY_ + deltaY
                menuScrollVel_ = deltaY
                menuScrollLastY_ = ty
            end
        end
    else
        if menuScrollTouchId_ ~= nil then
            menuScrollTouchId_ = nil
        end
        -- 惯性衰减
        if math.abs(menuScrollVel_) > 0.5 then
            menuScrollY_ = menuScrollY_ + menuScrollVel_
            menuScrollVel_ = menuScrollVel_ * 0.9
        else
            menuScrollVel_ = 0
        end
    end

    -- 鼠标滚轮支持（桌面端调试用）
    local wheel = input:GetMouseMoveWheel()
    if wheel ~= 0 then
        menuScrollY_ = menuScrollY_ - wheel * 20
    end

    -- 限制滚动范围
    menuScrollY_ = math.max(0, math.min(menuScrollY_, maxScroll))

    -- 裁剪绘制区域
    nvgSave(vg_)
    nvgScissor(vg_, lbX, rowsY, lbW, rowsH)

    for i, entry in ipairs(currentData) do
        local y = rowsY + (i - 1) * rowH - menuScrollY_

        -- 跳过不可见行
        if y + rowH >= rowsY and y <= rowsY + rowsH then
            if entry.isMe then
                nvgBeginPath(vg_)
                nvgRoundedRect(vg_, lbX, y, lbW, rowH, 3)
                nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.primary, 25)))
                nvgFill(vg_)
            end

            nvgFontFace(vg_, entry.isMe and "bold" or "sans")
            nvgFontSize(vg_, 10)

            local nameDisplay = entry.nickname or "玩家"
            if entry.isMe then nameDisplay = nameDisplay .. "(我)" end
            if #nameDisplay > 10 then nameDisplay = nameDisplay:sub(1, 9) .. "." end

            local values = {
                tostring(entry.rank),
                nameDisplay,
                tostring(entry.score),
                tostring(entry.maxHeight),
                tostring(entry.playCount),
            }

            local textColor
            if entry.isMe then
                textColor = nvgRGBA(Theme.rgba(Theme.primary, 255))
            elseif entry.rank == 1 then
                textColor = nvgRGBA(Theme.rgba(Theme.primary, 240))
            elseif entry.rank <= 3 then
                textColor = nvgRGBA(Theme.rgba(Theme.text, 220))
            else
                textColor = nvgRGBA(Theme.rgba(Theme.textSec, 180))
            end

            for ci, col in ipairs(lbCols) do
                nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
                nvgFillColor(vg_, textColor)
                nvgText(vg_, col.x, y + 2, values[ci])
            end
        end
    end

    nvgRestore(vg_)

    -- 滚动指示条（如果内容超出可见区域）
    if maxScroll > 0 then
        local scrollbarH = math.max(10, rowsH * (rowsH / totalRowsH))
        local scrollbarY = rowsY + (menuScrollY_ / maxScroll) * (rowsH - scrollbarH)
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, lbX + lbW - 3, scrollbarY, 3, scrollbarH, 1.5)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 40))
        nvgFill(vg_)
    end
end

-- ============================================================================
-- 桌面端主菜单：居中布局（原始设计）
-- ============================================================================
function HUD.DrawMenu_Desktop(t, mx, my)
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

        -- 柔和光晕
        local glowCx = imgX + drawW * 0.5
        local glowCy = imgY + drawH * 0.5
        local glowR = math.max(drawW, drawH) * 0.7
        local glowPulse = math.abs(math.sin(t * 1.0)) * 10 + 15
        local glowPaint = nvgRadialGradient(vg_, glowCx, glowCy, glowR * 0.2, glowR,
            nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], math.floor(glowPulse)),
            nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], 0))
        nvgBeginPath(vg_)
        nvgRect(vg_, glowCx - glowR, glowCy - glowR, glowR * 2, glowR * 2)
        nvgFillPaint(vg_, glowPaint)
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
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150))
        nvgText(vg_, cx + 3, cy + 3, Config.Title)
        fillTheme(Theme.primary, 255)
        nvgText(vg_, cx, cy, Config.Title)
    end

    -- 装饰分隔线
    local lineY = titleBottom + 12
    local lineW = math.min(logW_ * 0.3, 200)
    local linePaint = nvgLinearGradient(vg_, cx - lineW * 0.5, lineY, cx, lineY,
        nvgRGBA(Theme.rgba(Theme.primary, 0)), nvgRGBA(Theme.rgba(Theme.primary, 100)))
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, cx - lineW * 0.5, lineY)
    nvgLineTo(vg_, cx, lineY)
    nvgStrokePaint(vg_, linePaint)
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)
    local linePaint2 = nvgLinearGradient(vg_, cx, lineY, cx + lineW * 0.5, lineY,
        nvgRGBA(Theme.rgba(Theme.primary, 100)), nvgRGBA(Theme.rgba(Theme.primary, 0)))
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, cx, lineY)
    nvgLineTo(vg_, cx + lineW * 0.5, lineY)
    nvgStrokePaint(vg_, linePaint2)
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)

    -- 副标题
    local subtitleY = lineY + 18
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 16)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    fillTheme(Theme.textSec, 200)
    nvgText(vg_, cx, subtitleY, "大地图攀登挑战  2分钟限时赛")

    -- 当前职业显示
    local classId = Economy.GetSelectedClassId()
    local classDef = CharacterClass.GetById(classId)
    local classLabelY = subtitleY + 22
    nvgFontFace(vg_, "sans")
    nvgFontSize(vg_, 13)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    fillTheme(Theme.textSec, 160)
    local classLabel = "当前职业: " .. (classDef and (classDef.icon .. " " .. classDef.name) or "街头小子")
    nvgText(vg_, cx, classLabelY, classLabel)

    -- 按钮区域（开始 + 商店 横排）
    local btnW = 140
    local btnH = 50
    local btnGap = 16
    local btnY = classLabelY + 18
    local totalBtnW = btnW * 2 + btnGap
    local btnStartX = cx - totalBtnW * 0.5

    -- 开始游戏按钮
    local startHovered = mx >= btnStartX and mx <= btnStartX + btnW and my >= btnY and my <= btnY + btnH
    local startClicked = HUD.DrawRubberButton(btnStartX, btnY, btnW, btnH, "开始游戏",
        Theme.primary[1], Theme.primary[2], Theme.primary[3], startHovered)
    if startClicked then
        menuButtonClicked_ = "startGame"
    end

    -- 商店按钮
    local shopX = btnStartX + btnW + btnGap
    local shopHovered = mx >= shopX and mx <= shopX + btnW and my >= btnY and my <= btnY + btnH
    local shopClicked = HUD.DrawRubberButton(shopX, btnY, btnW, btnH, "商店",
        Theme.accent[1], Theme.accent[2], Theme.accent[3], shopHovered)
    if shopClicked then
        menuButtonClicked_ = "shop"
    end

    -- 排行榜区域
    local lbTop = btnY + btnH + 16
    local lbW = math.min(logW_ * 0.85, 460)
    local lbX = cx - lbW * 0.5

    -- Tab 按钮
    local tabW = 80
    local tabH = 26
    local tabGap = 8
    local tabTotalW = tabW * 2 + tabGap
    local tabX = cx - tabTotalW * 0.5
    local tabY = lbTop

    -- "历史排行" tab
    local histHover = mx >= tabX and mx <= tabX + tabW and my >= tabY and my <= tabY + tabH
    local histActive = menuLeaderboardTab_ == "history"
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, tabX, tabY, tabW, tabH, Theme.radiusSm)
    if histActive then
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.primary, 200)))
    else
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.bgMid, histHover and 180 or 120)))
    end
    nvgFill(vg_)
    nvgFontFace(vg_, histActive and "bold" or "sans")
    nvgFontSize(vg_, 13)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, histActive and 255 or 180))
    nvgText(vg_, tabX + tabW * 0.5, tabY + tabH * 0.5, "历史排行")

    if cachedMousePress_ and histHover and not histActive then
        menuLeaderboardTab_ = "history"
    end

    -- "今日排行" tab
    local dailyTabX = tabX + tabW + tabGap
    local dailyHover = mx >= dailyTabX and mx <= dailyTabX + tabW and my >= tabY and my <= tabY + tabH
    local dailyActive = menuLeaderboardTab_ == "daily"
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, dailyTabX, tabY, tabW, tabH, Theme.radiusSm)
    if dailyActive then
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.primary, 200)))
    else
        nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.bgMid, dailyHover and 180 or 120)))
    end
    nvgFill(vg_)
    nvgFontFace(vg_, dailyActive and "bold" or "sans")
    nvgFontSize(vg_, 13)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, dailyActive and 255 or 180))
    nvgText(vg_, dailyTabX + tabW * 0.5, tabY + tabH * 0.5, "今日排行")

    if cachedMousePress_ and dailyHover and not dailyActive then
        menuLeaderboardTab_ = "daily"
    end

    -- 排行榜内容区
    local contentY = tabY + tabH + 8
    local currentData = menuLeaderboardTab_ == "history" and cloudLeaderboard_ or dailyLeaderboard_
    local isLoading = menuLeaderboardTab_ == "history" and cloudLeaderboardLoading_ or dailyLeaderboardLoading_

    local panelH = 200
    drawPanel(lbX - 6, contentY - 4, lbW + 12, panelH + 8, Theme.radiusMd, 160)

    if isLoading then
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 14)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        fillTheme(Theme.textSec, 180)
        nvgText(vg_, cx, contentY + panelH * 0.5, "加载中...")
    elseif not currentData or #currentData == 0 then
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 14)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        fillTheme(Theme.textSec, 180)
        nvgText(vg_, cx, contentY + panelH * 0.5, clientCloud and "暂无数据" or "排行榜暂不可用")
    else
        nvgFontFace(vg_, "bold")
        nvgFontSize(vg_, 11)
        fillTheme(Theme.accent, 180)
        local lbCols = {
            { x = lbX + 10,          label = "#",    align = NVG_ALIGN_LEFT },
            { x = lbX + 30,          label = "昵称",  align = NVG_ALIGN_LEFT },
            { x = lbX + lbW * 0.55,  label = "最高分", align = NVG_ALIGN_CENTER },
            { x = lbX + lbW * 0.75,  label = "最高高度", align = NVG_ALIGN_CENTER },
            { x = lbX + lbW * 0.92,  label = "场次", align = NVG_ALIGN_CENTER },
        }
        for _, col in ipairs(lbCols) do
            nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
            nvgText(vg_, col.x, contentY, col.label)
        end

        local rowH = 18
        for i, entry in ipairs(currentData) do
            if i > 10 then break end
            local y = contentY + 16 + (i - 1) * rowH

            if entry.isMe then
                nvgBeginPath(vg_)
                nvgRoundedRect(vg_, lbX, y - 2, lbW, rowH, 3)
                nvgFillColor(vg_, nvgRGBA(Theme.rgba(Theme.primary, 20)))
                nvgFill(vg_)
            end

            nvgFontFace(vg_, entry.isMe and "bold" or "sans")
            nvgFontSize(vg_, 12)

            local nameDisplay = entry.nickname or "玩家"
            if entry.isMe then nameDisplay = nameDisplay .. " (我)" end
            if #nameDisplay > 16 then nameDisplay = nameDisplay:sub(1, 14) .. ".." end

            local values = {
                tostring(entry.rank),
                nameDisplay,
                tostring(entry.score),
                tostring(entry.maxHeight),
                tostring(entry.playCount),
            }

            local textColor
            if entry.isMe then
                textColor = nvgRGBA(Theme.rgba(Theme.primary, 255))
            elseif entry.rank == 1 then
                textColor = nvgRGBA(Theme.rgba(Theme.primary, 240))
            elseif entry.rank <= 3 then
                textColor = nvgRGBA(Theme.rgba(Theme.text, 220))
            else
                textColor = nvgRGBA(Theme.rgba(Theme.textSec, 180))
            end

            for ci, col in ipairs(lbCols) do
                nvgTextAlign(vg_, col.align + NVG_ALIGN_TOP)
                nvgFillColor(vg_, textColor)
                nvgText(vg_, col.x, y, values[ci])
            end
        end
    end
end

return HUD

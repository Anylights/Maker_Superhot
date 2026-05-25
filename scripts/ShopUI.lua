-- ============================================================================
-- ShopUI.lua - 商店界面（NanoVG 绘制，Astroon 主题）
-- 由 HUD.DrawShop() 调用，展示职业/皮肤列表、购买/选中、金币余额
-- 合并瀑布流布局 + 触摸/鼠标滚轮滚动
-- ============================================================================

local CharacterClass = require("CharacterClass")
local Economy = require("Economy")
local FaceSkin = require("FaceSkin")
local Theme = require("Theme")

local ShopUI = {}

-- 内部状态（桌面端单列滚动）
local scrollY_ = 0
local scrollVel_ = 0
local maxScrollY_ = 0

-- 移动端双面板独立滚动
local scrollYClass_ = 0      -- 职业面板
local velClass_     = 0
local maxScrollClass_ = 0
local scrollYSkin_  = 0      -- 表情面板
local velSkin_      = 0
local maxScrollSkin_ = 0

local buyResult_ = nil        -- 购买结果提示 { text, color, timer }
local buttonClicked_ = nil    -- "back" | nil
local pendingAdUnlock_ = nil  -- { type="class"|"skin", item=... } 推迟到 Update 阶段调用 SDK

-- 触摸拖拽状态
local touchActive_       = false
local touchDragging_     = false
local touchStartY_       = 0
local touchLastY_        = 0
local touchStartScrollY_ = 0
local touchSide_         = 0   -- 0=桌面, 1=左面板(职业), 2=右面板(表情)
local DRAG_THRESHOLD     = 5

-- 可通过广告解锁的职业/皮肤（其余只能金币购买）
local AD_UNLOCK_CLASSES = { [2]=true, [3]=true, [4]=true }  -- 弹跳忍者/能量达人/疾风突击
local AD_UNLOCK_SKINS   = { ["bored"]=true, ["stareyes"]=true }  -- 不屑冷漠/追星达人

-- ============================================================================
-- 公共 API
-- ============================================================================

--- 获取并清除按钮点击事件
---@return string|nil "back"
function ShopUI.GetButtonClicked()
    local r = buttonClicked_
    buttonClicked_ = nil
    return r
end

--- 重置商店状态（进入商店时调用）
function ShopUI.Reset()
    scrollY_ = 0; scrollVel_ = 0; maxScrollY_ = 0
    scrollYClass_ = 0; velClass_ = 0; maxScrollClass_ = 0
    scrollYSkin_  = 0; velSkin_ = 0; maxScrollSkin_  = 0
    buyResult_ = nil; buttonClicked_ = nil
    touchActive_ = false; touchSide_ = 0
    pendingAdUnlock_ = nil
end

--- 处理挂起的广告解锁请求（必须在 Update 阶段调用，不能在渲染回调中调用）
--- sdk:ShowRewardVideoAd 内部会修改渲染顺序，禁止在 NanoVGRender 中执行
function ShopUI.ProcessPendingAds()
    if not pendingAdUnlock_ then return end
    local pending = pendingAdUnlock_
    pendingAdUnlock_ = nil
    ---@diagnostic disable-next-line: undefined-global
    sdk:ShowRewardVideoAd(function(result)
        if result.success then
            if pending.type == "class" then
                local ok, _ = Economy.UnlockClassFree(pending.item.id)
                if ok then
                    buyResult_ = { text = "广告奖励！已解锁 " .. pending.item.name, color = Theme.success, timer = 2.0 }
                end
            else
                local ok, _ = Economy.UnlockSkinFree(pending.item.id)
                if ok then
                    buyResult_ = { text = "广告奖励！已解锁 " .. pending.item.name, color = Theme.success, timer = 2.0 }
                end
            end
        end
    end)
end

--- 绘制商店界面
---@param vg number NanoVG 上下文
---@param logW number 逻辑宽度
---@param logH number 逻辑高度
---@param uiScale number UI 缩放
---@param isMobile boolean 是否手机
---@param mousePress boolean 本帧是否有鼠标点击
---@param mx number 鼠标逻辑 X
---@param my number 鼠标逻辑 Y
function ShopUI.Draw(vg, logW, logH, uiScale, isMobile, mousePress, mx, my)
    -- =====================
    -- 处理滚动输入
    -- =====================
    handleScrollInput(vg, logW, logH, isMobile, mx, my, mousePress)

    -- =====================
    -- 全屏深紫背景
    -- =====================
    local bgPaint = nvgLinearGradient(vg, 0, 0, 0, logH,
        nvgRGBA(Theme.bg[1], Theme.bg[2], Theme.bg[3], 230),
        nvgRGBA(Theme.bgMid[1], Theme.bgMid[2], Theme.bgMid[3], 200))
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, logW, logH)
    nvgFillPaint(vg, bgPaint)
    nvgFill(vg)

    -- 装饰粒子
    local t = time.elapsedTime
    for i = 1, 20 do
        local speed = 0.1 + (i % 4) * 0.03
        local px = (math.sin(t * 0.15 + i * 2.1) * 0.5 + 0.5) * logW
        local py = math.fmod((1.0 - (t * speed * 0.06 + i * 0.11)) % 1.0, 1.0) * logH
        local alpha = math.abs(math.sin(t * 0.3 + i * 0.9)) * 30 + 8
        local radius = 1.0 + math.sin(t * 0.5 + i) * 0.6
        nvgBeginPath(vg)
        nvgCircle(vg, px, py, radius)
        if i % 3 == 0 then
            nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.accent, math.floor(alpha))))
        else
            nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, math.floor(alpha * 0.7))))
        end
        nvgFill(vg)
    end

    -- =====================
    -- 顶部标题栏
    -- =====================
    -- 移动端：状态栏+胶囊约占顶部 44px，header 需要更高以避开
    local safeTop = isMobile and 44 or 0
    local headerH = (isMobile and 88 or 52)
    local titleSize = isMobile and 20 or 28
    local coinSize = isMobile and 14 or 16
    local backBtnSize = isMobile and 44 or 40   -- 移动端更大触摸目标

    -- 返回按钮（左上角，大按钮，移动端位于安全区下方）
    local backPad = isMobile and 10 or 12
    local backX = backPad
    local backY = safeTop + (headerH - safeTop - backBtnSize) * 0.5
    local backHover = mx >= backX and mx <= backX + backBtnSize and my >= backY and my <= backY + backBtnSize

    nvgBeginPath(vg)
    nvgRoundedRect(vg, backX, backY, backBtnSize, backBtnSize, Theme.radiusSm)
    nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.surface, backHover and 230 or 170)))
    nvgFill(vg)
    if backHover then
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 60))
        nvgStrokeWidth(vg, 1)
        nvgBeginPath(vg)
        nvgRoundedRect(vg, backX, backY, backBtnSize, backBtnSize, Theme.radiusSm)
        nvgStroke(vg)
    end
    nvgFontFace(vg, "bold")
    nvgFontSize(vg, isMobile and 18 or 22)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, backHover and 255 or 210))
    nvgText(vg, backX + backBtnSize * 0.5, backY + backBtnSize * 0.5, "←")

    if mousePress and backHover and not touchDragging_ then
        buttonClicked_ = "back"
    end

    -- 标题（居中，移动端垂直居中于安全区以下的内容区）
    local titleCY = isMobile and (safeTop + (headerH - safeTop) * 0.5) or (headerH * 0.5)
    nvgFontFace(vg, "bold")
    nvgFontSize(vg, titleSize)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 120))
    nvgText(vg, logW * 0.5 + 1, titleCY + 1, "商店")
    nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 255)))
    nvgText(vg, logW * 0.5, titleCY, "商店")

    -- 金币显示（右上角，移动端避开 TapTap 胶囊：右留 100px + 垂直居中于安全区下方内容区）
    local coins = Economy.GetCoins()
    local coinText = "🪙 " .. tostring(coins)
    local coinRightPad = isMobile and 100 or 16
    local coinCY = isMobile and (safeTop + (headerH - safeTop) * 0.5) or (headerH * 0.5)
    nvgFontFace(vg, "bold")
    nvgFontSize(vg, coinSize)
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 240)))
    nvgText(vg, logW - coinRightPad, coinCY, coinText)

    -- =====================
    -- 购买结果提示（淡出）
    -- =====================
    local contentTop = headerH + (isMobile and 4 or 8)

    if buyResult_ then
        buyResult_.timer = buyResult_.timer - 0.016
        if buyResult_.timer <= 0 then
            buyResult_ = nil
        else
            local a = math.min(1.0, buyResult_.timer / 0.5) * 255
            nvgFontFace(vg, "bold")
            nvgFontSize(vg, isMobile and 12 or 16)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(buyResult_.color[1], buyResult_.color[2], buyResult_.color[3], math.floor(a)))
            nvgText(vg, logW * 0.5, contentTop - 2, buyResult_.text)
        end
    end

    -- =====================
    -- 瀑布流内容（职业 + 皮肤合并）
    -- =====================
    local classes = CharacterClass.GetAll()
    local allSkins = FaceSkin.GetAll()
    local selectedClassId = Economy.GetSelectedClassId()
    local selectedSkinId = Economy.GetSelectedSkinId()

    -- 裁剪区域（不让内容画到 header 上方）
    nvgSave(vg)
    nvgScissor(vg, 0, contentTop, logW, logH - contentTop)

    if isMobile then
        drawTwoColumnMobile(vg, logW, logH, contentTop, classes, allSkins, selectedClassId, selectedSkinId, mousePress, mx, my)
    else
        drawWaterfallGrid(vg, logW, logH, contentTop, classes, allSkins, selectedClassId, selectedSkinId, mousePress, mx, my)
    end

    nvgRestore(vg)

    -- 滚动条指示器
    drawScrollbar(vg, logW, logH, contentTop, isMobile)
end

-- ============================================================================
-- 滚动输入处理
-- ============================================================================

function handleScrollInput(vg, logW, logH, isMobile, mx, my, mousePress)
    local halfW = logW * 0.5

    -- 鼠标滚轮
    local wheel = input:GetMouseMoveWheel()
    if wheel ~= 0 then
        if isMobile then
            if mx < halfW then
                scrollYClass_ = scrollYClass_ - wheel * 30; velClass_ = 0
            else
                scrollYSkin_ = scrollYSkin_ - wheel * 30; velSkin_ = 0
            end
        else
            scrollY_ = scrollY_ - wheel * 30; scrollVel_ = 0
        end
    end

    -- 触摸/鼠标拖拽
    local mouseDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    if mousePress and not touchActive_ then
        touchActive_ = true
        touchDragging_ = false
        touchStartY_ = my
        touchLastY_ = my
        if isMobile then
            touchSide_ = (mx < halfW) and 1 or 2
            touchStartScrollY_ = (touchSide_ == 1) and scrollYClass_ or scrollYSkin_
        else
            touchSide_ = 0
            touchStartScrollY_ = scrollY_
        end
        scrollVel_ = 0; velClass_ = 0; velSkin_ = 0
    elseif touchActive_ and mouseDown then
        local totalDelta = math.abs(my - touchStartY_)
        if totalDelta > DRAG_THRESHOLD then touchDragging_ = true end
        if touchDragging_ then
            local deltaY = touchLastY_ - my
            touchLastY_ = my
            local newScroll = touchStartScrollY_ + (touchStartY_ - my)
            if isMobile then
                if touchSide_ == 1 then
                    scrollYClass_ = newScroll; velClass_ = deltaY
                else
                    scrollYSkin_ = newScroll; velSkin_ = deltaY
                end
            else
                scrollY_ = newScroll; scrollVel_ = deltaY
            end
        end
    elseif touchActive_ and not mouseDown then
        touchActive_ = false
    end

    -- 惯性滚动
    if not touchActive_ then
        if isMobile then
            if math.abs(velClass_) > 0.5 then
                scrollYClass_ = scrollYClass_ + velClass_; velClass_ = velClass_ * 0.92
            else velClass_ = 0 end
            if math.abs(velSkin_) > 0.5 then
                scrollYSkin_ = scrollYSkin_ + velSkin_; velSkin_ = velSkin_ * 0.92
            else velSkin_ = 0 end
        else
            if math.abs(scrollVel_) > 0.5 then
                scrollY_ = scrollY_ + scrollVel_; scrollVel_ = scrollVel_ * 0.92
            else scrollVel_ = 0 end
        end
    end

    -- 限制范围
    scrollY_ = math.max(0, math.min(scrollY_, maxScrollY_))
    scrollYClass_ = math.max(0, math.min(scrollYClass_, maxScrollClass_))
    scrollYSkin_  = math.max(0, math.min(scrollYSkin_,  maxScrollSkin_))
end

-- ============================================================================
-- 滚动条绘制
-- ============================================================================

function drawScrollbar(vg, logW, logH, contentTop, isMobile)
    local viewH = logH - contentTop
    if isMobile then
        -- 左面板滚动条（贴近分割线左侧）
        if maxScrollClass_ > 0 then
            local halfW = math.floor(logW * 0.5)
            local tH = viewH + maxScrollClass_
            local bH = math.max(16, (viewH / tH) * (viewH - 8))
            local bY = contentTop + 4 + (scrollYClass_ / maxScrollClass_) * (viewH - 8 - bH)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, halfW - 5, bY, 3, bH, 1.5)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 40))
            nvgFill(vg)
        end
        -- 右面板滚动条（贴右侧）
        if maxScrollSkin_ > 0 then
            local tH = viewH + maxScrollSkin_
            local bH = math.max(16, (viewH / tH) * (viewH - 8))
            local bY = contentTop + 4 + (scrollYSkin_ / maxScrollSkin_) * (viewH - 8 - bH)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, logW - 5, bY, 3, bH, 1.5)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 40))
            nvgFill(vg)
        end
    else
        if maxScrollY_ <= 0 then return end
        local tH = viewH + maxScrollY_
        local bH = math.max(20, (viewH / tH) * (viewH - 8))
        local bY = contentTop + 4 + (scrollY_ / maxScrollY_) * (viewH - 8 - bH)
        nvgBeginPath(vg)
        nvgRoundedRect(vg, logW - 5, bY, 3, bH, 1.5)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 40))
        nvgFill(vg)
    end
end

-- ============================================================================
-- 双面板布局：手机端（左职业2列/右表情2列，独立滚动）
-- ============================================================================

function drawTwoColumnMobile(vg, logW, logH, topY, classes, allSkins, selectedClassId, selectedSkinId, mousePress, mx, my)
    -- 屏幕两侧留白（避免卡片贴边，最少12px，最多5%）
    local screenPad = math.max(12, math.floor(logW * 0.05))
    local usableW   = logW - screenPad * 2
    local divW      = 2
    local panelW    = math.floor((usableW - divW) * 0.5)
    local leftX     = screenPad
    local rightX    = screenPad + panelW + divW

    -- 分割线
    nvgBeginPath(vg)
    nvgRect(vg, leftX + panelW, topY, divW, logH - topY)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 22))
    nvgFill(vg)

    local outerPad = 8
    local colGap   = 4
    local labelH   = 24
    local colW     = math.floor((panelW - outerPad * 2 - colGap) * 0.5)
    -- 窄卡（colW < 100）用 128，宽卡用 160 以避免 stat 文字与按钮重叠
    local cardH    = (colW < 100) and 128 or 160
    local cardGap  = 5
    local contentY = topY + labelH   -- 滚动内容从标题下方开始

    -- ─── 固定标题（不滚动，在裁剪区外绘制） ───
    nvgFontFace(vg, "bold")
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.accent, 200)))
    nvgText(vg, leftX  + panelW * 0.5, topY + labelH * 0.5, "— 职业 —")
    nvgText(vg, rightX + panelW * 0.5, topY + labelH * 0.5, "— 表情 —")

    -- ─── 左面板：职业（2列，独立滚动） ───
    nvgSave(vg)
    nvgIntersectScissor(vg, leftX, contentY, panelW, logH - contentY)
    for i, cls in ipairs(classes) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local cx  = leftX + outerPad + col * (colW + colGap)
        local cy  = contentY + row * (cardH + cardGap) - scrollYClass_
        if cy + cardH > contentY - 4 and cy < logH + 4 then
            drawClassCard(vg, cx, cy, colW, cardH, cls, selectedClassId, mousePress, mx, my, false)
        end
    end
    local classRows = math.ceil(#classes / 2)
    maxScrollClass_ = math.max(0, classRows * (cardH + cardGap) - cardGap - (logH - contentY) + 10)
    nvgRestore(vg)

    -- ─── 右面板：表情（2列，独立滚动） ───
    nvgSave(vg)
    nvgIntersectScissor(vg, rightX, contentY, panelW, logH - contentY)
    for i, skin in ipairs(allSkins) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local cx  = rightX + outerPad + col * (colW + colGap)
        local cy  = contentY + row * (cardH + cardGap) - scrollYSkin_
        if cy + cardH > contentY - 4 and cy < logH + 4 then
            drawSkinCard(vg, cx, cy, colW, cardH, skin, selectedSkinId, mousePress, mx, my, false)
        end
    end
    local skinRows = math.ceil(#allSkins / 2)
    maxScrollSkin_ = math.max(0, skinRows * (cardH + cardGap) - cardGap - (logH - contentY) + 10)
    nvgRestore(vg)
end

-- ============================================================================
-- 瀑布流布局：手机端（单列列表，保留备用）
-- ============================================================================

function drawWaterfallList(vg, logW, logH, topY, classes, allSkins, selectedClassId, selectedSkinId, mousePress, mx, my, isMobile)
    local cardW = math.min(logW - 24, 320)
    local cardH = 70
    local gap = 8
    local startX = math.floor((logW - cardW) * 0.5)
    local sectionGap = 16
    local sectionLabelH = 28

    local curY = 0  -- 虚拟Y（相对于 contentTop）

    -- --- 职业区块 ---
    curY = curY + 4
    -- 区块标题
    local labelY = topY + curY - scrollY_
    if labelY + sectionLabelH > topY - 10 and labelY < logH + 10 then
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, 14)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.accent, 200)))
        nvgText(vg, startX, labelY + sectionLabelH * 0.5, "— 职业 —")
    end
    curY = curY + sectionLabelH

    for i, cls in ipairs(classes) do
        local cy = topY + curY - scrollY_
        if cy + cardH > topY - 10 and cy < logH + 10 then
            drawClassCard(vg, startX, cy, cardW, cardH, cls, selectedClassId, mousePress, mx, my, true)
        end
        curY = curY + cardH + gap
    end

    -- --- 皮肤区块 ---
    curY = curY + sectionGap
    labelY = topY + curY - scrollY_
    if labelY + sectionLabelH > topY - 10 and labelY < logH + 10 then
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, 14)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.accent, 200)))
        nvgText(vg, startX, labelY + sectionLabelH * 0.5, "— 表情 —")
    end
    curY = curY + sectionLabelH

    for i, skin in ipairs(allSkins) do
        local cy = topY + curY - scrollY_
        if cy + cardH > topY - 10 and cy < logH + 10 then
            drawSkinCard(vg, startX, cy, cardW, cardH, skin, selectedSkinId, mousePress, mx, my, true)
        end
        curY = curY + cardH + gap
    end

    -- 底部留空
    curY = curY + 20
    -- 更新最大滚动范围
    local viewH = logH - topY
    maxScrollY_ = math.max(0, curY - viewH)
end

-- ============================================================================
-- 瀑布流布局：桌面端（网格）
-- ============================================================================

function drawWaterfallGrid(vg, logW, logH, topY, classes, allSkins, selectedClassId, selectedSkinId, mousePress, mx, my)
    local cols = 3
    local gap = 12
    local maxCardW = 180
    local totalW = cols * maxCardW + (cols - 1) * gap
    if totalW > logW * 0.92 then
        maxCardW = math.floor((logW * 0.92 - (cols - 1) * gap) / cols)
        totalW = cols * maxCardW + (cols - 1) * gap
    end
    local startX = math.floor((logW - totalW) * 0.5)
    local cardH = 160
    local sectionGap = 16
    local sectionLabelH = 30

    local curY = 0

    -- --- 职业区块 ---
    curY = curY + 4
    local labelY = topY + curY - scrollY_
    if labelY + sectionLabelH > topY - 10 and labelY < logH + 10 then
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.accent, 200)))
        nvgText(vg, startX, labelY + sectionLabelH * 0.5, "— 职业 —")
    end
    curY = curY + sectionLabelH

    for i, cls in ipairs(classes) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local cx = startX + col * (maxCardW + gap)
        local cy = topY + curY + row * (cardH + gap) - scrollY_

        if cy + cardH > topY - 10 and cy < logH + 10 then
            drawClassCard(vg, cx, cy, maxCardW, cardH, cls, selectedClassId, mousePress, mx, my, false)
        end
    end
    local classRows = math.ceil(#classes / cols)
    curY = curY + classRows * (cardH + gap)

    -- --- 皮肤区块（与职业统一三列布局）---
    curY = curY + sectionGap
    local skinCols = cols         -- 统一使用3列
    local skinCardW = maxCardW    -- 复用职业区块的卡片宽度
    local skinStartX = startX     -- 复用职业区块的起始X
    local skinCardH = 160         -- 统一卡片高度

    labelY = topY + curY - scrollY_
    if labelY + sectionLabelH > topY - 10 and labelY < logH + 10 then
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.accent, 200)))
        nvgText(vg, skinStartX, labelY + sectionLabelH * 0.5, "— 表情 —")
    end
    curY = curY + sectionLabelH

    for i, skin in ipairs(allSkins) do
        local col = (i - 1) % skinCols
        local row = math.floor((i - 1) / skinCols)
        local cx = skinStartX + col * (skinCardW + gap)
        local cy = topY + curY + row * (skinCardH + gap) - scrollY_

        if cy + skinCardH > topY - 10 and cy < logH + 10 then
            drawSkinCard(vg, cx, cy, skinCardW, skinCardH, skin, selectedSkinId, mousePress, mx, my, false)
        end
    end
    local skinRows = math.ceil(#allSkins / skinCols)
    curY = curY + skinRows * (skinCardH + gap)

    -- 底部留空
    curY = curY + 20
    local viewH = logH - topY
    maxScrollY_ = math.max(0, curY - viewH)
end

-- ============================================================================
-- 内部：单个职业卡片
-- ============================================================================

function drawClassCard(vg, x, y, w, h, cls, selectedId, mousePress, mx, my, compact)
    local isOwned = Economy.OwnsClass(cls.id)
    local isSelected = (cls.id == selectedId)
    local hovered = mx >= x and mx <= x + w and my >= y and my <= y + h

    -- 卡片背景
    local cornerR = Theme.radiusMd
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x + 1, y + 2, w, h, cornerR)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 60))
    nvgFill(vg)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x, y, w, h, cornerR)
    if isSelected then
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.bgMid, 240)))
    else
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.surface, hovered and 220 or 180)))
    end
    nvgFill(vg)
    if isSelected then
        nvgBeginPath(vg); nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgStrokeColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 200)))
        nvgStrokeWidth(vg, 2); nvgStroke(vg)
    elseif hovered then
        nvgBeginPath(vg); nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 40))
        nvgStrokeWidth(vg, 1); nvgStroke(vg)
    end

    -- 是否窄卡（移动端4列布局）
    local isNarrow = (not compact) and (w < 100)

    -- 角色形象参数
    local blockSize = compact and 24 or (isNarrow and 26 or 32)
    local blockX, blockY
    if compact then
        blockX = x + (20 - blockSize * 0.5)
        blockY = y + h * 0.35 - blockSize * 0.5
    elseif isNarrow then
        blockX = x + math.floor(w * 0.5 - blockSize * 0.5)
        blockY = y + 7
    else
        blockX = x + (w * 0.5 - blockSize * 0.5)
        blockY = y + 28 - blockSize * 0.5
    end
    local cornerR2 = math.floor(blockSize * 0.18)
    local outPad = compact and 2 or 3

    nvgBeginPath(vg)
    nvgRoundedRect(vg, blockX - outPad, blockY - outPad, blockSize + outPad*2, blockSize + outPad*2, cornerR2+1)
    nvgFillColor(vg, nvgRGBA(math.floor(cls.outlineColor.r*255), math.floor(cls.outlineColor.g*255), math.floor(cls.outlineColor.b*255), 255))
    nvgFill(vg)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, blockX, blockY, blockSize, blockSize, cornerR2)
    nvgFillColor(vg, nvgRGBA(math.floor(cls.bodyColor.r*255), math.floor(cls.bodyColor.g*255), math.floor(cls.bodyColor.b*255), 255))
    nvgFill(vg)
    local eyeR   = compact and 3.5 or (isNarrow and 3.8 or 4.5)
    local eyeGap = compact and 5   or (isNarrow and 5.5 or 6.5)
    local eyeCX  = blockX + blockSize * 0.5
    local eyeCY  = blockY + blockSize * 0.42
    nvgBeginPath(vg)
    nvgEllipse(vg, eyeCX - eyeGap, eyeCY, eyeR, eyeR*1.1)
    nvgEllipse(vg, eyeCX + eyeGap, eyeCY, eyeR, eyeR*1.1)
    nvgFillColor(vg, nvgRGBA(math.floor(cls.outlineColor.r*255), math.floor(cls.outlineColor.g*255), math.floor(cls.outlineColor.b*255), 255))
    nvgFill(vg)

    local dotR = blockSize * 0.5
    local dotX = blockX + blockSize * 0.5
    local dotY = blockY + blockSize * 0.5

    if compact then
        -- 横向紧凑布局（宽卡列表）
        local textX = dotX + dotR + 10
        local nameY = y + 14
        nvgFontFace(vg, "bold"); nvgFontSize(vg, 13)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, textX, nameY, cls.icon .. " " .. cls.name)
        nvgFontFace(vg, "sans"); nvgFontSize(vg, 10)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.textSec, 170)))
        nvgText(vg, textX, nameY + 17, cls.desc)
        local canAdUnlockCls = AD_UNLOCK_CLASSES[cls.id] and not isOwned and not isSelected
        local btnW = canAdUnlockCls and 110 or 64
        local btnH = 22
        local btnX = x + w - btnW - 8
        local btnY = y + h * 0.5 - btnH * 0.5
        drawActionButton(vg, btnX, btnY, btnW, btnH, cls, isOwned, isSelected, mousePress, mx, my)

    elseif isNarrow then
        -- 窄卡纵向布局（移动端4列）
        local cx = x + w * 0.5
        local nameY = blockY + blockSize + 6
        nvgFontFace(vg, "bold"); nvgFontSize(vg, 12)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, cx, nameY, cls.icon .. " " .. cls.name)

        nvgFontFace(vg, "sans"); nvgFontSize(vg, 9)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.textSec, 160)))
        nvgText(vg, cx, nameY + 15, cls.desc)

        local statText = getStatHighlight(cls)
        if statText then
            nvgFontFace(vg, "sans"); nvgFontSize(vg, 9)
            nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.accent, 220)))
            nvgText(vg, cx, nameY + 28, statText)
        end

        -- 按钮区（始终底部对齐，广告+金币左右并排，统一高度）
        local btnW = w - 8; local btnX = x + 4
        local btnH = 22
        local btnY = y + h - btnH - 5
        drawActionButton(vg, btnX, btnY, btnW, btnH, cls, isOwned, isSelected, mousePress, mx, my)

    else
        -- 标准纵向宽卡
        local nameY = dotY + dotR + 8
        nvgFontFace(vg, "bold"); nvgFontSize(vg, 15)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, x + w * 0.5, nameY, cls.icon .. " " .. cls.name)
        nvgFontFace(vg, "sans"); nvgFontSize(vg, 11)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.textSec, 170)))
        nvgText(vg, x + w * 0.5, nameY + 20, cls.desc)
        local statY = nameY + 36
        local statText = getStatHighlight(cls)
        if statText then
            nvgFontFace(vg, "sans"); nvgFontSize(vg, 10)
            nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.accent, 220)))
            nvgText(vg, x + w * 0.5, statY, statText)
            statY = statY + 14
        end
        local canAdUnlockCls2 = AD_UNLOCK_CLASSES[cls.id] and not isOwned and not isSelected
        local btnW = canAdUnlockCls2 and math.min(w - 16, 150) or math.min(w - 16, 90)
        local btnH = 26
        local btnX = x + (w - btnW) * 0.5
        local btnY = math.min(statY + 4, y + h - btnH - 8)
        drawActionButton(vg, btnX, btnY, btnW, btnH, cls, isOwned, isSelected, mousePress, mx, my)
    end
end

-- ============================================================================
-- 内部：单个皮肤卡片
-- ============================================================================

function drawSkinCard(vg, x, y, w, h, skin, selectedSkinId, mousePress, mx, my, compact)
    local isOwned = Economy.OwnsSkin(skin.id)
    local isSelected = (skin.id == selectedSkinId)
    local hovered = mx >= x and mx <= x + w and my >= y and my <= y + h

    local cornerR = Theme.radiusMd
    -- 阴影
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x + 1, y + 2, w, h, cornerR)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 60))
    nvgFill(vg)
    -- 主体
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x, y, w, h, cornerR)
    if isSelected then
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.bgMid, 240)))
    else
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.surface, hovered and 220 or 180)))
    end
    nvgFill(vg)

    -- 选中边框
    if isSelected then
        nvgBeginPath(vg)
        nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgStrokeColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 200)))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)
    elseif hovered then
        nvgBeginPath(vg)
        nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 40))
        nvgStrokeWidth(vg, 1)
        nvgStroke(vg)
    end

    -- FaceSkin 预览
    local previewBodyColor = Color(0.24, 0.60, 1.0, 1.0)
    local previewOutlineColor = Color(0.08, 0.20, 0.45, 1.0)

    -- 是否窄卡（移动端4列布局）
    local isNarrow = (not compact) and (w < 100)

    if compact then
        local blockSize = 28
        local prevCX = x + 22
        local prevCY = y + h * 0.40
        FaceSkin.DrawPreview(vg, prevCX, prevCY, blockSize, skin.id, previewBodyColor, previewOutlineColor)

        local textX = prevCX + blockSize * 0.5 + 14
        local nameY = y + 12

        nvgFontFace(vg, "bold")
        nvgFontSize(vg, 13)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, textX, nameY, skin.icon .. " " .. skin.name)

        nvgFontFace(vg, "sans")
        nvgFontSize(vg, 10)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.textSec, 170)))
        nvgText(vg, textX, nameY + 17, skin.desc)

        local canAdUnlockSk = AD_UNLOCK_SKINS[skin.id] and not isOwned and not isSelected
        local btnW = canAdUnlockSk and 110 or 64
        local btnH = 22
        local btnX = x + w - btnW - 8
        local btnY = y + h * 0.5 - btnH * 0.5
        drawSkinActionButton(vg, btnX, btnY, btnW, btnH, skin, isOwned, isSelected, mousePress, mx, my)

    elseif isNarrow then
        -- 窄卡纵向布局（移动端4列）
        local blockSize = 28
        local prevCX = x + w * 0.5
        local prevCY = y + 10 + blockSize * 0.5
        FaceSkin.DrawPreview(vg, prevCX, prevCY, blockSize, skin.id, previewBodyColor, previewOutlineColor)

        local cx   = x + w * 0.5
        local nameY = prevCY + blockSize * 0.5 + 6

        nvgFontFace(vg, "bold")
        nvgFontSize(vg, 12)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, cx, nameY, skin.icon .. " " .. skin.name)

        nvgFontFace(vg, "sans")
        nvgFontSize(vg, 9)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.textSec, 160)))
        nvgText(vg, cx, nameY + 15, skin.desc)

        -- 按钮区（始终底部对齐，广告+金币左右并排，统一高度）
        local btnW = w - 8; local btnX = x + 4
        local btnH = 22
        local btnY = y + h - btnH - 5
        drawSkinActionButton(vg, btnX, btnY, btnW, btnH, skin, isOwned, isSelected, mousePress, mx, my)

    else
        local blockSize = 36
        local prevCX = x + w * 0.5
        local prevCY = y + 30
        FaceSkin.DrawPreview(vg, prevCX, prevCY, blockSize, skin.id, previewBodyColor, previewOutlineColor)

        local nameY = prevCY + blockSize * 0.5 + 10

        nvgFontFace(vg, "bold")
        nvgFontSize(vg, 13)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, x + w * 0.5, nameY, skin.icon .. " " .. skin.name)

        nvgFontFace(vg, "sans")
        nvgFontSize(vg, 10)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.textSec, 170)))
        nvgText(vg, x + w * 0.5, nameY + 18, skin.desc)

        local canAdUnlockSk2 = AD_UNLOCK_SKINS[skin.id] and not isOwned and not isSelected
        local btnW = canAdUnlockSk2 and math.min(w - 16, 150) or math.min(w - 16, 90)
        local btnH = 24
        local btnX = x + (w - btnW) * 0.5
        local btnY = math.min(nameY + 36, y + h - btnH - 6)
        drawSkinActionButton(vg, btnX, btnY, btnW, btnH, skin, isOwned, isSelected, mousePress, mx, my)
    end
end

-- ============================================================================
-- 内部：职业操作按钮
-- ============================================================================

function drawActionButton(vg, x, y, w, h, cls, isOwned, isSelected, mousePress, mx, my)
    local hovered = mx >= x and mx <= x + w and my >= y and my <= y + h
    local cornerR = Theme.radiusSm

    if isSelected then
        nvgBeginPath(vg)
        nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 60)))
        nvgFill(vg)
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.floor(h * 0.48))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 200)))
        nvgText(vg, x + w * 0.5, y + h * 0.5, "已装备")
    elseif isOwned then
        nvgBeginPath(vg)
        nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.secondary, hovered and 220 or 160)))
        nvgFill(vg)
        if hovered then
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 40))
            nvgStrokeWidth(vg, 1)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, x, y, w, h, cornerR)
            nvgStroke(vg)
        end
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.floor(h * 0.48))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
        nvgText(vg, x + w * 0.5, y + h * 0.5, "选择")

        if mousePress and hovered and not touchDragging_ then
            Economy.SelectClass(cls.id)
            buyResult_ = { text = "已选择 " .. cls.name .. "!", color = Theme.success, timer = 1.5 }
        end
    elseif AD_UNLOCK_CLASSES[cls.id] then
        -- 广告解锁：左右并排（广告在左，金币在右）
        local gap   = 4
        local adW   = math.floor((w - gap) * 0.46)
        local coinW = w - gap - adW
        local adX   = x
        local coinX = x + adW + gap

        -- 广告按钮（左）
        local adHover = mx >= adX and mx <= adX + adW and my >= y and my <= y + h
        local adColor = { 50, 180, 80 }
        nvgBeginPath(vg)
        nvgRoundedRect(vg, adX, y, adW, h, cornerR)
        nvgFillColor(vg, nvgRGBA(adColor[1], adColor[2], adColor[3], adHover and 240 or 200))
        nvgFill(vg)
        if adHover then
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 50))
            nvgStrokeWidth(vg, 1)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, adX, y, adW, h, cornerR)
            nvgStroke(vg)
        end
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.max(8, math.floor(h * 0.50)))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, adX + adW * 0.5, y + h * 0.5, "🎬广告")

        if mousePress and adHover and not touchDragging_ then
            pendingAdUnlock_ = { type = "class", item = cls }
        end

        -- 金币按钮（右）
        local canAfford   = Economy.GetCoins() >= cls.price
        local coinBtnColor = canAfford and Theme.primary or Theme.disabled
        local textAlpha   = canAfford and 255 or 120
        local coinHover   = mx >= coinX and mx <= coinX + coinW and my >= y and my <= y + h

        nvgBeginPath(vg)
        nvgRoundedRect(vg, coinX, y, coinW, h, cornerR)
        nvgFillColor(vg, nvgRGBA(coinBtnColor[1], coinBtnColor[2], coinBtnColor[3], coinHover and 240 or 200))
        nvgFill(vg)
        if canAfford then
            local dark = nvgLinearGradient(vg, coinX, y + h * 0.6, coinX, y + h,
                nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 0, 0, 50))
            nvgBeginPath(vg)
            nvgRoundedRect(vg, coinX, y, coinW, h, cornerR)
            nvgFillPaint(vg, dark)
            nvgFill(vg)
        end
        if coinHover and canAfford then
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 50))
            nvgStrokeWidth(vg, 1)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, coinX, y, coinW, h, cornerR)
            nvgStroke(vg)
        end
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.max(8, math.floor(h * 0.50)))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(canAfford and 30 or 255, canAfford and 15 or 255, canAfford and 0 or 255, textAlpha))
        nvgText(vg, coinX + coinW * 0.5, y + h * 0.5, "🪙" .. cls.price)

        if mousePress and coinHover and canAfford and not touchDragging_ then
            local ok, err = Economy.BuyClass(cls.id)
            if ok then
                buyResult_ = { text = "购买成功！已装备 " .. cls.name, color = Theme.success, timer = 2.0 }
            else
                if err == "not_enough_coins" then
                    buyResult_ = { text = "金币不足！", color = Theme.error, timer = 1.5 }
                end
            end
        end
    else
        -- 仅金币购买
        local canAfford = Economy.GetCoins() >= cls.price
        local btnColor = canAfford and Theme.primary or Theme.disabled
        local textAlpha = canAfford and 255 or 120

        nvgBeginPath(vg)
        nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgFillColor(vg, nvgRGBA(btnColor[1], btnColor[2], btnColor[3], hovered and 240 or 200))
        nvgFill(vg)
        if canAfford then
            local dark = nvgLinearGradient(vg, x, y + h * 0.6, x, y + h,
                nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 0, 0, 50))
            nvgBeginPath(vg)
            nvgRoundedRect(vg, x, y, w, h, cornerR)
            nvgFillPaint(vg, dark)
            nvgFill(vg)
        end
        if hovered and canAfford then
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 50))
            nvgStrokeWidth(vg, 1)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, x, y, w, h, cornerR)
            nvgStroke(vg)
        end

        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.floor(h * 0.44))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        if canAfford then
            nvgFillColor(vg, nvgRGBA(30, 15, 0, textAlpha))
        else
            nvgFillColor(vg, nvgRGBA(255, 255, 255, textAlpha))
        end
        nvgText(vg, x + w * 0.5, y + h * 0.5, "🪙 " .. cls.price)

        if mousePress and hovered and canAfford and not touchDragging_ then
            local ok, err = Economy.BuyClass(cls.id)
            if ok then
                buyResult_ = { text = "购买成功！已装备 " .. cls.name, color = Theme.success, timer = 2.0 }
            else
                if err == "not_enough_coins" then
                    buyResult_ = { text = "金币不足！", color = Theme.error, timer = 1.5 }
                end
            end
        end
    end
end

-- ============================================================================
-- 内部：皮肤操作按钮
-- ============================================================================

function drawSkinActionButton(vg, x, y, w, h, skin, isOwned, isSelected, mousePress, mx, my)
    local hovered = mx >= x and mx <= x + w and my >= y and my <= y + h
    local cornerR = Theme.radiusSm

    if isSelected then
        nvgBeginPath(vg)
        nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 60)))
        nvgFill(vg)
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.floor(h * 0.48))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 200)))
        nvgText(vg, x + w * 0.5, y + h * 0.5, "已装备")
    elseif isOwned then
        nvgBeginPath(vg)
        nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.secondary, hovered and 220 or 160)))
        nvgFill(vg)
        if hovered then
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 40))
            nvgStrokeWidth(vg, 1)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, x, y, w, h, cornerR)
            nvgStroke(vg)
        end
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.floor(h * 0.48))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
        nvgText(vg, x + w * 0.5, y + h * 0.5, "选择")

        if mousePress and hovered and not touchDragging_ then
            Economy.SelectSkin(skin.id)
            buyResult_ = { text = "已选择 " .. skin.name .. "!", color = Theme.success, timer = 1.5 }
        end
    elseif AD_UNLOCK_SKINS[skin.id] then
        -- 广告解锁：左右并排（广告在左，金币在右）
        local gap   = 4
        local adW   = math.floor((w - gap) * 0.46)
        local coinW = w - gap - adW
        local adX   = x
        local coinX = x + adW + gap

        -- 广告按钮（左）
        local adHover = mx >= adX and mx <= adX + adW and my >= y and my <= y + h
        local adColor = { 50, 180, 80 }
        nvgBeginPath(vg)
        nvgRoundedRect(vg, adX, y, adW, h, cornerR)
        nvgFillColor(vg, nvgRGBA(adColor[1], adColor[2], adColor[3], adHover and 240 or 200))
        nvgFill(vg)
        if adHover then
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 50))
            nvgStrokeWidth(vg, 1)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, adX, y, adW, h, cornerR)
            nvgStroke(vg)
        end
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.max(8, math.floor(h * 0.50)))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, adX + adW * 0.5, y + h * 0.5, "🎬广告")

        if mousePress and adHover and not touchDragging_ then
            pendingAdUnlock_ = { type = "skin", item = skin }
        end

        -- 金币按钮（右）
        local canAfford    = Economy.GetCoins() >= skin.price
        local coinBtnColor = canAfford and Theme.primary or Theme.disabled
        local textAlpha    = canAfford and 255 or 120
        local coinHover    = mx >= coinX and mx <= coinX + coinW and my >= y and my <= y + h

        nvgBeginPath(vg)
        nvgRoundedRect(vg, coinX, y, coinW, h, cornerR)
        nvgFillColor(vg, nvgRGBA(coinBtnColor[1], coinBtnColor[2], coinBtnColor[3], coinHover and 240 or 200))
        nvgFill(vg)
        if canAfford then
            local dark = nvgLinearGradient(vg, coinX, y + h * 0.6, coinX, y + h,
                nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 0, 0, 50))
            nvgBeginPath(vg)
            nvgRoundedRect(vg, coinX, y, coinW, h, cornerR)
            nvgFillPaint(vg, dark)
            nvgFill(vg)
        end
        if coinHover and canAfford then
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 50))
            nvgStrokeWidth(vg, 1)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, coinX, y, coinW, h, cornerR)
            nvgStroke(vg)
        end
        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.max(8, math.floor(h * 0.50)))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(canAfford and 30 or 255, canAfford and 15 or 255, canAfford and 0 or 255, textAlpha))
        nvgText(vg, coinX + coinW * 0.5, y + h * 0.5, "🪙" .. skin.price)

        if mousePress and coinHover and canAfford and not touchDragging_ then
            local ok, err = Economy.BuySkin(skin.id)
            if ok then
                buyResult_ = { text = "购买成功！已装备 " .. skin.name, color = Theme.success, timer = 2.0 }
            else
                if err == "not_enough_coins" then
                    buyResult_ = { text = "金币不足！", color = Theme.error, timer = 1.5 }
                end
            end
        end
    else
        -- 仅金币购买
        local canAfford = Economy.GetCoins() >= skin.price
        local btnColor = canAfford and Theme.primary or Theme.disabled
        local textAlpha = canAfford and 255 or 120

        nvgBeginPath(vg)
        nvgRoundedRect(vg, x, y, w, h, cornerR)
        nvgFillColor(vg, nvgRGBA(btnColor[1], btnColor[2], btnColor[3], hovered and 240 or 200))
        nvgFill(vg)
        if canAfford then
            local dark = nvgLinearGradient(vg, x, y + h * 0.6, x, y + h,
                nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 0, 0, 50))
            nvgBeginPath(vg)
            nvgRoundedRect(vg, x, y, w, h, cornerR)
            nvgFillPaint(vg, dark)
            nvgFill(vg)
        end
        if hovered and canAfford then
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 50))
            nvgStrokeWidth(vg, 1)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, x, y, w, h, cornerR)
            nvgStroke(vg)
        end

        nvgFontFace(vg, "bold")
        nvgFontSize(vg, math.floor(h * 0.44))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        if canAfford then
            nvgFillColor(vg, nvgRGBA(30, 15, 0, textAlpha))
        else
            nvgFillColor(vg, nvgRGBA(255, 255, 255, textAlpha))
        end
        nvgText(vg, x + w * 0.5, y + h * 0.5, "🪙 " .. skin.price)

        if mousePress and hovered and canAfford and not touchDragging_ then
            local ok, err = Economy.BuySkin(skin.id)
            if ok then
                buyResult_ = { text = "购买成功！已装备 " .. skin.name, color = Theme.success, timer = 2.0 }
            else
                if err == "not_enough_coins" then
                    buyResult_ = { text = "金币不足！", color = Theme.error, timer = 1.5 }
                end
            end
        end
    end
end

-- ============================================================================
-- 内部：属性高亮文本
-- ============================================================================

function getStatHighlight(cls)
    if cls.id == 1 then return nil end
    if cls.maxJumps > 2 then return "★ 三段跳" end
    if cls.energyChargeTime < 15 then return "★ 能量回复+40%" end
    if cls.dashCount > 1 then return "★ 连冲两次" end
    if cls.slamStunDuration > 1.5 then return "★ 晕眩×2" end
    if cls.explosionChargeTime < 2.0 then return "★ 蓄力+50%" end
    return nil
end

return ShopUI

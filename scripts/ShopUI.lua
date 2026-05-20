-- ============================================================================
-- ShopUI.lua - 商店界面（NanoVG 绘制，Astroon 主题）
-- 由 HUD.DrawShop() 调用，展示职业/皮肤列表、购买/选中、金币余额
-- ============================================================================

local CharacterClass = require("CharacterClass")
local Economy = require("Economy")
local FaceSkin = require("FaceSkin")
local Theme = require("Theme")

local ShopUI = {}

-- 内部状态
local scrollY_ = 0           -- 滚动偏移（手机端）
local selectedPreview_ = nil  -- 正在预览的职业 ID（点击卡片高亮）
local buyResult_ = nil        -- 购买结果提示 { text, color, timer }
local buttonClicked_ = nil    -- "back" | nil
local currentTab_ = "class"   -- "class" | "skin"

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
    scrollY_ = 0
    selectedPreview_ = Economy.GetSelectedClassId()
    buyResult_ = nil
    buttonClicked_ = nil
    currentTab_ = "class"
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
    local headerH = isMobile and 36 or 52
    local titleSize = isMobile and 18 or 28
    local coinSize = isMobile and 13 or 16

    -- 标题
    nvgFontFace(vg, "bold")
    nvgFontSize(vg, titleSize)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 120))
    nvgText(vg, 17, headerH * 0.5 + 1, "商店")
    nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 255)))
    nvgText(vg, 16, headerH * 0.5, "商店")

    -- 金币显示（右上角）
    local coins = Economy.GetCoins()
    local coinText = "🪙 " .. tostring(coins)
    nvgFontFace(vg, "bold")
    nvgFontSize(vg, coinSize)
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 240)))
    nvgText(vg, logW - 16, headerH * 0.5, coinText)

    -- 返回按钮（金币左边）
    local backW = isMobile and 48 or 64
    local backH = isMobile and 22 or 30
    local coinTextWidth = 80
    local backX = logW - coinTextWidth - backW - 24
    local backY = headerH * 0.5 - backH * 0.5

    local backHover = mx >= backX and mx <= backX + backW and my >= backY and my <= backY + backH
    nvgBeginPath(vg)
    nvgRoundedRect(vg, backX, backY, backW, backH, Theme.radiusSm)
    nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.surface, backHover and 220 or 160)))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, backHover and 60 or 25))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)
    nvgFontFace(vg, "sans")
    nvgFontSize(vg, isMobile and 11 or 14)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, backHover and 255 or 200))
    nvgText(vg, backX + backW * 0.5, backY + backH * 0.5, "← 返回")

    if mousePress and backHover then
        buttonClicked_ = "back"
    end

    -- =====================
    -- Tab 切换栏
    -- =====================
    local tabH = isMobile and 26 or 32
    local tabY = headerH + 2
    local tabW = isMobile and 60 or 80
    local tabGap = isMobile and 6 or 8
    local tabTotalW = tabW * 2 + tabGap
    local tabStartX = 16

    local tabs = {
        { key = "class", label = "职业" },
        { key = "skin",  label = "表情" },
    }

    for i, tab in ipairs(tabs) do
        local tx = tabStartX + (i - 1) * (tabW + tabGap)
        local isActive = (currentTab_ == tab.key)
        local tabHover = mx >= tx and mx <= tx + tabW and my >= tabY and my <= tabY + tabH

        nvgBeginPath(vg)
        nvgRoundedRect(vg, tx, tabY, tabW, tabH, Theme.radiusSm)
        if isActive then
            nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.primary, 200)))
        else
            nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.surface, tabHover and 200 or 130)))
        end
        nvgFill(vg)

        if not isActive and tabHover then
            nvgBeginPath(vg)
            nvgRoundedRect(vg, tx, tabY, tabW, tabH, Theme.radiusSm)
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 30))
            nvgStrokeWidth(vg, 1)
            nvgStroke(vg)
        end

        nvgFontFace(vg, "bold")
        nvgFontSize(vg, isMobile and 11 or 14)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        if isActive then
            nvgFillColor(vg, nvgRGBA(30, 15, 0, 255))
        else
            nvgFillColor(vg, nvgRGBA(255, 255, 255, tabHover and 240 or 180))
        end
        nvgText(vg, tx + tabW * 0.5, tabY + tabH * 0.5, tab.label)

        if mousePress and tabHover and not isActive then
            currentTab_ = tab.key
            scrollY_ = 0
            buyResult_ = nil
        end
    end

    -- =====================
    -- 购买结果提示（淡出）
    -- =====================
    local contentTop = tabY + tabH + (isMobile and 8 or 12)

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
    -- 分页内容
    -- =====================
    if currentTab_ == "class" then
        local classes = CharacterClass.GetAll()
        local selectedId = Economy.GetSelectedClassId()
        if isMobile then
            drawCardList(vg, logW, logH, contentTop, classes, selectedId, mousePress, mx, my, true)
        else
            drawCardGrid(vg, logW, logH, contentTop, classes, selectedId, mousePress, mx, my)
        end
    else
        local allSkins = FaceSkin.GetAll()
        local selectedSkinId = Economy.GetSelectedSkinId()
        if isMobile then
            drawSkinList(vg, logW, logH, contentTop, allSkins, selectedSkinId, mousePress, mx, my)
        else
            drawSkinGrid(vg, logW, logH, contentTop, allSkins, selectedSkinId, mousePress, mx, my)
        end
    end
end

-- ============================================================================
-- 内部：桌面端网格布局（2 行 3 列）——职业
-- ============================================================================

function drawCardGrid(vg, logW, logH, topY, classes, selectedId, mousePress, mx, my)
    local cols = 3
    local gap = 12
    local maxCardW = 180
    local totalW = cols * maxCardW + (cols - 1) * gap
    if totalW > logW * 0.92 then
        maxCardW = math.floor((logW * 0.92 - (cols - 1) * gap) / cols)
        totalW = cols * maxCardW + (cols - 1) * gap
    end
    local startX = math.floor((logW - totalW) * 0.5)
    local cardH = math.min(160, math.floor((logH - topY - 20) * 0.5 - gap * 0.5))

    for i, cls in ipairs(classes) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local cx = startX + col * (maxCardW + gap)
        local cy = topY + row * (cardH + gap)

        drawClassCard(vg, cx, cy, maxCardW, cardH, cls, selectedId, mousePress, mx, my, false)
    end
end

-- ============================================================================
-- 内部：手机端竖向列表——职业
-- ============================================================================

function drawCardList(vg, logW, logH, topY, classes, selectedId, mousePress, mx, my, isMobile)
    local cardW = math.min(logW - 24, 280)
    local cardH = 70
    local gap = 8
    local startX = math.floor((logW - cardW) * 0.5)

    for i, cls in ipairs(classes) do
        local cy = topY + (i - 1) * (cardH + gap) - scrollY_
        if cy + cardH > topY - 10 and cy < logH + 10 then
            drawClassCard(vg, startX, cy, cardW, cardH, cls, selectedId, mousePress, mx, my, true)
        end
    end
end

-- ============================================================================
-- 内部：桌面端网格布局——皮肤
-- ============================================================================

function drawSkinGrid(vg, logW, logH, topY, allSkins, selectedSkinId, mousePress, mx, my)
    local cols = 4
    local gap = 10
    local maxCardW = 150
    local totalW = cols * maxCardW + (cols - 1) * gap
    if totalW > logW * 0.92 then
        maxCardW = math.floor((logW * 0.92 - (cols - 1) * gap) / cols)
        totalW = cols * maxCardW + (cols - 1) * gap
    end
    local startX = math.floor((logW - totalW) * 0.5)
    local cardH = math.min(140, math.floor((logH - topY - 20) * 0.5 - gap * 0.5))

    for i, skin in ipairs(allSkins) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local cx = startX + col * (maxCardW + gap)
        local cy = topY + row * (cardH + gap)

        drawSkinCard(vg, cx, cy, maxCardW, cardH, skin, selectedSkinId, mousePress, mx, my, false)
    end
end

-- ============================================================================
-- 内部：手机端竖向列表——皮肤
-- ============================================================================

function drawSkinList(vg, logW, logH, topY, allSkins, selectedSkinId, mousePress, mx, my)
    local cardW = math.min(logW - 24, 280)
    local cardH = 70
    local gap = 8
    local startX = math.floor((logW - cardW) * 0.5)

    for i, skin in ipairs(allSkins) do
        local cy = topY + (i - 1) * (cardH + gap) - scrollY_
        if cy + cardH > topY - 10 and cy < logH + 10 then
            drawSkinCard(vg, startX, cy, cardW, cardH, skin, selectedSkinId, mousePress, mx, my, true)
        end
    end
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

    -- 选中边框高亮
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

    -- 职业角色形象（圆角方块 + 描边 + 眼睛）
    local blockSize = compact and 24 or 32
    local blockX = x + (compact and (20 - blockSize * 0.5) or (w * 0.5 - blockSize * 0.5))
    local blockY = compact and (y + h * 0.35 - blockSize * 0.5) or (y + 28 - blockSize * 0.5)
    local cornerR2 = math.floor(blockSize * 0.18)

    -- 描边层
    local outPad = compact and 2 or 3
    nvgBeginPath(vg)
    nvgRoundedRect(vg, blockX - outPad, blockY - outPad, blockSize + outPad * 2, blockSize + outPad * 2, cornerR2 + 1)
    nvgFillColor(vg, nvgRGBA(
        math.floor(cls.outlineColor.r * 255),
        math.floor(cls.outlineColor.g * 255),
        math.floor(cls.outlineColor.b * 255), 255))
    nvgFill(vg)
    -- 身体方块
    nvgBeginPath(vg)
    nvgRoundedRect(vg, blockX, blockY, blockSize, blockSize, cornerR2)
    nvgFillColor(vg, nvgRGBA(
        math.floor(cls.bodyColor.r * 255),
        math.floor(cls.bodyColor.g * 255),
        math.floor(cls.bodyColor.b * 255), 255))
    nvgFill(vg)
    -- 眼睛
    local eyeR = compact and 3.5 or 4.5
    local eyeGap = compact and 5 or 6.5
    local eyeCX = blockX + blockSize * 0.5
    local eyeCY = blockY + blockSize * 0.42
    nvgBeginPath(vg)
    nvgEllipse(vg, eyeCX - eyeGap, eyeCY, eyeR, eyeR * 1.1)
    nvgEllipse(vg, eyeCX + eyeGap, eyeCY, eyeR, eyeR * 1.1)
    nvgFillColor(vg, nvgRGBA(
        math.floor(cls.outlineColor.r * 255),
        math.floor(cls.outlineColor.g * 255),
        math.floor(cls.outlineColor.b * 255), 255))
    nvgFill(vg)

    local dotR = blockSize * 0.5
    local dotX = blockX + blockSize * 0.5
    local dotY = blockY + blockSize * 0.5

    if compact then
        local textX = dotX + dotR + 10
        local nameY = y + 14

        nvgFontFace(vg, "bold")
        nvgFontSize(vg, 13)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, textX, nameY, cls.icon .. " " .. cls.name)

        nvgFontFace(vg, "sans")
        nvgFontSize(vg, 10)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.textSec, 170)))
        nvgText(vg, textX, nameY + 17, cls.desc)

        local btnW = 52
        local btnH = 22
        local btnX = x + w - btnW - 8
        local btnY = y + h * 0.5 - btnH * 0.5
        drawActionButton(vg, btnX, btnY, btnW, btnH, cls, isOwned, isSelected, mousePress, mx, my)
    else
        local nameY = dotY + dotR + 8

        nvgFontFace(vg, "bold")
        nvgFontSize(vg, 15)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, x + w * 0.5, nameY, cls.icon .. " " .. cls.name)

        nvgFontFace(vg, "sans")
        nvgFontSize(vg, 11)
        nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.textSec, 170)))
        nvgText(vg, x + w * 0.5, nameY + 20, cls.desc)

        local statY = nameY + 36
        local statText = getStatHighlight(cls)
        if statText then
            nvgFontFace(vg, "sans")
            nvgFontSize(vg, 10)
            nvgFillColor(vg, nvgRGBA(Theme.rgba(Theme.accent, 220)))
            nvgText(vg, x + w * 0.5, statY, statText)
            statY = statY + 14
        end

        local btnW = 80
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

    -- 使用 FaceSkin.DrawPreview 绘制角色预览
    -- 用默认玩家颜色（蓝色系）
    local previewBodyColor = Color(0.24, 0.60, 1.0, 1.0)
    local previewOutlineColor = Color(0.08, 0.20, 0.45, 1.0)

    if compact then
        -- 紧凑布局：左边预览，右边文字
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

        local btnW = 52
        local btnH = 22
        local btnX = x + w - btnW - 8
        local btnY = y + h * 0.5 - btnH * 0.5
        drawSkinActionButton(vg, btnX, btnY, btnW, btnH, skin, isOwned, isSelected, mousePress, mx, my)
    else
        -- 标准布局：上方预览，下方文字
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

        local btnW = 72
        local btnH = 24
        local btnX = x + (w - btnW) * 0.5
        local btnY = math.min(nameY + 36, y + h - btnH - 6)
        drawSkinActionButton(vg, btnX, btnY, btnW, btnH, skin, isOwned, isSelected, mousePress, mx, my)
    end
end

-- ============================================================================
-- 内部：职业操作按钮（购买/选中/已装备）
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
        nvgText(vg, x + w * 0.5, y + h * 0.5, "已装备 ✓")
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

        if mousePress and hovered then
            Economy.SelectClass(cls.id)
            buyResult_ = { text = "已选择 " .. cls.name .. "!", color = Theme.success, timer = 1.5 }
        end
    else
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

        if mousePress and hovered and canAfford then
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
-- 内部：皮肤操作按钮（购买/选中/已装备）
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
        nvgText(vg, x + w * 0.5, y + h * 0.5, "已装备 ✓")
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

        if mousePress and hovered then
            Economy.SelectSkin(skin.id)
            buyResult_ = { text = "已选择 " .. skin.name .. "!", color = Theme.success, timer = 1.5 }
        end
    else
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

        if mousePress and hovered and canAfford then
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
    if cls.energyChargeTime < 15 then return "★ 能量+20%" end
    if cls.dashCount > 1 then return "★ 连冲两次" end
    if cls.slamStunDuration > 1.5 then return "★ 晕眩×2" end
    if cls.explosionChargeTime < 2.0 then return "★ 蓄力+50%" end
    return nil
end

return ShopUI

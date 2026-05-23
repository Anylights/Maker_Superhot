-- ============================================================================
-- Tutorial.lua - 新手教程系统（9步引导）
-- 独立关卡，首次进入自动触发，通关后不再出现
-- ============================================================================

local Config = require("Config")
local Theme = require("Theme")
local Economy = require("Economy")

local Tutorial = {}

-- 模块引用（由 Init 注入）
local playerModule_ = nil
local gameManager_ = nil
local mapModule_ = nil

-- NanoVG 上下文（由 Draw 传入）
local vg_ = nil

-- 教程状态
local active_ = false        -- 教程是否激活
local currentStep_ = 0       -- 当前步骤（1-9）
local stepTimer_ = 0         -- 步骤内计时器
local stepDone_ = false      -- 当前步骤的动作是否已完成
local showNext_ = false      -- 是否显示"继续"提示
local fadeAlpha_ = 0         -- 遮罩淡入淡出
local introTimer_ = 0        -- 开场动画计时
local completedActions_ = {} -- 已完成的动作追踪

-- 跳过确认
local skipConfirm_ = false   -- 是否显示跳过确认对话框

-- 平台检测
local isMobile_ = false

-- 动画
local pulseTimer_ = 0        -- 脉冲动画
local arrowBounce_ = 0       -- 箭头弹跳

-- 步骤追踪数据
local moveLeftDone_ = false
local moveRightDone_ = false
local jumpDone_ = false
local slamDone_ = false
local dashDone_ = false
local chargeDone_ = false
local explodeDone_ = false

-- 分辨率
local logW_, logH_ = 0, 0
local uiScale_ = 1.0

-- 缓存输入
local cachedPress_ = false
local cachedMX_ = 0
local cachedMY_ = 0

-- 移动端控制区域排除矩形（防止点击虚拟控制触发"点击继续"）
-- 格式：{ {x1,y1,x2,y2}, ... }  逻辑坐标
local mobileExcludeRects_ = {}

-- ============================================================================
-- 教程步骤定义
-- ============================================================================

local STEPS = {
    -- 步骤1：欢迎
    {
        id = "welcome",
        title = "欢迎来到 超级红温！",
        desc_pc = "你是一颗愤怒的小球，目标是疯狂攀爬、击败对手、拿到最高分！\n准备好了吗？点击任意位置继续！",
        desc_mobile = "你是一颗愤怒的小球，目标是疯狂攀爬、击败对手、拿到最高分！\n准备好了吗？点击任意位置继续！",
        check = function() return cachedPress_ end,
    },
    -- 步骤2：移动
    {
        id = "move",
        title = "基础移动",
        desc_pc = "按 A / D 或 方向键 ← → 来左右移动\n先试试左右各走一走吧！",
        desc_mobile = "拖动左侧摇杆来左右移动\n先试试左右各走一走吧！",
        check = function()
            return moveLeftDone_ and moveRightDone_
        end,
    },
    -- 步骤3：跳跃
    {
        id = "jump",
        title = "跳跃 & 二段跳",
        desc_pc = "按 空格键 跳跃，空中再按一次可以二段跳！\n试试跳到上面的平台上吧！",
        desc_mobile = "点 [跳] 按钮跳跃，空中再点一次可以二段跳！\n试试跳到上面的平台上吧！",
        check = function() return jumpDone_ end,
    },
    -- 步骤4：下砸
    {
        id = "slam",
        title = "下砸攻击",
        desc_pc = "在空中按 S 或 ↓ 高速下砸！\n砸到地面会震飞周围的敌人，让他们眩晕！\n跳起来，然后下砸试试！",
        desc_mobile = "在空中点 [砸] 按钮高速下砸！\n砸到地面会震飞周围的敌人，让他们眩晕！\n跳起来，然后下砸试试！",
        check = function() return slamDone_ end,
    },
    -- 步骤5：冲刺
    {
        id = "dash",
        title = "闪电冲刺",
        desc_pc = "按 Shift 或 鼠标右键 瞬间冲刺！\n撞到敌人会把他们击飞！有冷却时间哦。\n来，冲一个！",
        desc_mobile = "点 [冲] 按钮瞬间冲刺！\n撞到敌人会把他们击飞！有冷却时间哦。\n来，冲一个！",
        check = function() return dashDone_ end,
    },
    -- 步骤6：能量 & 爆炸
    {
        id = "energy",
        title = "蓄力爆炸",
        desc_pc = "能量条满了之后，按住鼠标左键蓄力，松开释放爆炸！\n爆炸会炸掉周围的方块，让敌人掉下去！\n你的能量已经满了，试试吧！",
        desc_mobile = "能量条满了之后，按住 [爆] 按钮蓄力，松开释放爆炸！\n爆炸会炸掉周围的方块，让敌人掉下去！\n你的能量已经满了，试试吧！",
        check = function() return explodeDone_ end,
    },
    -- 步骤7：下砸眩晕（提示）
    {
        id = "slam_stun",
        title = "下砸震晕技巧",
        desc_pc = "你知道吗？下砸地面后，周围的敌人会被震晕 1 秒！\n趁他们晕的时候冲刺过去，一击必杀！\n这是你最强的连招，记住了！点击继续。",
        desc_mobile = "你知道吗？下砸地面后，周围的敌人会被震晕 1 秒！\n趁他们晕的时候冲刺过去，一击必杀！\n这是你最强的连招，记住了！点击继续。",
        check = function() return cachedPress_ end,
    },
    -- 步骤8：随机事件 & 道具
    {
        id = "events",
        title = "随机事件 & 道具",
        desc_pc = "游戏中会出现各种随机事件和道具：\n吃到彩色方块可以变大、变小、无限冲刺！\n比赛中还有随机地震、嗜血模式等惊喜！\n点击继续。",
        desc_mobile = "游戏中会出现各种随机事件和道具：\n吃到彩色方块可以变大、变小、无限冲刺！\n比赛中还有随机地震、嗜血模式等惊喜！\n点击继续。",
        check = function() return cachedPress_ end,
    },
    -- 步骤9：得分规则
    {
        id = "scoring",
        title = "得分规则",
        desc_pc = "爬得越高，分越多！击杀敌人可以拿大量奖励分！\n连杀还有额外加成！捡能量块也能得分。\n\n你已经准备好了！去攀登吧！点击开始游戏！",
        desc_mobile = "爬得越高，分越多！击杀敌人可以拿大量奖励分！\n连杀还有额外加成！捡能量块也能得分。\n\n你已经准备好了！去攀登吧！点击开始游戏！",
        check = function() return cachedPress_ end,
    },
}

-- ============================================================================
-- 初始化
-- ============================================================================

---@param playerRef table
---@param gmRef table
---@param mapRef table
function Tutorial.Init(playerRef, gmRef, mapRef)
    playerModule_ = playerRef
    gameManager_ = gmRef
    mapModule_ = mapRef

    -- 平台检测
    local dpr = graphics:GetDPR()
    local logH = graphics:GetHeight() / dpr
    isMobile_ = (logH < 500)

    print("[Tutorial] Initialized, isMobile=" .. tostring(isMobile_))
end

-- ============================================================================
-- 启动 / 结束
-- ============================================================================

--- 启动教程
function Tutorial.Start()
    active_ = true
    currentStep_ = 1
    stepTimer_ = 0
    stepDone_ = false
    showNext_ = false
    fadeAlpha_ = 255
    introTimer_ = 0
    skipConfirm_ = false

    -- 重置所有动作追踪
    moveLeftDone_ = false
    moveRightDone_ = false
    jumpDone_ = false
    slamDone_ = false
    dashDone_ = false
    chargeDone_ = false
    explodeDone_ = false

    -- 确保人类玩家存活（一命通天模式结束后 alive=false，重进教程需要复活）
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.isHuman then
                if not p.alive then
                    playerModule_.Respawn(p)
                end
                -- 给满能量（方便教爆炸）
                p.energy = 1.0
            end
        end
    end

    print("[Tutorial] Started - step 1")
end

--- 结束教程（通关或跳过）
---@param skipped boolean 是否跳过
function Tutorial.Finish(skipped)
    active_ = false
    currentStep_ = 0

    -- 标记教程完成
    Economy.SetTutorialDone()

    if skipped then
        print("[Tutorial] Skipped by player")
    else
        print("[Tutorial] Completed!")
    end
end

--- 教程是否激活
---@return boolean
function Tutorial.IsActive()
    return active_
end

--- 获取当前步骤 ID
---@return string|nil
function Tutorial.GetCurrentStepId()
    local step = STEPS[currentStep_]
    return step and step.id or nil
end

-- ============================================================================
-- 更新逻辑
-- ============================================================================

--- 设置移动端虚拟控制排除区域（由 Standalone 在 InitMobileControls 后调用）
---@param rects table  格式 {{x1,y1,x2,y2}, ...}，逻辑坐标
function Tutorial.SetMobileExcludeRects(rects)
    mobileExcludeRects_ = rects or {}
end

--- 缓存输入（由外部在 Update 阶段调用）
function Tutorial.CacheInput(mousePress, mx, my)
    -- 移动端：如果点击落在虚拟控制区域内，不算作"点击继续"
    if mousePress and isMobile_ and #mobileExcludeRects_ > 0 then
        for _, r in ipairs(mobileExcludeRects_) do
            if mx >= r[1] and mx <= r[3] and my >= r[2] and my <= r[4] then
                mousePress = false
                break
            end
        end
    end
    cachedPress_ = mousePress
    cachedMX_ = mx
    cachedMY_ = my
end

---@param dt number
function Tutorial.Update(dt)
    if not active_ then return end

    stepTimer_ = stepTimer_ + dt
    pulseTimer_ = pulseTimer_ + dt
    arrowBounce_ = math.sin(pulseTimer_ * 3.0) * 4

    -- 开场淡入
    if fadeAlpha_ > 0 then
        fadeAlpha_ = math.max(0, fadeAlpha_ - dt * 400)
    end

    -- 教程期间自动复活（死亡后 1 秒内复活，保持教程流程连贯）
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.isHuman and not p.alive then
                playerModule_.Respawn(p)
                -- 给满能量，以防在能量步骤死亡
                p.energy = 1.0
                print("[Tutorial] Auto-respawned human player during tutorial")
                break
            end
        end
    end

    -- 追踪玩家动作
    Tutorial.TrackPlayerActions(dt)

    -- 检查当前步骤是否完成
    local step = STEPS[currentStep_]
    if step and not stepDone_ then
        -- 跳过确认对话框打开时不检查步骤完成
        if skipConfirm_ then return end

        if step.check() then
            stepDone_ = true
            showNext_ = true
            stepTimer_ = 0
            print("[Tutorial] Step " .. currentStep_ .. " (" .. step.id .. ") completed")
        end
    end

    -- 步骤完成后自动切到下一步
    if stepDone_ and showNext_ then
        -- 操作型步骤延迟 1 秒（显示"操作完成！"反馈），点击型步骤立即前进
        local stepId = step and step.id or ""
        local isClickStep = (stepId == "welcome" or stepId == "slam_stun"
            or stepId == "events" or stepId == "scoring")
        local delay = isClickStep and 0.05 or 1.0
        if stepTimer_ > delay then
            Tutorial.NextStep()
        end
    end
end

--- 追踪玩家的各种动作
---@param dt number
function Tutorial.TrackPlayerActions(dt)
    if not playerModule_ then return end

    for _, p in ipairs(playerModule_.list) do
        if p.isHuman and p.alive then
            -- 移动追踪
            if p.inputMoveX < -0.1 then moveLeftDone_ = true end
            if p.inputMoveX > 0.1 then moveRightDone_ = true end

            -- 跳跃追踪：检测玩家跳跃次数 >= 2（完成了二段跳）
            if p.jumpCount >= 2 then jumpDone_ = true end

            -- 下砸追踪（使用持久状态 slamming，而非单帧 inputSlam）
            if p.slamming then slamDone_ = true end

            -- 冲刺追踪
            if p.dashTimer and p.dashTimer > 0 then dashDone_ = true end

            -- 爆炸追踪：能量从有到无
            if p.explodeRecovery and p.explodeRecovery > 0 then
                explodeDone_ = true
            end

            -- 教程期间特殊处理：步骤6给满能量
            if currentStep_ == 6 and not explodeDone_ and p.energy < 0.5 then
                p.energy = 1.0
            end
        end
    end
end

--- 进入下一步
function Tutorial.NextStep()
    stepDone_ = false
    showNext_ = false
    stepTimer_ = 0

    if currentStep_ >= #STEPS then
        -- 所有步骤完成
        Tutorial.Finish(false)
        return
    end

    currentStep_ = currentStep_ + 1
    local stepId = STEPS[currentStep_].id
    print("[Tutorial] → Step " .. currentStep_ .. " (" .. stepId .. ")")

    -- 步骤6：给满能量
    if currentStep_ == 6 and playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.isHuman and p.alive then
                p.energy = 1.0
            end
        end
    end

    -- 步骤4(slam) 和 步骤7(slam_stun)：将一个 AI 放到玩家附近的上方平台
    if (stepId == "slam" or stepId == "slam_stun") and playerModule_ then
        Tutorial.PlaceAINearPlayer()
    end
end

--- 将一个 AI 敌人传送到人类玩家上方附近（供下砸/砸晕教学）
function Tutorial.PlaceAINearPlayer()
    if not playerModule_ then return end

    -- 找人类玩家位置
    local humanX, humanY = 0, 0
    for _, p in ipairs(playerModule_.list) do
        if p.isHuman and p.alive then
            humanX = p.node.position.x
            humanY = p.node.position.y
            break
        end
    end

    -- 找一个活着的 AI
    local targetAI = nil
    for _, p in ipairs(playerModule_.list) do
        if not p.isHuman and p.alive then
            targetAI = p
            break
        end
    end

    if not targetAI then
        print("[Tutorial] No alive AI found to place")
        return
    end

    -- 将 AI 放到玩家上方约 5 格的位置（第二层平台高度）
    local placeX = humanX + 2.0  -- 稍微偏右
    local placeY = humanY + 5.0  -- 上方 5 格
    targetAI.node.position = Vector3(placeX, placeY, 0)

    -- 清除 AI 的速度，防止残留运动
    local body = targetAI.node:GetComponent("RigidBody")
    if body then
        body:SetLinearVelocity(Vector3.ZERO)
        body:SetAngularVelocity(Vector3.ZERO)
    end

    -- 清除 AI 的眩晕状态
    targetAI.stunTimer = 0

    print("[Tutorial] Placed AI P" .. targetAI.index .. " at (" ..
        string.format("%.1f, %.1f", placeX, placeY) .. ") above player")
end

-- ============================================================================
-- NanoVG 渲染
-- ============================================================================

--- 绘制教程 UI（在 NanoVGRender 事件中调用）
---@param ctx number NanoVG 上下文
---@param w number 逻辑宽度
---@param h number 逻辑高度
---@param scale number UI 缩放
---@param mousePress boolean 本帧是否有鼠标点击
---@param mx number 鼠标逻辑 X
---@param my number 鼠标逻辑 Y
function Tutorial.Draw(ctx, w, h, scale, mousePress, mx, my)
    if not active_ then return end
    vg_ = ctx
    logW_ = w
    logH_ = h
    uiScale_ = scale

    -- 缓存输入给 check 函数用（仅非跳过对话框时）
    if not skipConfirm_ then
        Tutorial.CacheInput(mousePress, mx, my)
    else
        Tutorial.CacheInput(false, mx, my)
    end

    local step = STEPS[currentStep_]
    if not step then return end

    -- 半透明背景遮罩（上下两条，中间留出游戏区域）
    local maskAlpha = 120
    local topH = h * 0.12
    local botH = h * 0.35

    -- 顶部遮罩 + 步骤进度
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, w, topH)
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, maskAlpha))
    nvgFill(ctx)

    -- 底部遮罩 + 教学文本
    local botY = h - botH
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, botY, w, botH)
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, math.floor(maskAlpha * 1.3)))
    nvgFill(ctx)

    -- 步骤进度条（顶部）
    Tutorial.DrawProgress(ctx, w, topH)

    -- 教学内容（底部）
    Tutorial.DrawStepContent(ctx, step, w, h, botY, botH)

    -- 跳过按钮（右上角）
    Tutorial.DrawSkipButton(ctx, w, mousePress, mx, my)

    -- 跳过确认对话框
    if skipConfirm_ then
        Tutorial.DrawSkipConfirmDialog(ctx, w, h, mousePress, mx, my)
    end

    -- 开场淡入遮罩
    if fadeAlpha_ > 0 then
        nvgBeginPath(ctx)
        nvgRect(ctx, 0, 0, w, h)
        nvgFillColor(ctx, nvgRGBA(0, 0, 0, math.floor(fadeAlpha_)))
        nvgFill(ctx)
    end
end

--- 绘制步骤进度条
function Tutorial.DrawProgress(ctx, w, topH)
    local totalSteps = #STEPS
    local barW = math.min(w * 0.6, 300)
    local barH = 4 * uiScale_
    local barX = (w - barW) * 0.5
    local barY = topH * 0.5 - barH * 0.5

    -- 背景
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX, barY, barW, barH, barH * 0.5)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 40))
    nvgFill(ctx)

    -- 进度
    local progress = currentStep_ / totalSteps
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX, barY, barW * progress, barH, barH * 0.5)
    nvgFillColor(ctx, nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], 220))
    nvgFill(ctx)

    -- 步骤文字
    nvgFontFace(ctx, "sans")
    nvgFontSize(ctx, math.max(10, math.floor(12 * uiScale_)))
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 180))
    nvgText(ctx, w * 0.5, barY - 10 * uiScale_, currentStep_ .. " / " .. totalSteps)
end

--- 绘制步骤教学内容
function Tutorial.DrawStepContent(ctx, step, w, h, botY, botH)
    local cx = w * 0.5
    local contentY = botY + 12 * uiScale_

    -- 标题（金色，大字）
    nvgFontFace(ctx, "bold")
    local titleSize = math.max(16, math.floor(22 * uiScale_))
    nvgFontSize(ctx, titleSize)
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)

    -- 标题阴影
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, 160))
    nvgText(ctx, cx + 1, contentY + 1, step.title)

    -- 标题
    nvgFillColor(ctx, nvgRGBA(Theme.primary[1], Theme.primary[2], Theme.primary[3], 255))
    nvgText(ctx, cx, contentY, step.title)

    -- 说明文字（白色，分行绘制）
    local descY = contentY + titleSize + 10 * uiScale_
    local desc = isMobile_ and step.desc_mobile or step.desc_pc
    local lineH = math.max(14, math.floor(16 * uiScale_))

    nvgFontFace(ctx, "sans")
    nvgFontSize(ctx, math.max(11, math.floor(14 * uiScale_)))
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 230))

    -- 手动分行
    for line in desc:gmatch("[^\n]+") do
        nvgText(ctx, cx, descY, line)
        descY = descY + lineH
    end

    -- 动作完成/未完成时的底部提示
    local isActionStep = step.id ~= "welcome" and step.id ~= "slam_stun" and step.id ~= "events" and step.id ~= "scoring"
    if isActionStep then
        if stepDone_ then
            -- 完成反馈：绿色脉冲文字
            local doneAlpha = math.floor(math.abs(math.sin(pulseTimer_ * 3.0)) * 55 + 200)
            nvgFontFace(ctx, "bold")
            nvgFontSize(ctx, math.max(13, math.floor(16 * uiScale_)))
            nvgFillColor(ctx, nvgRGBA(80, 255, 120, doneAlpha))
            nvgText(ctx, cx, descY + 6 * uiScale_, "操作完成！")
        else
            -- 等待提示：脉冲动画
            local dotAlpha = math.floor(math.abs(math.sin(pulseTimer_ * 2.0)) * 180 + 50)
            nvgFontSize(ctx, math.max(10, math.floor(12 * uiScale_)))
            nvgFillColor(ctx, nvgRGBA(Theme.accent[1], Theme.accent[2], Theme.accent[3], dotAlpha))
            nvgText(ctx, cx, descY + 6 * uiScale_, "等待你完成操作...")
        end
    end
end

--- 绘制跳过按钮（右上角）
function Tutorial.DrawSkipButton(ctx, w, mousePress, mx, my)
    -- 移动端：更大的按钮 + 避开 TapTap 胶囊菜单（右约100px，顶约58px）
    local btnW, btnH, btnX, btnY
    if isMobile_ then
        btnW = math.floor(80 * uiScale_)
        btnH = math.floor(40 * uiScale_)
        btnX = w - btnW - math.floor(100 * uiScale_)
        -- 胶囊高度约 58px，再偏移一个胶囊距离（58px）+ 间距（8px）到其下方
        btnY = math.floor(58 * uiScale_) + math.floor(58 * uiScale_) + math.floor(8 * uiScale_)
    else
        btnW = math.floor(60 * uiScale_)
        btnH = math.floor(26 * uiScale_)
        btnX = w - btnW - 10
        btnY = 6
    end

    local hovered = mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH

    -- 按钮背景
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, btnX, btnY, btnW, btnH, Theme.radiusSm)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, hovered and 50 or 25))
    nvgFill(ctx)

    -- 边框
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, btnX, btnY, btnW, btnH, Theme.radiusSm)
    nvgStrokeColor(ctx, nvgRGBA(255, 255, 255, hovered and 80 or 40))
    nvgStrokeWidth(ctx, 1)
    nvgStroke(ctx)

    -- 文字
    nvgFontFace(ctx, "sans")
    nvgFontSize(ctx, math.max(10, math.floor(12 * uiScale_)))
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, hovered and 220 or 150))
    nvgText(ctx, btnX + btnW * 0.5, btnY + btnH * 0.5, "跳过")

    -- 点击
    if mousePress and hovered and not skipConfirm_ then
        skipConfirm_ = true
    end
end

--- 绘制跳过确认对话框
function Tutorial.DrawSkipConfirmDialog(ctx, w, h, mousePress, mx, my)
    -- 全屏遮罩
    nvgBeginPath(ctx)
    nvgRect(ctx, 0, 0, w, h)
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, 160))
    nvgFill(ctx)

    -- 对话框
    local dlgW = math.min(w * 0.6, 280)
    local dlgH = math.floor(130 * uiScale_)
    local dlgX = (w - dlgW) * 0.5
    local dlgY = (h - dlgH) * 0.5

    -- 背景
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, dlgX, dlgY, dlgW, dlgH, Theme.radiusLg)
    nvgFillColor(ctx, nvgRGBA(Theme.surface[1], Theme.surface[2], Theme.surface[3], 240))
    nvgFill(ctx)

    -- 边框
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, dlgX, dlgY, dlgW, dlgH, Theme.radiusLg)
    nvgStrokeColor(ctx, nvgRGBA(255, 255, 255, 30))
    nvgStrokeWidth(ctx, 1)
    nvgStroke(ctx)

    -- 标题
    nvgFontFace(ctx, "bold")
    nvgFontSize(ctx, math.max(14, math.floor(18 * uiScale_)))
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 240))
    nvgText(ctx, w * 0.5, dlgY + 30 * uiScale_, "确定跳过教程吗？")

    -- 提示
    nvgFontFace(ctx, "sans")
    nvgFontSize(ctx, math.max(10, math.floor(12 * uiScale_)))
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 150))
    nvgText(ctx, w * 0.5, dlgY + 52 * uiScale_, "你可以稍后在主菜单重新进入教程")

    -- 按钮
    local btnW2 = math.floor(90 * uiScale_)
    local btnH2 = math.floor(32 * uiScale_)
    local btnGap = 16 * uiScale_
    local btnY2 = dlgY + dlgH - 20 * uiScale_ - btnH2

    -- "继续教程"按钮
    local cancelX = w * 0.5 - btnW2 - btnGap * 0.5
    local cancelHov = mx >= cancelX and mx <= cancelX + btnW2 and my >= btnY2 and my <= btnY2 + btnH2

    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, cancelX, btnY2, btnW2, btnH2, Theme.radiusMd)
    nvgFillColor(ctx, nvgRGBA(Theme.secondary[1], Theme.secondary[2], Theme.secondary[3], cancelHov and 230 or 180))
    nvgFill(ctx)
    nvgFontFace(ctx, "bold")
    nvgFontSize(ctx, math.max(11, math.floor(13 * uiScale_)))
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 255))
    nvgText(ctx, cancelX + btnW2 * 0.5, btnY2 + btnH2 * 0.5, "继续教程")

    if mousePress and cancelHov then
        skipConfirm_ = false
    end

    -- "确认跳过"按钮
    local confirmX = w * 0.5 + btnGap * 0.5
    local confirmHov = mx >= confirmX and mx <= confirmX + btnW2 and my >= btnY2 and my <= btnY2 + btnH2

    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, confirmX, btnY2, btnW2, btnH2, Theme.radiusMd)
    nvgFillColor(ctx, nvgRGBA(Theme.error[1], Theme.error[2], Theme.error[3], confirmHov and 230 or 180))
    nvgFill(ctx)
    nvgFontFace(ctx, "bold")
    nvgFontSize(ctx, math.max(11, math.floor(13 * uiScale_)))
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 255))
    nvgText(ctx, confirmX + btnW2 * 0.5, btnY2 + btnH2 * 0.5, "确认跳过")

    if mousePress and confirmHov then
        skipConfirm_ = false
        Tutorial.Finish(true)
    end
end

return Tutorial

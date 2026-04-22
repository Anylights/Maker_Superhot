-- ============================================================================
-- LevelEditor.lua - 关卡编辑器
-- 功能：摆放地形方块、出生点、终点；保存/加载自定义关卡；试玩
-- 使用 NanoVG 绘制编辑器 UI，通过 Camera 手动模式控制视角
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local Camera = require("Camera")
local Map = require("Map")
local LevelManager = require("LevelManager")
---@diagnostic disable-next-line: undefined-global
local cjson = cjson  -- 引擎内置全局变量

local LevelEditor = {}

-- ============================================================================
-- 状态
-- ============================================================================
LevelEditor.active = false

-- 编辑器网格 (grid[y][x] = blockType)
local grid_ = {}

-- 当前选中的方块类型
local selectedType_ = Config.BLOCK_NORMAL

-- 相机控制
local camX_ = 25.0
local camY_ = 25.0
local camZoom_ = 30.0
local CAM_ZOOM_MIN = 8.0
local CAM_ZOOM_MAX = 55.0
local CAM_PAN_SPEED = 20.0

-- 鼠标状态
local isDragging_ = false
local lastPlacedGX_ = -1
local lastPlacedGY_ = -1
local isErasing_ = false  -- 右键擦除模式
local isPanning_ = false  -- 中键平移模式

-- 每帧缓存的鼠标按下状态（Update 中采集，Draw 中使用）
local cachedMousePress_ = false
local cachedMouseLogX_ = 0
local cachedMouseLogY_ = 0

-- NanoVG 上下文和分辨率（由 HUD 共享传入）
local vg_ = nil
local logW_, logH_ = 0, 0

-- ============================================================================
-- 本地坐标转换（不依赖 camera.aspectRatio / camera.orthoSize 属性）
-- 直接使用 camZoom_ 和 logW_/logH_ 确保编辑器内完全一致
-- ============================================================================

--- 屏幕逻辑像素 → 世界坐标
local function S2W(sx, sy)
    if Camera.node == nil or logW_ == 0 or logH_ == 0 then return 0, 0 end
    local pos = Camera.node.position
    local halfH = camZoom_ * 0.5
    local halfW = halfH * (logW_ / logH_)
    local wx = (sx / logW_) * (2 * halfW) - halfW + pos.x
    local wy = (1.0 - sy / logH_) * (2 * halfH) - halfH + pos.y
    return wx, wy
end

--- 世界坐标 → 屏幕逻辑像素
local function W2S(wx, wy)
    if Camera.node == nil or logW_ == 0 or logH_ == 0 then return 0, 0 end
    local pos = Camera.node.position
    local halfH = camZoom_ * 0.5
    local halfW = halfH * (logW_ / logH_)
    local sx = (wx - pos.x + halfW) / (2 * halfW) * logW_
    local sy = (1.0 - (wy - pos.y + halfH) / (2 * halfH)) * logH_
    return sx, sy
end

-- 工具栏定义（BLOCK_EMPTY = 橡皮擦）
local TOOLS = {
    { type = Config.BLOCK_NORMAL,    label = "普通",   color = Config.BlockColors[1] },
    { type = Config.BLOCK_SAFE,      label = "安全",   color = Config.BlockColors[2] },
    { type = Config.BLOCK_SPAWN_P1,  label = "P1出生", color = Config.BlockColors[10], unique = true },
    { type = Config.BLOCK_SPAWN_P2,  label = "P2出生", color = Config.BlockColors[11], unique = true },
    { type = Config.BLOCK_SPAWN_P3,  label = "P3出生", color = Config.BlockColors[12], unique = true },
    { type = Config.BLOCK_SPAWN_P4,  label = "P4出生", color = Config.BlockColors[13], unique = true },
    { type = Config.BLOCK_FINISH,    label = "终点",   color = Config.BlockColors[5] },
    { type = Config.BLOCK_EMPTY,     label = "橡皮擦", color = nil, isEraser = true },
}

-- 工具栏布局
local TOOLBAR_W = 78
local TOOLBAR_BTN_H = 34
local TOOLBAR_BTN_GAP = 4
local TOOLBAR_PAD = 8

-- 底部按钮
local BOTTOM_BTN_W = 80
local BOTTOM_BTN_H = 32
local BOTTOM_BTN_GAP = 12

-- 当前编辑的关卡文件
local currentFile_ = nil   -- 当前文件名（如 "level_001.json"），nil 表示新关卡
local currentName_ = nil   -- 当前关卡名称

-- 模块引用（由 main 注入）
local gameManagerRef_ = nil
local mapRef_ = nil

-- 提示消息
local toastMessage_ = nil
local toastTimer_ = 0

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化编辑器
---@param nvgCtx number NanoVG 上下文
---@param gmRef table GameManager 引用
---@param mapRefIn table Map 引用
function LevelEditor.Init(nvgCtx, gmRef, mapRefIn)
    vg_ = nvgCtx
    gameManagerRef_ = gmRef
    mapRef_ = mapRefIn
    LevelEditor.InitGrid()
    print("[LevelEditor] Initialized")
end

--- 初始化空网格
function LevelEditor.InitGrid()
    grid_ = {}
    for y = 1, MapData.Height do
        grid_[y] = {}
        for x = 1, MapData.Width do
            grid_[y][x] = Config.BLOCK_EMPTY
        end
    end

    -- 默认放一个起点平台（4 个出生点对称分布）
    for x = 3, 10 do
        grid_[3][x] = Config.BLOCK_SAFE
    end
    grid_[3][5] = Config.BLOCK_SPAWN_P1
    grid_[3][6] = Config.BLOCK_SPAWN_P2
    grid_[3][7] = Config.BLOCK_SPAWN_P3
    grid_[3][8] = Config.BLOCK_SPAWN_P4
end

-- ============================================================================
-- 进入/退出编辑器
-- ============================================================================

--- 进入编辑器模式
function LevelEditor.Enter()
    LevelEditor.active = true

    -- 立即初始化分辨率，避免第一帧 Update 中 ScreenToWorld 使用 logW_=0
    local dpr = graphics:GetDPR()
    logW_ = graphics:GetWidth() / dpr
    logH_ = graphics:GetHeight() / dpr

    -- 如果没有当前关卡（新建模式），使用默认空网格
    -- 如果有 currentFile_，说明是从关卡列表点"修改"进来的，grid_ 已被 LoadFile 设置好

    -- 切换相机到手动模式
    Camera.manualMode = true
    Camera.SetOrthoSize(camZoom_)
    Camera.SetCenter(camX_, camY_)

    -- 用编辑器网格构建地图预览
    LevelEditor.RebuildMapPreview()

    LevelEditor.ShowToast("编辑器已打开")
    print("[LevelEditor] Entered editor mode")
end

--- 退出编辑器模式
function LevelEditor.Exit()
    LevelEditor.active = false

    -- 恢复相机自动跟随
    Camera.manualMode = false

    print("[LevelEditor] Exited editor mode")
end

-- ============================================================================
-- 更新（每帧调用）
-- ============================================================================

--- 设置分辨率信息
---@param lw number 逻辑宽度
---@param lh number 逻辑高度
function LevelEditor.SetResolution(lw, lh)
    logW_ = lw
    logH_ = lh
end

--- 每帧更新（处理输入）
---@param dt number
function LevelEditor.Update(dt)
    if not LevelEditor.active then return end

    -- Toast 计时
    if toastTimer_ > 0 then
        toastTimer_ = toastTimer_ - dt
        if toastTimer_ <= 0 then
            toastMessage_ = nil
        end
    end

    -- 缓存鼠标单击状态（GetMouseButtonPress 是一次性的，必须在 Update 中采集）
    cachedMousePress_ = input:GetMouseButtonPress(MOUSEB_LEFT)
    if cachedMousePress_ then
        local dpr = graphics:GetDPR()
        cachedMouseLogX_ = input:GetMousePosition().x / dpr
        cachedMouseLogY_ = input:GetMousePosition().y / dpr
    end

    LevelEditor.HandleCameraInput(dt)
    LevelEditor.HandleEditing()
    LevelEditor.HandleButtons()
end

--- 处理相机平移和缩放
---@param dt number
function LevelEditor.HandleCameraInput(dt)
    -- WASD / 方向键 平移
    local dx, dy = 0, 0
    if input:GetKeyDown(KEY_W) or input:GetKeyDown(KEY_UP) then dy = 1 end
    if input:GetKeyDown(KEY_S) or input:GetKeyDown(KEY_DOWN) then dy = -1 end
    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then dx = -1 end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then dx = 1 end

    local speed = CAM_PAN_SPEED * (camZoom_ / 30.0) * dt
    camX_ = camX_ + dx * speed
    camY_ = camY_ + dy * speed

    -- 鼠标中键平移
    if input:GetMouseButtonDown(MOUSEB_MIDDLE) then
        isPanning_ = true
        local dpr = graphics:GetDPR()
        local mdx = input:GetMouseMoveX() / dpr  -- 物理像素 → 逻辑像素
        local mdy = input:GetMouseMoveY() / dpr
        -- 逻辑像素 → 世界单位：camZoom_ 是视野高度（米），logH_ 是逻辑像素高度
        local worldPerPx = camZoom_ / logH_
        camX_ = camX_ - mdx * worldPerPx  -- 拖右 → 相机左移
        camY_ = camY_ + mdy * worldPerPx  -- 拖下 → 相机上移（屏幕 Y 与世界 Y 相反）
    else
        isPanning_ = false
    end

    -- 限制范围
    camX_ = math.max(-5, math.min(MapData.Width + 5, camX_))
    camY_ = math.max(-5, math.min(MapData.Height + 5, camY_))

    -- 滚轮缩放
    local wheel = input:GetMouseMoveWheel()
    if wheel ~= 0 then
        camZoom_ = camZoom_ - wheel * 3.0
        camZoom_ = math.max(CAM_ZOOM_MIN, math.min(CAM_ZOOM_MAX, camZoom_))
    end

    Camera.SetCenter(camX_, camY_)
    Camera.SetOrthoSize(camZoom_)
end

--- 处理方块编辑（鼠标点击/拖拽放置）
function LevelEditor.HandleEditing()
    -- 中键平移时不处理编辑
    if isPanning_ then
        isDragging_ = false
        return
    end

    local mx = input:GetMousePosition().x
    local my = input:GetMousePosition().y

    -- 获取 DPR 转换鼠标到逻辑坐标
    local dpr = graphics:GetDPR()
    local logMX = mx / dpr
    local logMY = my / dpr

    -- 检查鼠标是否在工具栏区域（不处理编辑）
    if logMX < TOOLBAR_W + TOOLBAR_PAD * 2 then
        isDragging_ = false
        return
    end

    -- 检查鼠标是否在底部按钮区域
    if logMY > logH_ - 60 then
        isDragging_ = false
        return
    end

    -- 鼠标逻辑坐标转世界坐标
    local wx, wy = S2W(logMX, logMY)

    -- 世界坐标转网格坐标
    local gx = math.floor(wx / Config.BlockSize) + 1
    local gy = math.floor(wy / Config.BlockSize) + 1

    -- 左键：放置
    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    -- 右键：擦除
    local rightDown = input:GetMouseButtonDown(MOUSEB_RIGHT)

    -- 橡皮擦工具：左键也执行擦除
    local erasing = rightDown or (leftDown and selectedType_ == Config.BLOCK_EMPTY)

    if leftDown or rightDown then
        if gx >= 1 and gx <= MapData.Width and gy >= 1 and gy <= MapData.Height then
            -- 防止同一格重复操作（拖拽优化）
            if gx ~= lastPlacedGX_ or gy ~= lastPlacedGY_ then
                lastPlacedGX_ = gx
                lastPlacedGY_ = gy

                if erasing then
                    -- 擦除
                    if grid_[gy][gx] ~= Config.BLOCK_EMPTY then
                        grid_[gy][gx] = Config.BLOCK_EMPTY
                        if mapRef_ then mapRef_.RemoveBlock(gx, gy) end
                    end
                else
                    -- 出生点唯一性：同类型出生点只能存在一个
                    local tool = nil
                    for _, t in ipairs(TOOLS) do
                        if t.type == selectedType_ then tool = t; break end
                    end
                    if tool and tool.unique then
                        -- 移除同类型的旧出生点
                        for sy = 1, MapData.Height do
                            for sx = 1, MapData.Width do
                                if grid_[sy][sx] == selectedType_ then
                                    grid_[sy][sx] = Config.BLOCK_EMPTY
                                    if mapRef_ then mapRef_.RemoveBlock(sx, sy) end
                                end
                            end
                        end
                    end
                    -- 放置
                    grid_[gy][gx] = selectedType_
                    if mapRef_ then mapRef_.SetBlock(gx, gy, selectedType_) end
                end
            end
        end
        isDragging_ = true
    else
        isDragging_ = false
        lastPlacedGX_ = -1
        lastPlacedGY_ = -1
    end
end

--- 处理底部按钮点击
function LevelEditor.HandleButtons()
    -- ESC 退出
    if input:GetKeyPress(KEY_ESCAPE) then
        LevelEditor.OnExitClick()
        return
    end
end

-- ============================================================================
-- NanoVG 绘制
-- ============================================================================

--- 绘制编辑器 UI 覆盖层
function LevelEditor.Draw()
    if not LevelEditor.active then return end
    if vg_ == nil then return end

    LevelEditor.DrawToolbar()
    LevelEditor.DrawBottomBar()
    LevelEditor.DrawGridOverlay()
    LevelEditor.DrawToast()
end

--- 绘制左侧工具栏
function LevelEditor.DrawToolbar()
    local x = TOOLBAR_PAD
    local y = TOOLBAR_PAD
    local w = TOOLBAR_W

    -- 工具栏背景
    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, x, y, w, #TOOLS * (TOOLBAR_BTN_H + TOOLBAR_BTN_GAP) + TOOLBAR_PAD * 2 + 20, 8)
    nvgFillColor(vg_, nvgRGBA(30, 20, 15, 210))
    nvgFill(vg_)

    -- 标题
    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 13)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 200, 80, 240))
    nvgText(vg_, x + w * 0.5, y + 6, "工具")

    -- 方块类型按钮
    local btnY = y + 24
    for i, tool in ipairs(TOOLS) do
        local bx = x + 4
        local by = btnY + (i - 1) * (TOOLBAR_BTN_H + TOOLBAR_BTN_GAP)
        local bw = w - 8
        local bh = TOOLBAR_BTN_H

        -- 选中高亮
        local isSelected = (selectedType_ == tool.type)

        -- 背景
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, bw, bh, 5)
        if isSelected then
            nvgFillColor(vg_, nvgRGBA(255, 200, 80, 60))
        else
            nvgFillColor(vg_, nvgRGBA(60, 45, 35, 150))
        end
        nvgFill(vg_)

        -- 选中边框
        if isSelected then
            nvgStrokeColor(vg_, nvgRGBA(255, 200, 80, 200))
            nvgStrokeWidth(vg_, 2)
            nvgStroke(vg_)
        end

        -- 颜色示例块
        if tool.isEraser then
            -- 橡皮擦：绘制白色方块 + 红色斜线
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, bx + 6, by + 8, 14, 14, 3)
            nvgFillColor(vg_, nvgRGBA(80, 70, 60, 200))
            nvgFill(vg_)
            nvgStrokeColor(vg_, nvgRGBA(255, 80, 80, 220))
            nvgStrokeWidth(vg_, 2)
            nvgStroke(vg_)
            -- 斜线
            nvgBeginPath(vg_)
            nvgMoveTo(vg_, bx + 7, by + 9)
            nvgLineTo(vg_, bx + 19, by + 21)
            nvgStrokeColor(vg_, nvgRGBA(255, 80, 80, 220))
            nvgStrokeWidth(vg_, 2)
            nvgStroke(vg_)
        else
            local cr = math.floor(tool.color.r * 255)
            local cg = math.floor(tool.color.g * 255)
            local cb = math.floor(tool.color.b * 255)
            nvgBeginPath(vg_)
            nvgRoundedRect(vg_, bx + 6, by + 8, 14, 14, 3)
            nvgFillColor(vg_, nvgRGBA(cr, cg, cb, 255))
            nvgFill(vg_)
        end

        -- 标签
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 12)
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(220, 210, 200, 240))
        nvgText(vg_, bx + 24, by + bh * 0.5, tool.label)

        -- 快捷键提示
        nvgFontSize(vg_, 10)
        nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(160, 140, 120, 160))
        nvgText(vg_, bx + bw - 4, by + bh * 0.5, tostring(i))

        -- 点击检测（使用 Update 中缓存的鼠标按下状态）
        if cachedMousePress_ then
            if cachedMouseLogX_ >= bx and cachedMouseLogX_ <= bx + bw and
               cachedMouseLogY_ >= by and cachedMouseLogY_ <= by + bh then
                selectedType_ = tool.type
            end
        end
    end

    -- 快捷键切换（数字键 1-8）
    if input:GetKeyPress(KEY_1) then selectedType_ = TOOLS[1].type end
    if input:GetKeyPress(KEY_2) then selectedType_ = TOOLS[2].type end
    if input:GetKeyPress(KEY_3) then selectedType_ = TOOLS[3].type end
    if input:GetKeyPress(KEY_4) then selectedType_ = TOOLS[4].type end
    if input:GetKeyPress(KEY_5) then selectedType_ = TOOLS[5].type end
    if input:GetKeyPress(KEY_6) then selectedType_ = TOOLS[6].type end
    if input:GetKeyPress(KEY_7) then selectedType_ = TOOLS[7].type end
    if input:GetKeyPress(KEY_8) then selectedType_ = TOOLS[8].type end
end

--- 绘制底部按钮栏
function LevelEditor.DrawBottomBar()
    local barH = 50
    local barY = logH_ - barH

    -- 背景
    nvgBeginPath(vg_)
    nvgRect(vg_, 0, barY, logW_, barH)
    nvgFillColor(vg_, nvgRGBA(30, 20, 15, 210))
    nvgFill(vg_)

    -- 按钮列表
    local buttons = {
        { label = "保存",   key = "save",  hotkey = "Ctrl+S" },
        { label = "新建",   key = "new",   hotkey = "Ctrl+N" },
        { label = "清空",   key = "clear", hotkey = "" },
        { label = "试玩",   key = "test",  hotkey = "T" },
        { label = "退出",   key = "exit",  hotkey = "ESC" },
    }

    local totalW = #buttons * BOTTOM_BTN_W + (#buttons - 1) * BOTTOM_BTN_GAP
    local startX = (logW_ - totalW) * 0.5

    for i, btn in ipairs(buttons) do
        local bx = startX + (i - 1) * (BOTTOM_BTN_W + BOTTOM_BTN_GAP)
        local by = barY + (barH - BOTTOM_BTN_H) * 0.5
        local bw = BOTTOM_BTN_W
        local bh = BOTTOM_BTN_H

        -- 背景
        nvgBeginPath(vg_)
        nvgRoundedRect(vg_, bx, by, bw, bh, 5)
        nvgFillColor(vg_, nvgRGBA(60, 45, 35, 180))
        nvgFill(vg_)

        nvgStrokeColor(vg_, nvgRGBA(180, 150, 110, 80))
        nvgStrokeWidth(vg_, 1)
        nvgStroke(vg_)

        -- 标签
        nvgFontFace(vg_, "sans")
        nvgFontSize(vg_, 14)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(240, 230, 220, 240))
        nvgText(vg_, bx + bw * 0.5, by + bh * 0.5, btn.label)

        -- 点击检测（使用 Update 中缓存的鼠标按下状态）
        if cachedMousePress_ then
            if cachedMouseLogX_ >= bx and cachedMouseLogX_ <= bx + bw and
               cachedMouseLogY_ >= by and cachedMouseLogY_ <= by + bh then
                LevelEditor.OnButtonClick(btn.key)
            end
        end
    end

    -- 快捷键
    if input:GetKeyPress(KEY_T) then LevelEditor.OnButtonClick("test") end
    -- Ctrl+S 保存
    if input:GetKeyDown(KEY_CTRL) and input:GetKeyPress(KEY_S) then
        LevelEditor.OnButtonClick("save")
    end
    -- Ctrl+N 新建
    if input:GetKeyDown(KEY_CTRL) and input:GetKeyPress(KEY_N) then
        LevelEditor.OnButtonClick("new")
    end
end

--- 绘制网格参考线
function LevelEditor.DrawGridOverlay()
    -- 计算可见范围（用 logW_/logH_ 而非 camera.aspectRatio，确保与转换函数完全一致）
    local halfH = camZoom_ * 0.5
    local halfW = halfH * (logW_ / logH_)

    local viewMinX = camX_ - halfW
    local viewMaxX = camX_ + halfW
    local viewMinY = camY_ - halfH
    local viewMaxY = camY_ + halfH

    -- 网格线（仅在缩放足够时显示）
    if camZoom_ < 40 then
        local gridStartX = math.max(1, math.floor(viewMinX / Config.BlockSize) + 1)
        local gridEndX = math.min(MapData.Width, math.ceil(viewMaxX / Config.BlockSize) + 1)
        local gridStartY = math.max(1, math.floor(viewMinY / Config.BlockSize) + 1)
        local gridEndY = math.min(MapData.Height, math.ceil(viewMaxY / Config.BlockSize) + 1)

        nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 15))
        nvgStrokeWidth(vg_, 0.5)

        -- 垂直线
        for x = gridStartX, gridEndX do
            local wx = (x - 1) * Config.BlockSize
            local sx1, sy1 = W2S(wx, viewMinY)
            local sx2, sy2 = W2S(wx, viewMaxY)
            nvgBeginPath(vg_)
            nvgMoveTo(vg_, sx1, sy1)
            nvgLineTo(vg_, sx2, sy2)
            nvgStroke(vg_)
        end

        -- 水平线
        for y = gridStartY, gridEndY do
            local wy = (y - 1) * Config.BlockSize
            local sx1, sy1 = W2S(viewMinX, wy)
            local sx2, sy2 = W2S(viewMaxX, wy)
            nvgBeginPath(vg_)
            nvgMoveTo(vg_, sx1, sy1)
            nvgLineTo(vg_, sx2, sy2)
            nvgStroke(vg_)
        end
    end

    -- 鼠标悬停高亮格
    local dpr = graphics:GetDPR()
    local logMX = input:GetMousePosition().x / dpr
    local logMY = input:GetMousePosition().y / dpr

    -- 不在 UI 区域时才显示悬停
    if logMX > TOOLBAR_W + TOOLBAR_PAD * 2 and logMY < logH_ - 60 then
        local wx, wy = S2W(logMX, logMY)
        local gx = math.floor(wx / Config.BlockSize) + 1
        local gy = math.floor(wy / Config.BlockSize) + 1

        if gx >= 1 and gx <= MapData.Width and gy >= 1 and gy <= MapData.Height then
            -- 计算格子屏幕位置
            local cellWX = (gx - 1) * Config.BlockSize
            local cellWY = (gy - 1) * Config.BlockSize
            local sx1, sy1 = W2S(cellWX, cellWY + Config.BlockSize)
            local sx2, sy2 = W2S(cellWX + Config.BlockSize, cellWY)

            nvgBeginPath(vg_)
            nvgRect(vg_, sx1, sy1, sx2 - sx1, sy2 - sy1)
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 30))
            nvgFill(vg_)
            nvgStrokeColor(vg_, nvgRGBA(255, 255, 80, 120))
            nvgStrokeWidth(vg_, 1.5)
            nvgStroke(vg_)

            -- 坐标信息
            nvgFontFace(vg_, "sans")
            nvgFontSize(vg_, 11)
            nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
            nvgFillColor(vg_, nvgRGBA(255, 255, 200, 180))
            nvgText(vg_, sx1 + 2, sy1 - 2, gx .. "," .. gy)
        end
    end

    -- 地图边界框
    local bx1, by1 = W2S(0, MapData.Height * Config.BlockSize)
    local bx2, by2 = W2S(MapData.Width * Config.BlockSize, 0)
    nvgBeginPath(vg_)
    nvgRect(vg_, bx1, by1, bx2 - bx1, by2 - by1)
    nvgStrokeColor(vg_, nvgRGBA(255, 200, 80, 80))
    nvgStrokeWidth(vg_, 1.5)
    nvgStroke(vg_)
end

--- 绘制提示消息
function LevelEditor.DrawToast()
    if toastMessage_ == nil then return end

    local alpha = math.min(1.0, toastTimer_ * 2) * 255

    nvgFontFace(vg_, "bold")
    nvgFontSize(vg_, 18)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 背景
    local tw = 200
    local th = 36
    local tx = logW_ * 0.5 - tw * 0.5
    local ty = logH_ * 0.5 - 80

    nvgBeginPath(vg_)
    nvgRoundedRect(vg_, tx, ty, tw, th, 8)
    nvgFillColor(vg_, nvgRGBA(30, 20, 15, math.floor(alpha * 0.8)))
    nvgFill(vg_)

    nvgFillColor(vg_, nvgRGBA(255, 240, 200, math.floor(alpha)))
    nvgText(vg_, logW_ * 0.5, ty + th * 0.5, toastMessage_)
end

--- 显示提示消息
---@param msg string
function LevelEditor.ShowToast(msg)
    toastMessage_ = msg
    toastTimer_ = 2.0
end

-- ============================================================================
-- 按钮回调
-- ============================================================================

function LevelEditor.OnButtonClick(key)
    if key == "save" then
        LevelEditor.Save()
    elseif key == "new" then
        LevelEditor.NewLevel()
    elseif key == "clear" then
        LevelEditor.InitGrid()
        LevelEditor.RebuildMapPreview()
        LevelEditor.ShowToast("已清空")
    elseif key == "test" then
        LevelEditor.TestPlay()
    elseif key == "exit" then
        LevelEditor.OnExitClick()
    end
end

function LevelEditor.OnExitClick()
    LevelEditor.Exit()
    if gameManagerRef_ then
        -- 如果有关卡列表功能，返回关卡列表
        gameManagerRef_.EnterLevelList()
    end
end

-- ============================================================================
-- 试玩
-- ============================================================================

--- 使用当前编辑器网格开始试玩
function LevelEditor.TestPlay()
    -- 验证：必须有至少一个出生点和终点
    local hasSpawn = false
    local hasFinish = false
    for y = 1, MapData.Height do
        for x = 1, MapData.Width do
            if Config.IsSpawnBlock(grid_[y][x]) then hasSpawn = true end
            if grid_[y][x] == Config.BLOCK_FINISH then hasFinish = true end
        end
    end

    if not hasSpawn then
        LevelEditor.ShowToast("需要至少一个出生点！")
        return
    end
    if not hasFinish then
        LevelEditor.ShowToast("需要至少一个终点！")
        return
    end

    -- 自动保存
    LevelEditor.Save()

    -- 将编辑器网格设置为自定义地图
    MapData.SetCustomGrid(grid_)

    -- 退出编辑器
    LevelEditor.Exit()

    -- 开始试玩（使用 StartTestPlay，结束后回到关卡列表）
    if gameManagerRef_ then
        Camera.manualMode = false
        gameManagerRef_.StartTestPlay(currentFile_)
    end

    print("[LevelEditor] Test play started")
end

-- ============================================================================
-- 保存/加载
-- ============================================================================

--- 保存关卡到文件（使用 LevelManager）
function LevelEditor.Save()
    -- 新关卡：自动生成文件名
    if currentFile_ == nil then
        local fn, nm = LevelManager.NextFilename()
        currentFile_ = fn
        currentName_ = nm
    end

    local ok = LevelManager.Save(currentFile_, currentName_ or "未命名", grid_)
    if ok then
        LevelEditor.ShowToast("已保存！")
    else
        LevelEditor.ShowToast("保存失败")
    end
end

--- 加载指定关卡文件到编辑器
---@param filename string 文件名（不含目录）
---@return boolean
function LevelEditor.LoadFile(filename)
    local loadedGrid, name = LevelManager.Load(filename)
    if not loadedGrid then
        LevelEditor.ShowToast("加载失败")
        return false
    end

    -- 深拷贝 grid 到编辑器内部
    grid_ = {}
    for y = 1, MapData.Height do
        grid_[y] = {}
        for x = 1, MapData.Width do
            grid_[y][x] = loadedGrid[y] and loadedGrid[y][x] or Config.BLOCK_EMPTY
        end
    end

    currentFile_ = filename
    currentName_ = name

    LevelEditor.RebuildMapPreview()
    LevelEditor.ShowToast("已加载: " .. (name or filename))
    return true
end

--- 新建空关卡
function LevelEditor.NewLevel()
    currentFile_ = nil
    currentName_ = nil
    LevelEditor.InitGrid()
    LevelEditor.RebuildMapPreview()
    LevelEditor.ShowToast("新关卡")
end

--- 获取当前编辑的文件名
---@return string|nil
function LevelEditor.GetCurrentFile()
    return currentFile_
end

--- 获取当前关卡名称
---@return string|nil
function LevelEditor.GetCurrentName()
    return currentName_
end

-- ============================================================================
-- 地图预览重建
-- ============================================================================

--- 用编辑器网格重建 3D 地图预览
function LevelEditor.RebuildMapPreview()
    if mapRef_ then
        mapRef_.BuildFromGrid(grid_)
    end
end

-- ============================================================================
-- 查询接口
-- ============================================================================

--- 获取编辑器网格（外部读取用）
---@return table
function LevelEditor.GetGrid()
    return grid_
end

--- 编辑器是否处于活跃状态
---@return boolean
function LevelEditor.IsActive()
    return LevelEditor.active
end

return LevelEditor

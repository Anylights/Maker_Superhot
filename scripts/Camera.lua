-- ============================================================================
-- Camera.lua - 正交侧视动态缩放相机
-- 2.5D 赛跑游戏：相机跟随所有玩家，自动缩放包含全部角色
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")

local Camera = {}

---@type Node
Camera.node = nil
---@type Camera
Camera.camera = nil

-- 内部状态
local currentCenter_ = Vector3(0, 0, 0)
local currentOrtho_ = Config.CameraMinOrtho
local targetCenter_ = Vector3(0, 0, 0)
local targetOrtho_ = Config.CameraMinOrtho

-- 手动模式（编辑器用，禁用自动跟随）
Camera.manualMode = false

-- 固定模式（游戏时显示全局地图，禁用自动跟随）
Camera.fixedMode = false

-- 屏幕震动状态
local shakeTimer_ = 0
local shakeDuration_ = 0
local shakeIntensity_ = 0

-- 动画过渡状态（仅供 intro 开场镜头使用，由 GameManager 手动驱动）
local animating_ = false
local animStartCenter_ = Vector3(0, 0, 0)
local animEndCenter_ = Vector3(0, 0, 0)
local animStartOrtho_ = 12.0
local animEndOrtho_ = 12.0
local animTimer_ = 0
local animDuration_ = 1.0

--- 初始化相机
---@param scene Scene
function Camera.Init(scene)
    Camera.node = scene:CreateChild("Camera", LOCAL)
    Camera.node.position = Vector3(0, 5, Config.CameraZ)
    Camera.node.rotation = Quaternion(0, 0, 0)

    Camera.camera = Camera.node:CreateComponent("Camera")
    Camera.camera.orthographic = true
    Camera.camera.orthoSize = Config.CameraMinOrtho
    Camera.camera.nearClip = 0.1
    Camera.camera.farClip = 100.0

    currentCenter_ = Vector3(0, 5, 0)
    currentOrtho_ = Config.CameraMinOrtho

    print("[Camera] Initialized orthographic side-view camera")
end

--- 每帧更新：根据玩家位置调整相机
---@param dt number
---@param playerPositions table
---@param humanPos Vector3|nil
function Camera.Update(dt, playerPositions, humanPos)
    if Camera.node == nil then return end
    if Camera.manualMode then return end

    -- intro 动画期间由 GameManager 完全控制相机，跳过自动逻辑
    if animating_ then return end

    -- 固定模式：lerp 平滑过渡到目标 + 处理屏幕震动
    if Camera.fixedMode then
        local smooth = Config.CameraSmoothSpeed * dt
        smooth = math.min(smooth, 1.0)
        currentCenter_ = currentCenter_ + (targetCenter_ - currentCenter_) * smooth
        currentOrtho_ = currentOrtho_ + (targetOrtho_ - currentOrtho_) * smooth

        -- 应用屏幕震动偏移
        local shakeOffX, shakeOffY = 0, 0
        if shakeTimer_ > 0 then
            shakeTimer_ = shakeTimer_ - dt
            local progress = shakeTimer_ / shakeDuration_
            local amp = shakeIntensity_ * progress
            shakeOffX = (math.random() * 2 - 1) * amp
            shakeOffY = (math.random() * 2 - 1) * amp
        end

        Camera.node.position = Vector3(currentCenter_.x + shakeOffX, currentCenter_.y + shakeOffY, Config.CameraZ)
        Camera.camera.orthoSize = currentOrtho_
        return
    end

    local mapMinX = 0
    local mapMaxX = MapData.Width * Config.BlockSize
    local mapMinY = 0
    local mapMaxY = MapData.Height * Config.BlockSize

    -- 地图边界容差：超出此范围的玩家视为"掉出"，放弃跟踪
    local boundsTolerance = Config.CameraPadding * 2
    local trackMinX = mapMinX - boundsTolerance
    local trackMaxX = mapMaxX + boundsTolerance
    local trackMinY = mapMinY - boundsTolerance
    local trackMaxY = mapMaxY + boundsTolerance * 3  -- 上方留更多空间（跳跃）

    local positions = {}
    for _, pos in ipairs(playerPositions) do
        -- 仅跟踪仍在地图合理范围内的玩家
        if pos.x >= trackMinX and pos.x <= trackMaxX
            and pos.y >= trackMinY and pos.y <= trackMaxY then
            table.insert(positions, Vector3(pos.x, pos.y, 0))
        end
    end

    if humanPos then
        if humanPos.x >= trackMinX and humanPos.x <= trackMaxX
            and humanPos.y >= trackMinY and humanPos.y <= trackMaxY then
            table.insert(positions, Vector3(humanPos.x, humanPos.y, 0))
        end
    end

    -- 无可跟踪玩家时保持当前位置不动
    if #positions == 0 then
        return
    end

    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge

    for _, pos in ipairs(positions) do
        if pos.x < minX then minX = pos.x end
        if pos.x > maxX then maxX = pos.x end
        if pos.y < minY then minY = pos.y end
        if pos.y > maxY then maxY = pos.y end
    end

    local cx = (minX + maxX) * 0.5
    local cy = (minY + maxY) * 0.5
    cx = math.max(mapMinX, math.min(mapMaxX, cx))
    cy = math.max(mapMinY, math.min(mapMaxY, cy))

    targetCenter_ = Vector3(cx, cy, 0)

    local spanX = maxX - minX + Config.CameraPadding * 2
    local spanY = maxY - minY + Config.CameraPadding * 2

    local aspect = Camera.camera.aspectRatio
    if aspect <= 0 then aspect = 16.0 / 9.0 end

    local orthoFromX = spanX / aspect
    local orthoFromY = spanY
    targetOrtho_ = math.max(orthoFromX, orthoFromY)
    targetOrtho_ = math.max(Config.CameraMinOrtho, math.min(Config.CameraMaxOrtho, targetOrtho_))

    -- 统一 lerp 平滑：位置和缩放均平滑过渡
    local smooth = Config.CameraSmoothSpeed * dt
    smooth = math.min(smooth, 1.0)
    currentCenter_ = currentCenter_ + (targetCenter_ - currentCenter_) * smooth
    currentOrtho_ = currentOrtho_ + (targetOrtho_ - currentOrtho_) * smooth

    -- 应用屏幕震动偏移
    local shakeOffX, shakeOffY = 0, 0
    if shakeTimer_ > 0 then
        shakeTimer_ = shakeTimer_ - dt
        local progress = shakeTimer_ / shakeDuration_  -- 1→0 衰减
        local amp = shakeIntensity_ * progress
        shakeOffX = (math.random() * 2 - 1) * amp
        shakeOffY = (math.random() * 2 - 1) * amp
    end

    Camera.node.position = Vector3(currentCenter_.x + shakeOffX, currentCenter_.y + shakeOffY, Config.CameraZ)
    Camera.camera.orthoSize = currentOrtho_
end

--- 获取 Camera 组件（用于设置 Viewport）
---@return Camera
function Camera.GetCamera()
    return Camera.camera
end

--- 强制设置相机位置（用于重置回合）
---@param center Vector3
---@param orthoSize number|nil
function Camera.SetImmediate(center, orthoSize)
    currentCenter_ = Vector3(center.x, center.y, 0)
    currentOrtho_ = orthoSize or Config.CameraMinOrtho
    targetCenter_ = currentCenter_
    targetOrtho_ = currentOrtho_

    if Camera.node then
        Camera.node.position = Vector3(currentCenter_.x, currentCenter_.y, Config.CameraZ)
    end
    if Camera.camera then
        Camera.camera.orthoSize = currentOrtho_
    end
end

-- ============================================================================
-- 坐标转换工具（正交投影）
-- ============================================================================

--- 世界坐标 → 屏幕逻辑坐标（Mode B）
---@param wx number 世界 X
---@param wy number 世界 Y
---@param logW number 逻辑宽度
---@param logH number 逻辑高度
---@return number, number  -- screenX, screenY
function Camera.WorldToScreen(wx, wy, logW, logH)
    if Camera.camera == nil or Camera.node == nil then return 0, 0 end
    local pos = Camera.node.position
    local ortho = Camera.camera.orthoSize
    local aspect = Camera.camera.aspectRatio
    if aspect <= 0 then aspect = 16.0 / 9.0 end
    local halfH = ortho * 0.5
    local halfW = halfH * aspect
    local sx = (wx - pos.x + halfW) / (2 * halfW) * logW
    local sy = (1.0 - (wy - pos.y + halfH) / (2 * halfH)) * logH
    return sx, sy
end

--- 世界尺寸 → 屏幕逻辑像素尺寸
---@param worldSize number 世界单位大小
---@param logH number 逻辑高度
---@return number  -- 屏幕像素大小
function Camera.WorldSizeToScreen(worldSize, logH)
    if Camera.camera == nil then return 0 end
    return worldSize / Camera.camera.orthoSize * logH
end

-- ============================================================================
-- 编辑器支持方法
-- ============================================================================

--- 直接设置正交尺寸（手动模式用）
---@param size number
function Camera.SetOrthoSize(size)
    currentOrtho_ = size
    targetOrtho_ = size
    if Camera.camera then
        Camera.camera.orthoSize = size
    end
end

--- 获取当前正交尺寸
---@return number
function Camera.GetOrthoSize()
    return currentOrtho_
end

--- 直接设置相机中心（手动模式用）
---@param x number
---@param y number
function Camera.SetCenter(x, y)
    currentCenter_ = Vector3(x, y, 0)
    targetCenter_ = Vector3(x, y, 0)
    if Camera.node then
        Camera.node.position = Vector3(x, y, Config.CameraZ)
    end
end

--- 获取当前相机中心
---@return number, number
function Camera.GetCenter()
    return currentCenter_.x, currentCenter_.y
end

-- ============================================================================
-- 固定模式（显示全局地图）
-- ============================================================================

--- 设置固定相机模式，自动计算中心和 orthoSize 以显示整个地图
---@param mapWidth number 地图宽度（格数）
---@param mapHeight number 地图高度（格数）
---@param padding number|nil 边距（默认 2）
function Camera.SetFixedForMap(mapWidth, mapHeight, padding)
    padding = padding or 2
    Camera.fixedMode = true

    local bs = Config.BlockSize
    local totalW = mapWidth * bs + padding * 2
    local totalH = mapHeight * bs + padding * 2

    -- 中心
    local cx = mapWidth * bs * 0.5
    local cy = mapHeight * bs * 0.5

    -- 计算所需 orthoSize
    local aspect = Camera.camera and Camera.camera.aspectRatio or (16.0 / 9.0)
    if aspect <= 0 then aspect = 16.0 / 9.0 end

    local orthoFromW = totalW / aspect
    local orthoFromH = totalH
    local ortho = math.max(orthoFromW, orthoFromH)

    -- 只设 target，让固定模式块内的 lerp 平滑过渡过去
    targetCenter_ = Vector3(cx, cy, 0)
    targetOrtho_ = ortho
    print("[Camera] Fixed mode: center=(" .. string.format("%.1f,%.1f", cx, cy) ..
          ") ortho=" .. string.format("%.1f", ortho) ..
          " map=" .. mapWidth .. "x" .. mapHeight)
end

-- ============================================================================
-- 动画过渡（开场镜头等）
-- ============================================================================

--- 平滑缓动函数（ease in-out cubic）
---@param t number 0~1
---@return number
local function easeInOutCubic(t)
    if t < 0.5 then
        return 4 * t * t * t
    else
        local f = (2 * t - 2)
        return 0.5 * f * f * f + 1
    end
end

--- 启动动画过渡：从当前位置平滑移动到目标位置
---@param center Vector3 目标中心
---@param orthoSize number 目标正交尺寸
---@param duration number 过渡时间（秒）
function Camera.AnimateTo(center, orthoSize, duration)
    animating_ = true
    animStartCenter_ = Vector3(currentCenter_.x, currentCenter_.y, 0)
    animEndCenter_ = Vector3(center.x, center.y, 0)
    animStartOrtho_ = currentOrtho_
    animEndOrtho_ = orthoSize
    animTimer_ = 0
    animDuration_ = math.max(0.01, duration)
    print("[Camera] AnimateTo: (" .. string.format("%.1f,%.1f", center.x, center.y) ..
          ") ortho=" .. string.format("%.1f", orthoSize) ..
          " dur=" .. string.format("%.1f", duration) .. "s")
end

--- 更新动画过渡（每帧调用）
---@param dt number
---@return boolean -- 动画是否仍在进行
function Camera.UpdateAnimation(dt)
    if not animating_ then return false end

    animTimer_ = animTimer_ + dt
    local t = math.min(animTimer_ / animDuration_, 1.0)
    local eased = easeInOutCubic(t)

    -- 插值位置和正交尺寸
    local cx = animStartCenter_.x + (animEndCenter_.x - animStartCenter_.x) * eased
    local cy = animStartCenter_.y + (animEndCenter_.y - animStartCenter_.y) * eased
    local ortho = animStartOrtho_ + (animEndOrtho_ - animStartOrtho_) * eased

    currentCenter_ = Vector3(cx, cy, 0)
    currentOrtho_ = ortho
    targetCenter_ = currentCenter_
    targetOrtho_ = currentOrtho_

    if Camera.node then
        Camera.node.position = Vector3(cx, cy, Config.CameraZ)
    end
    if Camera.camera then
        Camera.camera.orthoSize = ortho
    end

    if t >= 1.0 then
        animating_ = false
        return false
    end
    return true
end

--- 是否正在动画中
---@return boolean
function Camera.IsAnimating()
    return animating_
end

--- 停止动画
function Camera.StopAnimation()
    animating_ = false
end

--- 触发屏幕震动
---@param intensity number 震动强度（世界坐标单位偏移）
---@param duration number 震动持续时间（秒）
function Camera.Shake(intensity, duration)
    shakeIntensity_ = intensity
    shakeDuration_ = duration
    shakeTimer_ = duration
end

--- 释放固定模式（恢复自动跟随）
--- currentCenter_ 保持当前值，lerp 自然平滑过渡到玩家跟随位置
function Camera.ReleaseFixed()
    Camera.fixedMode = false
    print("[Camera] Fixed mode released")
end

--- 屏幕逻辑坐标 → 世界坐标（WorldToScreen 的逆变换）
---@param sx number 屏幕逻辑 X
---@param sy number 屏幕逻辑 Y
---@param logW number 逻辑宽度
---@param logH number 逻辑高度
---@return number, number  -- wx, wy
function Camera.ScreenToWorld(sx, sy, logW, logH)
    if Camera.camera == nil or Camera.node == nil then return 0, 0 end
    local pos = Camera.node.position
    local ortho = Camera.camera.orthoSize
    local aspect = Camera.camera.aspectRatio
    if aspect <= 0 then aspect = 16.0 / 9.0 end
    local halfH = ortho * 0.5
    local halfW = halfH * aspect
    local wx = (sx / logW) * (2 * halfW) - halfW + pos.x
    local wy = (1.0 - sy / logH) * (2 * halfH) - halfH + pos.y
    return wx, wy
end

return Camera

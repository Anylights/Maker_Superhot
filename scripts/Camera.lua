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

--- 初始化相机
---@param scene Scene
function Camera.Init(scene)
    Camera.node = scene:CreateChild("Camera")
    Camera.node.position = Vector3(0, 5, Config.CameraZ)
    -- 朝向 +Z 方向看（侧视）
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
--- 优先保证人类玩家可见；对所有位置做地图边界钳位
---@param dt number
---@param playerPositions table  -- {Vector3, Vector3, ...} 活跃玩家位置列表
---@param humanPos Vector3|nil   -- 人类玩家当前位置（即使死亡也传重生点）
function Camera.Update(dt, playerPositions, humanPos)
    if Camera.node == nil then return end

    -- 地图边界（世界坐标）
    local mapMinX = 0
    local mapMaxX = MapData.Width * Config.BlockSize
    local mapMinY = 0
    local mapMaxY = MapData.Height * Config.BlockSize

    -- 收集有效位置（钳位到地图边界内）
    local positions = {}
    for _, pos in ipairs(playerPositions) do
        local clampedY = math.max(mapMinY, pos.y)
        local clampedX = math.max(mapMinX, math.min(mapMaxX, pos.x))
        table.insert(positions, Vector3(clampedX, clampedY, 0))
    end

    -- 人类玩家位置始终加入（保证自己始终可见）
    if humanPos then
        local clampedY = math.max(mapMinY, humanPos.y)
        local clampedX = math.max(mapMinX, math.min(mapMaxX, humanPos.x))
        table.insert(positions, Vector3(clampedX, clampedY, 0))
    end

    -- 如果没有任何有效位置，维持当前相机
    if #positions == 0 then return end

    -- 计算所有位置的包围盒（XY 平面）
    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge

    for _, pos in ipairs(positions) do
        if pos.x < minX then minX = pos.x end
        if pos.x > maxX then maxX = pos.x end
        if pos.y < minY then minY = pos.y end
        if pos.y > maxY then maxY = pos.y end
    end

    -- 目标中心
    local cx = (minX + maxX) * 0.5
    local cy = (minY + maxY) * 0.5

    -- 钳位相机中心到地图范围内
    cx = math.max(mapMinX, math.min(mapMaxX, cx))
    cy = math.max(mapMinY, math.min(mapMaxY, cy))

    targetCenter_ = Vector3(cx, cy, 0)

    -- 目标正交尺寸：需要包含所有玩家 + 边距
    local spanX = maxX - minX + Config.CameraPadding * 2
    local spanY = maxY - minY + Config.CameraPadding * 2

    -- 根据屏幕宽高比决定
    local aspect = Camera.camera.aspectRatio
    if aspect <= 0 then aspect = 16.0 / 9.0 end

    -- orthoSize 是视野全高度，需要满足水平和垂直都能包含
    local orthoFromX = spanX / aspect
    local orthoFromY = spanY
    targetOrtho_ = math.max(orthoFromX, orthoFromY)
    targetOrtho_ = math.max(Config.CameraMinOrtho, math.min(Config.CameraMaxOrtho, targetOrtho_))

    -- 平滑过渡
    local smooth = Config.CameraSmoothSpeed * dt
    smooth = math.min(smooth, 1.0)  -- 防止 dt 过大导致过冲

    currentCenter_ = currentCenter_ + (targetCenter_ - currentCenter_) * smooth
    currentOrtho_ = currentOrtho_ + (targetOrtho_ - currentOrtho_) * smooth

    -- 应用相机参数
    Camera.node.position = Vector3(currentCenter_.x, currentCenter_.y, Config.CameraZ)
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

return Camera

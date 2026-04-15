-- ============================================================================
-- Map.lua - 地图方块管理（创建、破坏、重生）
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")

local Map = {}

---@type Scene
local scene_ = nil

-- 地图网格数据：grid[y][x] = 方块类型
local grid_ = {}

-- 节点引用：blockNodes[y][x] = Node|nil
local blockNodes_ = {}

-- 被破坏的方块重生计时器：destroyed[key] = { timer, blockType, x, y }
local destroyed_ = {}

-- 材质缓存（避免每个方块创建新材质）
local materialCache_ = {}

-- 方块模型缓存
local boxModel_ = nil
local pbrTechnique_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化地图系统
---@param scene Scene
function Map.Init(scene)
    scene_ = scene

    -- 缓存模型和技术
    boxModel_ = cache:GetResource("Model", "Models/Box.mdl")
    pbrTechnique_ = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")

    -- 预创建材质
    for blockType, color in pairs(Config.BlockColors) do
        materialCache_[blockType] = Map.CreateBlockMaterial(color, blockType)
    end

    print("[Map] Initialized")
end

--- 创建方块材质
---@param color Color
---@param blockType number
---@return Material
function Map.CreateBlockMaterial(color, blockType)
    local mat = Material:new()
    mat:SetTechnique(0, pbrTechnique_)
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Metallic", Variant(0.05))
    mat:SetShaderParameter("Roughness", Variant(0.65))

    -- 特殊方块的自发光
    if blockType == Config.BLOCK_ENERGY_PAD then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.1, 0.25, 0.3)))
    elseif blockType == Config.BLOCK_SPAWN then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.05, 0.2, 0.05)))
    elseif blockType == Config.BLOCK_FINISH then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.6, 0.5, 0.05)))
    end

    return mat
end

--- 构建完整地图
function Map.Build()
    -- 清除旧地图
    Map.Clear()

    -- 生成网格数据
    grid_ = MapData.Generate()

    -- 创建地图父节点
    local mapRoot = scene_:CreateChild("MapRoot")

    -- 遍历网格，创建方块节点
    blockNodes_ = {}
    local blockCount = 0

    for y = 1, MapData.Height do
        blockNodes_[y] = {}
        for x = 1, MapData.Width do
            local blockType = grid_[y][x]
            if blockType ~= Config.BLOCK_EMPTY then
                local node = Map.CreateBlockNode(mapRoot, x, y, blockType)
                blockNodes_[y][x] = node
                blockCount = blockCount + 1
            end
        end
    end

    -- 清空重生列表
    destroyed_ = {}

    print("[Map] Built " .. blockCount .. " blocks (" .. MapData.Width .. "x" .. MapData.Height .. ")")
end

--- 创建单个方块节点
---@param parent Node
---@param gx number 网格 X（1-based）
---@param gy number 网格 Y（1-based）
---@param blockType number
---@return Node
function Map.CreateBlockNode(parent, gx, gy, blockType)
    local bs = Config.BlockSize
    -- 网格坐标转世界坐标（格子中心）
    local wx = (gx - 1) * bs + bs * 0.5
    local wy = (gy - 1) * bs + bs * 0.5

    local node = parent:CreateChild("Block_" .. gx .. "_" .. gy)
    node.position = Vector3(wx, wy, 0)

    -- 视觉
    local model = node:CreateComponent("StaticModel")
    model.model = boxModel_
    model.castShadows = true

    local mat = materialCache_[blockType]
    if mat then
        model:SetMaterial(mat)
    end

    -- 物理碰撞（静态刚体，mass=0）
    local body = node:CreateComponent("RigidBody")
    body.collisionLayer = 1

    local shape = node:CreateComponent("CollisionShape")
    shape:SetBox(Vector3(bs, bs, bs))

    return node
end

-- ============================================================================
-- 运行时操作
-- ============================================================================

--- 每帧更新（处理方块重生）
---@param dt number
function Map.Update(dt)
    local toRespawn = {}

    for key, info in pairs(destroyed_) do
        info.timer = info.timer - dt
        if info.timer <= 0 then
            table.insert(toRespawn, key)
        end
    end

    -- 重生方块
    for _, key in ipairs(toRespawn) do
        local info = destroyed_[key]
        if info then
            Map.RespawnBlock(info.x, info.y, info.blockType)
            destroyed_[key] = nil
        end
    end
end

--- 在指定网格坐标爆炸（破坏范围内的可破坏方块）
---@param centerGX number 爆炸中心网格 X
---@param centerGY number 爆炸中心网格 Y
---@param radius number 爆炸半径（格数）
---@return number 被破坏的方块数
function Map.Explode(centerGX, centerGY, radius)
    local count = 0
    local radiusSq = radius * radius

    for dy = -radius, radius do
        for dx = -radius, radius do
            local gx = centerGX + dx
            local gy = centerGY + dy
            -- 圆形范围判定
            if dx * dx + dy * dy <= radiusSq then
                if Map.DestroyBlock(gx, gy) then
                    count = count + 1
                end
            end
        end
    end

    if count > 0 then
        print("[Map] Exploded at (" .. centerGX .. "," .. centerGY .. "), destroyed " .. count .. " blocks")
    end

    return count
end

--- 破坏指定方块
---@param gx number
---@param gy number
---@return boolean 是否成功破坏
function Map.DestroyBlock(gx, gy)
    if gx < 1 or gx > MapData.Width or gy < 1 or gy > MapData.Height then
        return false
    end

    local blockType = grid_[gy][gx]

    -- 只能破坏普通方块和能量托台
    if blockType ~= Config.BLOCK_NORMAL and blockType ~= Config.BLOCK_ENERGY_PAD then
        return false
    end

    -- 移除节点
    if blockNodes_[gy] and blockNodes_[gy][gx] then
        blockNodes_[gy][gx]:Remove()
        blockNodes_[gy][gx] = nil
    end

    -- 标记为空
    grid_[gy][gx] = Config.BLOCK_EMPTY

    -- 加入重生队列
    local key = gx .. "_" .. gy
    destroyed_[key] = {
        timer = Config.PlatformRespawnTime,
        blockType = blockType,
        x = gx,
        y = gy,
    }

    return true
end

--- 重生方块
---@param gx number
---@param gy number
---@param blockType number
function Map.RespawnBlock(gx, gy, blockType)
    if gx < 1 or gx > MapData.Width or gy < 1 or gy > MapData.Height then
        return
    end

    -- 恢复网格数据
    grid_[gy][gx] = blockType

    -- 创建新节点
    local mapRoot = scene_:GetChild("MapRoot")
    if mapRoot then
        local node = Map.CreateBlockNode(mapRoot, gx, gy, blockType)
        if not blockNodes_[gy] then
            blockNodes_[gy] = {}
        end
        blockNodes_[gy][gx] = node
    end
end

--- 世界坐标转网格坐标
---@param wx number
---@param wy number
---@return number, number  -- gx, gy（1-based）
function Map.WorldToGrid(wx, wy)
    local bs = Config.BlockSize
    local gx = math.floor(wx / bs) + 1
    local gy = math.floor(wy / bs) + 1
    return gx, gy
end

--- 网格坐标转世界坐标（格子中心）
---@param gx number
---@param gy number
---@return number, number  -- wx, wy
function Map.GridToWorld(gx, gy)
    local bs = Config.BlockSize
    local wx = (gx - 1) * bs + bs * 0.5
    local wy = (gy - 1) * bs + bs * 0.5
    return wx, wy
end

--- 获取指定位置的方块类型
---@param gx number
---@param gy number
---@return number
function Map.GetBlock(gx, gy)
    if gx < 1 or gx > MapData.Width or gy < 1 or gy > MapData.Height then
        return Config.BLOCK_EMPTY
    end
    return grid_[gy][gx] or Config.BLOCK_EMPTY
end

--- 检查指定位置是否有被破坏的方块正在重生
---@param gx number
---@param gy number
---@return boolean, number|nil  -- isDestroyed, remainingTime
function Map.IsBlockDestroyed(gx, gy)
    local key = gx .. "_" .. gy
    local info = destroyed_[key]
    if info then
        return true, info.timer
    end
    return false, nil
end

--- 获取所有正在重生的方块信息（用于 HUD 显示）
---@return table  -- { {x, y, timer, totalTime}, ... }
function Map.GetDestroyedBlocks()
    local result = {}
    for _, info in pairs(destroyed_) do
        table.insert(result, {
            x = info.x,
            y = info.y,
            timer = info.timer,
            totalTime = Config.PlatformRespawnTime,
        })
    end
    return result
end

--- 清除全部地图
function Map.Clear()
    local mapRoot = scene_:GetChild("MapRoot")
    if mapRoot then
        mapRoot:Remove()
    end
    grid_ = {}
    blockNodes_ = {}
    destroyed_ = {}
end

--- 重置地图（回到完整状态）
function Map.Reset()
    Map.Build()
end

return Map

-- ============================================================================
-- Pickup.lua - 能量拾取物系统
-- ============================================================================

local Config = require("Config")
local SFX = require("SFX")

local Pickup = {}

---@type Scene
local scene_ = nil
local playerModule_ = nil  -- Player 模块引用

-- 活跃拾取物列表
local pickups_ = {}

-- 材质缓存
local smallMat_ = nil
local largeMat_ = nil
local smallOutlineMat_ = nil
local largeOutlineMat_ = nil
local unlitTechnique_ = nil
local sphereModel_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化拾取物系统
---@param scene Scene
---@param playerRef table Player 模块引用
function Pickup.Init(scene, playerRef)
    scene_ = scene
    playerModule_ = playerRef

    unlitTechnique_ = cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml")
    sphereModel_ = cache:GetResource("Model", "Models/Sphere.mdl")

    -- 小能量块材质（青色，无光照纯色）
    smallMat_ = Material:new()
    smallMat_:SetTechnique(0, unlitTechnique_)
    smallMat_:SetShaderParameter("MatDiffColor", Variant(Config.PickupSmallColor))

    -- 小能量块描边材质（无光照纯色）
    smallOutlineMat_ = Material:new()
    smallOutlineMat_:SetTechnique(0, unlitTechnique_)
    smallOutlineMat_:SetShaderParameter("MatDiffColor", Variant(Config.PickupSmallOutline))

    -- 大能量块材质（金色，无光照纯色）
    largeMat_ = Material:new()
    largeMat_:SetTechnique(0, unlitTechnique_)
    largeMat_:SetShaderParameter("MatDiffColor", Variant(Config.PickupLargeColor))

    -- 大能量块描边材质（无光照纯色）
    largeOutlineMat_ = Material:new()
    largeOutlineMat_:SetTechnique(0, unlitTechnique_)
    largeOutlineMat_:SetShaderParameter("MatDiffColor", Variant(Config.PickupLargeOutline))

    print("[Pickup] Initialized")
end

--- 生成所有拾取物（现由 RandomPickup 模块控制，此处仅保留接口）
function Pickup.SpawnAll()
    Pickup.ClearAll()
    -- 不再从 MapData.EnergyPickups 读取，由 RandomPickup.Reset() 调用 Spawn()
    print("[Pickup] SpawnAll called (awaiting RandomPickup)")
end

--- 构建钻石造型 CustomGeometry（八面体）
---@param geom CustomGeometry
---@param w number 宽度（X 半径）
---@param h number 高度（Y 半径，上下顶点距离的一半）
---@param d number 深度（Z 半径）
local function buildDiamond(geom, w, h, d)
    geom:BeginGeometry(0, TRIANGLE_LIST)

    -- 八面体 6 个顶点
    local top    = Vector3(0,  h, 0)
    local bottom = Vector3(0, -h, 0)
    local front  = Vector3(0,  0, -d)
    local back   = Vector3(0,  0,  d)
    local left   = Vector3(-w, 0,  0)
    local right  = Vector3( w, 0,  0)

    -- 8 个三角面（上4 + 下4）
    local faces = {
        -- 上半部分
        { top, front, right },
        { top, right, back  },
        { top, back,  left  },
        { top, left,  front },
        -- 下半部分
        { bottom, right, front },
        { bottom, back,  right },
        { bottom, left,  back  },
        { bottom, front, left  },
    }

    for _, tri in ipairs(faces) do
        -- 计算面法线
        local e1 = tri[2] - tri[1]
        local e2 = tri[3] - tri[1]
        local n = e1:CrossProduct(e2):Normalized()

        for _, v in ipairs(tri) do
            geom:DefineVertex(v)
            geom:DefineNormal(n)
            geom:DefineTexCoord(Vector2(0, 0))
        end
    end

    geom:Commit()
end

--- 生成单个拾取物
---@param x number 世界 X
---@param y number 世界 Y
---@param size string "small"|"large"
function Pickup.Spawn(x, y, size)
    local node = scene_:CreateChild("Pickup_" .. size)
    node.position = Vector3(x, y, 0)

    local isLarge = (size == "large")
    local scale = isLarge and 0.6 or 0.4

    -- 钻石造型尺寸（世界坐标）
    local dw = scale * 0.5   -- X 半径
    local dh = scale * 0.7   -- Y 半径（略高，更像钻石）
    local dd = scale * 0.35  -- Z 半径

    -- 主体钻石
    local geom = node:CreateComponent("CustomGeometry")
    buildDiamond(geom, dw, dh, dd)
    geom.castShadows = true
    geom:SetMaterial(isLarge and largeMat_ or smallMat_)

    -- 描边子节点（略大，Z 偏后）
    local outlineNode = node:CreateChild("Outline")
    outlineNode.position = Vector3(0, 0, 0.08)
    outlineNode.scale = Vector3(1.18, 1.18, 1.0)
    local outGeom = outlineNode:CreateComponent("CustomGeometry")
    buildDiamond(outGeom, dw, dh, dd)
    outGeom.castShadows = false
    outGeom:SetMaterial(isLarge and largeOutlineMat_ or smallOutlineMat_)

    -- 触发器刚体
    local body = node:CreateComponent("RigidBody")
    body.trigger = true
    body.collisionLayer = 4
    body.collisionMask = 2  -- 只检测玩家

    local shape = node:CreateComponent("CollisionShape")
    shape:SetSphere(scale * 1.2)

    local pickup = {
        node = node,
        size = size,
        amount = isLarge and Config.LargeEnergyAmount or Config.SmallEnergyAmount,
        active = true,
        respawnTimer = 0,
        spawnX = x,
        spawnY = y,
        bobPhase = math.random() * math.pi * 2,  -- 随机初始浮动相位
    }

    table.insert(pickups_, pickup)
end

-- ============================================================================
-- 更新
-- ============================================================================

-- 拾取距离阈值（米）
local PICKUP_DISTANCE = 1.5

--- 每帧更新
---@param dt number
function Pickup.Update(dt)
    for _, pk in ipairs(pickups_) do
        if pk.active then
            -- 旋转 + 上下浮动动画
            if pk.node then
                pk.node:Rotate(Quaternion(0, 120 * dt, 0))
                pk.bobPhase = (pk.bobPhase or 0) + dt * 3.0
                local bobOffset = math.sin(pk.bobPhase) * 0.12
                pk.node.position = Vector3(pk.spawnX, pk.spawnY + bobOffset, 0)
            end

            -- 碰撞检测（简单距离检测，使用拾取前的位置快照）
            if pk.node and playerModule_ then
                local pkX, pkY = pk.spawnX, pk.spawnY
                for _, p in ipairs(playerModule_.list) do
                    if p.alive and p.node then
                        local pPos = p.node.position
                        local dx = pPos.x - pkX
                        local dy = pPos.y - pkY
                        local dist = math.sqrt(dx * dx + dy * dy)
                        if dist < PICKUP_DISTANCE then
                            -- 拾取：标记为待移除
                            playerModule_.AddEnergy(p, pk.amount)
                            pk.collected = true
                            SFX.Play(pk.size == "large" and "pickup_large" or "pickup_small", 0.6)
                            print("[Pickup] Player " .. p.index .. " picked up " .. pk.size .. " energy")
                            break
                        end
                    end
                end
            end
        end
    end

    -- 清理已收集的拾取物（反向遍历安全删除）
    for i = #pickups_, 1, -1 do
        if pickups_[i].collected then
            if pickups_[i].node then
                pickups_[i].node:Remove()
            end
            table.remove(pickups_, i)
        end
    end
end

--- 获取当前活跃（未被收集）的拾取物数量
---@return number
function Pickup.GetActiveCount()
    local count = 0
    for _, pk in ipairs(pickups_) do
        if pk.active and not pk.collected then
            count = count + 1
        end
    end
    return count
end

--- 检查指定位置附近是否已有拾取物
---@param x number 世界 X
---@param y number 世界 Y
---@param radius number 检查半径
---@return boolean
function Pickup.HasPickupNear(x, y, radius)
    local r2 = radius * radius
    for _, pk in ipairs(pickups_) do
        if pk.active and not pk.collected then
            local dx = pk.spawnX - x
            local dy = pk.spawnY - y
            if dx * dx + dy * dy < r2 then
                return true
            end
        end
    end
    return false
end

--- 清除所有拾取物
function Pickup.ClearAll()
    for _, pk in ipairs(pickups_) do
        if pk.node then
            pk.node:Remove()
        end
    end
    pickups_ = {}
end

--- 重置所有拾取物
function Pickup.Reset()
    Pickup.SpawnAll()
end

return Pickup

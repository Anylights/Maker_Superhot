-- ============================================================================
-- Pickup.lua - 能量拾取物系统
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
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
local pbrTechnique_ = nil
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

    pbrTechnique_ = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")
    sphereModel_ = cache:GetResource("Model", "Models/Sphere.mdl")

    -- 小能量块材质（亮青色）
    smallMat_ = Material:new()
    smallMat_:SetTechnique(0, pbrTechnique_)
    smallMat_:SetShaderParameter("MatDiffColor", Variant(Color(0.3, 0.9, 1.0, 1.0)))
    smallMat_:SetShaderParameter("MatEmissiveColor", Variant(Color(0.1, 0.3, 0.4)))
    smallMat_:SetShaderParameter("Metallic", Variant(0.8))
    smallMat_:SetShaderParameter("Roughness", Variant(0.2))

    -- 大能量块材质（亮金色）
    largeMat_ = Material:new()
    largeMat_:SetTechnique(0, pbrTechnique_)
    largeMat_:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.85, 0.2, 1.0)))
    largeMat_:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 0.3, 0.05)))
    largeMat_:SetShaderParameter("Metallic", Variant(0.9))
    largeMat_:SetShaderParameter("Roughness", Variant(0.15))

    print("[Pickup] Initialized")
end

--- 生成所有拾取物
function Pickup.SpawnAll()
    Pickup.ClearAll()

    for _, data in ipairs(MapData.EnergyPickups) do
        Pickup.Spawn(data.x, data.y, data.size)
    end

    print("[Pickup] Spawned " .. #pickups_ .. " energy pickups")
end

--- 生成单个拾取物
---@param x number 世界 X
---@param y number 世界 Y
---@param size string "small"|"large"
function Pickup.Spawn(x, y, size)
    local node = scene_:CreateChild("Pickup_" .. size)
    node.position = Vector3(x, y, 0)

    local scale = (size == "large") and 0.6 or 0.4
    node.scale = Vector3(scale, scale, scale)

    -- 视觉
    local model = node:CreateComponent("StaticModel")
    model.model = sphereModel_
    model.castShadows = true
    model:SetMaterial(size == "large" and largeMat_ or smallMat_)

    -- 触发器刚体
    local body = node:CreateComponent("RigidBody")
    body.trigger = true
    body.collisionLayer = 4
    body.collisionMask = 2  -- 只检测玩家

    local shape = node:CreateComponent("CollisionShape")
    shape:SetSphere(1.0)

    local pickup = {
        node = node,
        size = size,
        amount = (size == "large") and Config.LargeEnergyAmount or Config.SmallEnergyAmount,
        active = true,
        respawnTimer = 0,
        spawnX = x,
        spawnY = y,
    }

    table.insert(pickups_, pickup)
end

-- ============================================================================
-- 更新
-- ============================================================================

--- 每帧更新
---@param dt number
function Pickup.Update(dt)
    for _, pk in ipairs(pickups_) do
        if pk.active then
            -- 旋转动画
            if pk.node then
                pk.node:Rotate(Quaternion(0, 120 * dt, 0))
            end

            -- 碰撞检测（简单距离检测，因为 trigger 事件在后续用全局订阅更方便）
            if pk.node and playerModule_ then
                local pkPos = pk.node.position
                for _, p in ipairs(playerModule_.list) do
                    if p.alive and p.node and p.energy < 1.0 then
                        local diff = p.node.position - pkPos
                        local dist = math.sqrt(diff.x * diff.x + diff.y * diff.y)
                        if dist < 0.8 then
                            -- 拾取
                            playerModule_.AddEnergy(p, pk.amount)
                            pk.active = false
                            pk.respawnTimer = Config.PickupRespawnTime
                            if pk.node then
                                pk.node.enabled = false
                            end
                            SFX.Play(pk.size == "large" and "pickup_large" or "pickup_small", 0.6)
                            print("[Pickup] Player " .. p.index .. " picked up " .. pk.size .. " energy")
                            break
                        end
                    end
                end
            end
        else
            -- 等待重生
            pk.respawnTimer = pk.respawnTimer - dt
            if pk.respawnTimer <= 0 then
                pk.active = true
                if pk.node then
                    pk.node.enabled = true
                    pk.node.position = Vector3(pk.spawnX, pk.spawnY, 0)
                end
            end
        end
    end
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

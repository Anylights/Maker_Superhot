-- ============================================================================
-- Pickup.lua - 能量拾取物系统
-- ============================================================================

local Config = require("Config")
local SFX = require("SFX")
local HUD = require("HUD")
local PowerUp = require("PowerUp")

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

-- 道具材质缓存 { [effectType] = { main, outline } }
local powerUpMats_ = {}

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

    -- 特殊道具材质（按效果类型，带发光）
    local pbrTech = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")
    for _, effectType in ipairs(PowerUp.ALL_TYPES) do
        local color = Config.PowerUpColors[effectType]
        if color then
            local mainMat = Material:new()
            mainMat:SetTechnique(0, pbrTech)
            mainMat:SetShaderParameter("MatDiffColor", Variant(color))
            mainMat:SetShaderParameter("MatEmissiveColor", Variant(Color(color.r * 0.4, color.g * 0.4, color.b * 0.4)))
            mainMat:SetShaderParameter("Metallic", Variant(0.1))
            mainMat:SetShaderParameter("Roughness", Variant(0.4))

            local outColor = Color(color.r * 0.4, color.g * 0.4, color.b * 0.4, 1.0)
            local outMat = Material:new()
            outMat:SetTechnique(0, unlitTechnique_)
            outMat:SetShaderParameter("MatDiffColor", Variant(outColor))

            powerUpMats_[effectType] = { main = mainMat, outline = outMat }
        end
    end

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

--- 构建八角星造型 CustomGeometry（特殊道具外观）
--- 基于八面体但每个顶点外扩形成尖刺星形
---@param geom CustomGeometry
---@param r number 外径半径
local function buildOctaStar(geom, r)
    geom:BeginGeometry(0, TRIANGLE_LIST)

    -- 八角星：8 个外尖 + 8 个内凹顶点交替排列在 XY 平面上
    -- 然后前后各一个中心点形成 3D 外观
    local innerR = r * 0.45
    local outerR = r
    local depthR = r * 0.4

    local frontZ = -depthR
    local backZ = depthR
    local centerFront = Vector3(0, 0, frontZ)
    local centerBack = Vector3(0, 0, backZ)

    -- 生成 16 个环形顶点（8 外 + 8 内，交替）
    local ringVerts = {}
    for i = 0, 15 do
        local angle = (i / 16) * math.pi * 2 - math.pi / 2
        local radius = (i % 2 == 0) and outerR or innerR
        local vx = math.cos(angle) * radius
        local vy = math.sin(angle) * radius
        table.insert(ringVerts, Vector3(vx, vy, 0))
    end

    -- 前面三角扇（16 个三角形）
    for i = 1, 16 do
        local v1 = ringVerts[i]
        local v2 = ringVerts[(i % 16) + 1]
        local e1 = v1 - centerFront
        local e2 = v2 - centerFront
        local n = e1:CrossProduct(e2):Normalized()

        geom:DefineVertex(centerFront)
        geom:DefineNormal(n)
        geom:DefineTexCoord(Vector2(0.5, 0.5))

        geom:DefineVertex(v1)
        geom:DefineNormal(n)
        geom:DefineTexCoord(Vector2(0, 0))

        geom:DefineVertex(v2)
        geom:DefineNormal(n)
        geom:DefineTexCoord(Vector2(1, 0))
    end

    -- 后面三角扇（反向绕序）
    for i = 1, 16 do
        local v1 = ringVerts[i]
        local v2 = ringVerts[(i % 16) + 1]
        local e1 = v2 - centerBack
        local e2 = v1 - centerBack
        local n = e1:CrossProduct(e2):Normalized()

        geom:DefineVertex(centerBack)
        geom:DefineNormal(n)
        geom:DefineTexCoord(Vector2(0.5, 0.5))

        geom:DefineVertex(v2)
        geom:DefineNormal(n)
        geom:DefineTexCoord(Vector2(0, 0))

        geom:DefineVertex(v1)
        geom:DefineNormal(n)
        geom:DefineTexCoord(Vector2(1, 0))
    end

    geom:Commit()
end

--- 生成单个拾取物
---@param x number 世界 X
---@param y number 世界 Y
---@param size string "small"|"large"|"powerup"
---@param effectType string|nil 道具效果类型（仅 size=="powerup" 时有效）
function Pickup.Spawn(x, y, size, effectType)
    local isPowerUp = (size == "powerup")
    local isLarge = (size == "large")

    local node = scene_:CreateChild("Pickup_" .. size, LOCAL)
    node.position = Vector3(x, y, 0)

    if isPowerUp then
        -- 特殊道具：八角星造型，更大
        local starR = 0.5
        local geom = node:CreateComponent("CustomGeometry")
        buildOctaStar(geom, starR)
        geom.castShadows = true

        local mats = powerUpMats_[effectType]
        if mats then
            geom:SetMaterial(mats.main)
        end

        -- 描边子节点
        local outlineNode = node:CreateChild("Outline")
        outlineNode.position = Vector3(0, 0, 0.08)
        outlineNode.scale = Vector3(1.18, 1.18, 1.0)
        local outGeom = outlineNode:CreateComponent("CustomGeometry")
        buildOctaStar(outGeom, starR)
        outGeom.castShadows = false
        if mats then
            outGeom:SetMaterial(mats.outline)
        end

        -- 触发器刚体
        local body = node:CreateComponent("RigidBody")
        body.trigger = true
        body.collisionLayer = 4
        body.collisionMask = 2

        local shape = node:CreateComponent("CollisionShape")
        shape:SetSphere(starR * 2.0)
    else
        -- 普通能量道具：钻石造型
        local scale = isLarge and 0.6 or 0.4

        local dw = scale * 0.5
        local dh = scale * 0.7
        local dd = scale * 0.35

        local geom = node:CreateComponent("CustomGeometry")
        buildDiamond(geom, dw, dh, dd)
        geom.castShadows = true
        geom:SetMaterial(isLarge and largeMat_ or smallMat_)

        local outlineNode = node:CreateChild("Outline")
        outlineNode.position = Vector3(0, 0, 0.08)
        outlineNode.scale = Vector3(1.18, 1.18, 1.0)
        local outGeom = outlineNode:CreateComponent("CustomGeometry")
        buildDiamond(outGeom, dw, dh, dd)
        outGeom.castShadows = false
        outGeom:SetMaterial(isLarge and largeOutlineMat_ or smallOutlineMat_)

        local body = node:CreateComponent("RigidBody")
        body.trigger = true
        body.collisionLayer = 4
        body.collisionMask = 2

        local shape = node:CreateComponent("CollisionShape")
        shape:SetSphere(scale * 1.2)
    end

    local pickup = {
        node = node,
        size = size,
        effectType = effectType,  -- 道具效果类型（仅 powerup）
        amount = isPowerUp and 0 or (isLarge and Config.LargeEnergyAmount or Config.SmallEnergyAmount),
        active = true,
        respawnTimer = 0,
        spawnX = x,
        spawnY = y,
        bobPhase = math.random() * math.pi * 2,
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
                            pk.collected = true

                            if pk.size == "powerup" and pk.effectType then
                                -- 特殊道具：应用 buff 效果
                                PowerUp.Apply(p.index, pk.effectType)
                                -- 显示道具名称浮动文字
                                if p.index == 1 and HUD.AddScorePopup then
                                    local color = Config.PowerUpColors[pk.effectType]
                                    if color then
                                        local name = Config.PowerUpNames[pk.effectType] or "???"
                                        HUD.AddScorePopup(pkX, pkY, name,
                                            math.floor(color.r * 255),
                                            math.floor(color.g * 255),
                                            math.floor(color.b * 255), 24)
                                    end
                                end
                                SFX.Play("pickup_large", 0.8, pkX, pkY)
                                print("[Pickup] Player " .. p.index .. " picked up powerup: " .. pk.effectType)
                            else
                                -- 普通能量道具
                                playerModule_.AddEnergy(p, pk.amount)
                                local scorePoints = (pk.size == "large") and Config.PickupLargeScore or Config.PickupSmallScore
                                if playerModule_.AddPickupScore then
                                    playerModule_.AddPickupScore(p, scorePoints)
                                end
                                if p.index == 1 and HUD.AddScorePopup then
                                    local popColor = (pk.size == "large")
                                        and {r = 255, g = 220, b = 50}
                                        or  {r = 100, g = 255, b = 220}
                                    local popSize = (pk.size == "large") and 22 or 16
                                    HUD.AddScorePopup(pkX, pkY, "+" .. scorePoints, popColor.r, popColor.g, popColor.b, popSize)
                                end
                                SFX.Play(pk.size == "large" and "pickup_large" or "pickup_small", 0.6, pkX, pkY)
                                print("[Pickup] Player " .. p.index .. " picked up " .. pk.size .. " (+" .. scorePoints .. " score)")
                            end
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

--- 列出所有当前活跃（未被收集）的拾取物位置（供 AI 决策使用）
---@return table list 每项 { x, y, size, amount }
function Pickup.GetActivePickups()
    local list = {}
    for _, pk in ipairs(pickups_) do
        if pk.active and not pk.collected then
            table.insert(list, {
                x = pk.spawnX,
                y = pk.spawnY,
                size = pk.size,
                amount = pk.amount,
            })
        end
    end
    return list
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

--- 清理距离玩家太远的拾取物（大地图模式用）
---@param playerY number 玩家当前 Y 高度
---@param maxDistance number 最大允许距离
function Pickup.CleanupFarPickups(playerY, maxDistance)
    for i = #pickups_, 1, -1 do
        local pk = pickups_[i]
        if pk.active and not pk.collected then
            local dy = math.abs(pk.spawnY - playerY)
            if dy > maxDistance then
                if pk.node then pk.node:Remove() end
                table.remove(pickups_, i)
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

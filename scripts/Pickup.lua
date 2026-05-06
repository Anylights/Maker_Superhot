-- ============================================================================
-- Pickup.lua - 能量拾取物系统
-- ============================================================================

local Config = require("Config")
local SFX = require("SFX")

local Pickup = {}

---@type Scene
local scene_ = nil
local playerModule_ = nil  -- Player 模块引用
local networkMode_ = "standalone"  -- "standalone" | "server" | "client"

-- 活跃拾取物列表
local pickups_ = {}

-- 客户端：已拾取的 NodeID 黑名单（防止 ScanReplicatedNodes 在服务端 REPLICATED 节点
-- 同步删除到达之前重新挂载视觉）
local collectedNodeIds_ = {}

--- 设置网络模式（必须在 Init 之前或之后立即调用）
---@param mode string "standalone" | "server" | "client"
function Pickup.SetNetworkMode(mode)
    networkMode_ = mode
end

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

--- 为已有节点挂上视觉子节点（LOCAL 模式，避免与服务端节点同步冲突）
---@param node Node REPLICATED 父节点
---@param size string "small"|"large"
local function attachVisualsTo(node, size)
    local isLarge = (size == "large")
    local scale = isLarge and 0.6 or 0.4
    local dw = scale * 0.5
    local dh = scale * 0.7
    local dd = scale * 0.35

    -- 主体钻石（CustomGeometry 是组件，跟随 node 的 mode；显式重建在子节点更稳）
    local visualNode = node:CreateChild("Visual", LOCAL)
    local geom = visualNode:CreateComponent("CustomGeometry", LOCAL)
    buildDiamond(geom, dw, dh, dd)
    geom.castShadows = true
    geom:SetMaterial(isLarge and largeMat_ or smallMat_)

    -- 描边
    local outlineNode = visualNode:CreateChild("Outline", LOCAL)
    outlineNode.position = Vector3(0, 0, 0.08)
    outlineNode.scale = Vector3(1.18, 1.18, 1.0)
    local outGeom = outlineNode:CreateComponent("CustomGeometry", LOCAL)
    buildDiamond(outGeom, dw, dh, dd)
    outGeom.castShadows = false
    outGeom:SetMaterial(isLarge and largeOutlineMat_ or smallOutlineMat_)
end

--- 生成单个拾取物
---@param x number 世界 X
---@param y number 世界 Y
---@param size string "small"|"large"
function Pickup.Spawn(x, y, size)
    -- 节点：服务端创建 REPLICATED（默认）让客户端能感知；
    -- 单机/客户端创建 LOCAL（不会触发同步）
    local createMode = (networkMode_ == "server") and REPLICATED or LOCAL
    local node = scene_:CreateChild("Pickup_" .. size, createMode)
    node.position = Vector3(x, y, 0)

    local isLarge = (size == "large")
    local scale = isLarge and 0.6 or 0.4

    -- 视觉：服务端跳过；其它模式（standalone/client）立即挂上
    if networkMode_ ~= "server" then
        attachVisualsTo(node, size)
    end

    -- 物理：仅服务端 / 单机需要触发器；客户端不需要（客户端不做拾取判定）
    if networkMode_ ~= "client" then
        local bodyMode = (networkMode_ == "server") and LOCAL or REPLICATED
        local body = node:CreateComponent("RigidBody", bodyMode)
        body.trigger = true
        body.collisionLayer = 4
        body.collisionMask = 2

        local shape = node:CreateComponent("CollisionShape", bodyMode)
        shape:SetSphere(scale * 1.2)
    end

    local pickup = {
        node = node,
        size = size,
        amount = isLarge and Config.LargeEnergyAmount or Config.SmallEnergyAmount,
        active = true,
        respawnTimer = 0,
        spawnX = x,
        spawnY = y,
        bobPhase = math.random() * math.pi * 2,
    }

    table.insert(pickups_, pickup)
end

--- 客户端：处理服务端复制过来的 Pickup_xxx 节点（NodeAdded 触发）
---@param node Node REPLICATED 节点
function Pickup.AttachClientVisualsForNode(node)
    if not node then return end
    local name = node.name
    local size
    if name == "Pickup_small" then size = "small"
    elseif name == "Pickup_large" then size = "large"
    else return end

    -- 已拾取黑名单：服务端 Remove 同步未到达期间，禁止重新挂载视觉
    if collectedNodeIds_[node.ID] then return end

    -- 防重复
    if node:GetChild("Visual", false) then return end
    attachVisualsTo(node, size)

    -- 加入 pickups_ 用于 UpdateVisuals 的旋转/浮动动画
    local isLarge = (size == "large")
    table.insert(pickups_, {
        node = node,
        size = size,
        amount = isLarge and Config.LargeEnergyAmount or Config.SmallEnergyAmount,
        active = true,
        respawnTimer = 0,
        spawnX = node.position.x,
        spawnY = node.position.y,
        bobPhase = math.random() * math.pi * 2,
    })
    print("[Pickup] Client visual attached to " .. name .. " (id=" .. node.ID .. ")")
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
                            -- 服务端：广播拾取事件给所有客户端，触发即时视觉移除
                            if networkMode_ == "server" and Pickup.onCollected then
                                Pickup.onCollected(pk.node and pk.node.ID or 0, p.index, pk.size)
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
                -- 服务端 REPLICATED 节点使用 Dispose() 立即断开引用并触发网络同步删除
                -- Remove() 依赖 GC，可能延迟数帧导致客户端看到"幽灵"节点
                pickups_[i].node:Dispose()
            end
            table.remove(pickups_, i)
        end
    end
end

--- 客户端专用：仅更新视觉动画（旋转+浮动），不做碰撞检测
---@param dt number
function Pickup.UpdateVisuals(dt)
    -- 反向遍历，剔除被服务端 Remove 后变成无效引用的节点
    for i = #pickups_, 1, -1 do
        local pk = pickups_[i]
        local node = pk.node
        -- node:GetID() == 0 表示节点已被销毁
        if not node or node.ID == 0 or not node.parent then
            table.remove(pickups_, i)
        elseif pk.active then
            node:Rotate(Quaternion(0, 120 * dt, 0))
            pk.bobPhase = (pk.bobPhase or 0) + dt * 3.0
            local bobOffset = math.sin(pk.bobPhase) * 0.12
            node.position = Vector3(pk.spawnX, pk.spawnY + bobOffset, 0)
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

--- 客户端专用：根据服务端广播的 NodeID 立即移除拾取物（视觉与索引）
---@param nodeId number
---@return boolean removed 是否成功移除
function Pickup.RemoveByNodeID(nodeId)
    if not nodeId or nodeId == 0 then return false end
    -- 加入黑名单（无论 pickups_ 是否找到，都要标记，避免 Scan 重新 attach）
    collectedNodeIds_[nodeId] = true
    for i = #pickups_, 1, -1 do
        local pk = pickups_[i]
        if pk.node and pk.node.ID == nodeId then
            -- 客户端不能 Remove REPLICATED 节点，但可以移除本地的 Visual 子节点让它消失
            local visual = pk.node:GetChild("Visual", false)
            if visual then visual:Remove() end
            table.remove(pickups_, i)
            return true
        end
    end
    return false
end

--- 清除所有拾取物
function Pickup.ClearAll()
    -- 客户端：不能 Remove REPLICATED 节点（会与服务端同步冲突）
    -- 仅清空本地索引；节点自身由服务端 Remove 后通过同步消失
    if networkMode_ == "client" then
        pickups_ = {}
        collectedNodeIds_ = {}  -- 新回合开始，重置已拾取黑名单
        return
    end
    for _, pk in ipairs(pickups_) do
        if pk.node then
            -- 服务端 REPLICATED 节点用 Dispose() 确保即时网络同步
            if networkMode_ == "server" then
                pk.node:Dispose()
            else
                pk.node:Remove()
            end
        end
    end
    pickups_ = {}
    collectedNodeIds_ = {}
end

--- 重置所有拾取物
function Pickup.Reset()
    Pickup.SpawnAll()
end

return Pickup

-- ============================================================================
-- Map.lua - 地图方块管理（创建、破坏、重生、分块渲染）
-- 支持 500m 大世界地图，仅渲染相机附近 ±ChunkRenderBuffer 范围的方块
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")

local Map = {}

---@type Scene
local scene_ = nil

-- 地图网格数据：grid[y][x] = 方块类型
local grid_ = {}

-- 节点引用：blockNodes[y][x] = Node|nil（仅可见区域有节点）
local blockNodes_ = {}

-- 被破坏的方块重生计时器：destroyed[key] = { timer, blockType, x, y }
local destroyed_ = {}

-- 材质缓存（避免每个方块创建新材质）
local materialCache_ = {}

-- 方块模型缓存
local boxModel_ = nil
local pbrTechnique_ = nil

-- 飞散碎片列表：{ node, velX, velY, rotSpeed, life }
local debris_ = {}

-- 重生缩放动画列表：{ node, timer, duration }
local respawnAnims_ = {}

-- 网络模式：服务端跳过视觉组件
local skipVisuals_ = false
-- 网络模式：客户端跳过物理组件（无动态刚体，不需要碰撞）
local skipPhysics_ = false

-- ============================================================================
-- 分块渲染状态
-- ============================================================================

-- 当前可见行范围（1-based grid Y）
local visibleMinY_ = 0
local visibleMaxY_ = 0

-- 地图根节点
---@type Node
local mapRoot_ = nil

--- 设置是否跳过视觉组件（必须在 Init 之前调用）
---@param skip boolean
function Map.SetSkipVisuals(skip)
    skipVisuals_ = skip
    print("[Map] Skip visuals set to: " .. tostring(skip))
end

--- 设置是否跳过物理组件（客户端不需要地图碰撞）
---@param skip boolean
function Map.SetSkipPhysics(skip)
    skipPhysics_ = skip
    print("[Map] Skip physics set to: " .. tostring(skip))
end

-- 描边材质缓存
local outlineMat_ = nil

-- ============================================================================
-- 圆角矩形生成（CustomGeometry）
-- ============================================================================

--- 在 CustomGeometry 上生成一个圆角矩形方块
--- 方块中心在原点，尺寸 size x size x size，圆角半径 r
---@param geom userdata CustomGeometry 组件
---@param size number 方块边长
---@param r number 圆角半径
local function buildRoundedBox(geom, size, r)
    local h = size * 0.5
    r = math.min(r, h * 0.5)
    local segs = 4

    geom:SetNumGeometries(1)
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local function tri(p1, p2, p3, n)
        geom:DefineVertex(p1)
        geom:DefineNormal(n)
        geom:DefineVertex(p2)
        geom:DefineNormal(n)
        geom:DefineVertex(p3)
        geom:DefineNormal(n)
    end

    local function quad(p1, p2, p3, p4, n)
        tri(p1, p2, p3, n)
        tri(p1, p3, p4, n)
    end

    local function roundedRectVerts()
        local verts = {}
        local corners = {
            { x =  h - r, y =  h - r },
            { x = -h + r, y =  h - r },
            { x = -h + r, y = -h + r },
            { x =  h - r, y = -h + r },
        }
        local startAngles = { 0, math.pi * 0.5, math.pi, math.pi * 1.5 }
        for ci = 1, 4 do
            local cx = corners[ci].x
            local cy = corners[ci].y
            local sa = startAngles[ci]
            for si = 0, segs do
                local a = sa + (math.pi * 0.5) * si / segs
                table.insert(verts, {
                    x = cx + r * math.cos(a),
                    y = cy + r * math.sin(a),
                })
            end
        end
        return verts
    end

    local outline = roundedRectVerts()
    local nv = #outline

    local frontZ = h
    local backZ = -h

    -- 正面（Z+）
    local nFront = Vector3(0, 0, 1)
    local center = Vector3(0, 0, frontZ)
    for i = 1, nv do
        local j = (i % nv) + 1
        local p1 = Vector3(outline[i].x, outline[i].y, frontZ)
        local p2 = Vector3(outline[j].x, outline[j].y, frontZ)
        tri(center, p1, p2, nFront)
    end

    -- 背面（Z-）
    local nBack = Vector3(0, 0, -1)
    local centerB = Vector3(0, 0, backZ)
    for i = 1, nv do
        local j = (i % nv) + 1
        local p1 = Vector3(outline[i].x, outline[i].y, backZ)
        local p2 = Vector3(outline[j].x, outline[j].y, backZ)
        tri(centerB, p2, p1, nBack)
    end

    -- 侧面
    for i = 1, nv do
        local j = (i % nv) + 1
        local v1 = outline[i]
        local v2 = outline[j]

        local f1 = Vector3(v1.x, v1.y, frontZ)
        local f2 = Vector3(v2.x, v2.y, frontZ)
        local b1 = Vector3(v1.x, v1.y, backZ)
        local b2 = Vector3(v2.x, v2.y, backZ)

        local dx = v2.x - v1.x
        local dy = v2.y - v1.y
        local len = math.sqrt(dx * dx + dy * dy)
        local nx, ny = dy / len, -dx / len
        local sideN = Vector3(nx, ny, 0)

        quad(f1, f2, b2, b1, sideN)
    end

    geom:Commit()
end

--- 公共接口：在指定 CustomGeometry 上构建圆角矩形
--- 供其他模块（如 Player）复用
---@param geom userdata CustomGeometry 组件
---@param size number 方块边长
---@param r number 圆角半径
function Map.BuildRoundedBox(geom, size, r)
    buildRoundedBox(geom, size, r)
end

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化地图系统
---@param scene Scene
function Map.Init(scene)
    scene_ = scene

    if not skipVisuals_ then
        boxModel_ = cache:GetResource("Model", "Models/Box.mdl")
        pbrTechnique_ = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")

        for blockType, color in pairs(Config.BlockColors) do
            materialCache_[blockType] = Map.CreateBlockMaterial(color, blockType)
        end

        outlineMat_ = Material:new()
        outlineMat_:SetTechnique(0, pbrTechnique_)
        outlineMat_:SetShaderParameter("MatDiffColor", Variant(Config.BlockOutlineColor))
        outlineMat_:SetShaderParameter("Metallic", Variant(0.0))
        outlineMat_:SetShaderParameter("Roughness", Variant(1.0))
    end

    local matCount = 0
    for _ in pairs(materialCache_) do matCount = matCount + 1 end
    print("[Map] Initialized (skipVisuals=" .. tostring(skipVisuals_) .. ", skipPhysics=" .. tostring(skipPhysics_) .. ", materialsCached=" .. matCount .. ")")
end

--- 创建方块材质
---@param color Color
---@param blockType number
---@return Material
function Map.CreateBlockMaterial(color, blockType)
    local mat = Material:new()
    mat:SetTechnique(0, pbrTechnique_)
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Metallic", Variant(Config.RubberMetallic))
    mat:SetShaderParameter("Roughness", Variant(Config.RubberRoughness))

    if blockType == Config.BLOCK_ENERGY_PAD then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.1, 0.25, 0.3)))
    elseif blockType == Config.BLOCK_SPAWN then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.05, 0.2, 0.05)))
    elseif blockType == Config.BLOCK_CHECKPOINT then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.35, 0.15, 0.50)))
    elseif Config.SpawnBlockEmissive[blockType] then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Config.SpawnBlockEmissive[blockType]))
    else
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(color.r * 0.15, color.g * 0.15, color.b * 0.15)))
    end

    return mat
end

-- ============================================================================
-- 地图构建
-- ============================================================================

--- 构建地图（生成 grid 数据，创建初始可见区域节点）
---@param seed number|nil 随机种子
function Map.Build(seed)
    Map.Clear()

    -- 生成网格数据（程序化大世界）
    grid_ = MapData.Generate(seed)

    -- 创建地图父节点（LOCAL 防止服务端场景复制到客户端）
    mapRoot_ = scene_:CreateChild("MapRoot", LOCAL)

    -- 初始化节点数组（全部为 nil）
    blockNodes_ = {}
    for y = 1, MapData.Height do
        blockNodes_[y] = {}
    end

    -- 清空重生列表
    destroyed_ = {}
    debris_ = {}
    respawnAnims_ = {}

    -- 重置可见范围
    visibleMinY_ = 0
    visibleMaxY_ = 0

    if skipVisuals_ then
        -- 服务端：创建全部物理碰撞节点（服务端不做分块，需要全地图碰撞）
        local blockCount = 0
        for y = 1, MapData.Height do
            for x = 1, MapData.Width do
                local blockType = grid_[y][x]
                if blockType ~= Config.BLOCK_EMPTY then
                    local node = Map.CreateBlockNode(mapRoot_, x, y, blockType)
                    blockNodes_[y][x] = node
                    blockCount = blockCount + 1
                end
            end
        end
        visibleMinY_ = 1
        visibleMaxY_ = MapData.Height
        print("[Map] Server built " .. blockCount .. " collision blocks")
    else
        -- 客户端：初始可见区域从底部开始
        Map.UpdateVisibleChunk(5.0)  -- 初始相机在底部附近
        print("[Map] Client ready, chunk rendering enabled (buffer=" .. Config.ChunkRenderBuffer .. "m)")
    end
end

--- 创建单个方块节点（使用圆角矩形 CustomGeometry）
---@param parent Node
---@param gx number 网格 X（1-based）
---@param gy number 网格 Y（1-based）
---@param blockType number
---@return Node
function Map.CreateBlockNode(parent, gx, gy, blockType)
    local bs = Config.BlockSize
    local wx = (gx - 1) * bs + bs * 0.5
    local wy = (gy - 1) * bs + bs * 0.5

    local node = parent:CreateChild("Block_" .. gx .. "_" .. gy, LOCAL)
    node.position = Vector3(wx, wy, 0)

    -- 视觉组件（服务端跳过）
    if not skipVisuals_ then
        local geom = node:CreateComponent("CustomGeometry", LOCAL)
        buildRoundedBox(geom, bs, 0.1)
        geom.castShadows = true

        local mat = materialCache_[blockType]
        if mat then
            geom:SetMaterial(mat)
        end

        -- 描边子节点
        local outlineNode = node:CreateChild("Outline", LOCAL)
        outlineNode.position = Vector3(0, 0, 0.1)
        outlineNode.scale = Vector3(1.12, 1.12, 1.0)
        local outlineGeom = outlineNode:CreateComponent("CustomGeometry", LOCAL)
        buildRoundedBox(outlineGeom, bs, 0.1)
        outlineGeom.castShadows = false
        if outlineMat_ then
            outlineGeom:SetMaterial(outlineMat_)
        end
    end

    -- 物理碰撞（静态刚体，mass=0）- 客户端跳过
    if not skipPhysics_ then
        local body = node:CreateComponent("RigidBody", LOCAL)
        body.collisionLayer = 1

        local shape = node:CreateComponent("CollisionShape", LOCAL)
        shape:SetBox(Vector3(bs, bs, bs))
    end

    return node
end

-- ============================================================================
-- 分块渲染（客户端专用）
-- ============================================================================

local chunkDiagFirstCall_ = true

--- 更新可见区域（根据相机 Y 位置，创建/移除方块节点）
--- 应在每帧或相机移动后调用
---@param cameraY number 相机中心世界 Y 坐标
function Map.UpdateVisibleChunk(cameraY)
    if skipVisuals_ then return end  -- 服务端不分块
    if not mapRoot_ then
        if chunkDiagFirstCall_ then
            chunkDiagFirstCall_ = false
            print("[Map.DIAG] UpdateVisibleChunk called but mapRoot_ is nil!")
        end
        return
    end

    local buffer = Config.ChunkRenderBuffer
    local bs = Config.BlockSize

    -- 计算新的可见行范围
    local newMinY = math.max(1, math.floor((cameraY - buffer) / bs) + 1)
    local newMaxY = math.min(MapData.Height, math.ceil((cameraY + buffer) / bs) + 1)

    -- 首次调用诊断
    if chunkDiagFirstCall_ then
        chunkDiagFirstCall_ = false
        local gridRows = 0
        for _ in pairs(grid_) do gridRows = gridRows + 1 end
        print(string.format(
            "[Map.DIAG] UpdateVisibleChunk FIRST CALL: cameraY=%.1f range=[%d,%d] gridRows=%d skipVisuals=%s mapRoot=%s",
            cameraY, newMinY, newMaxY, gridRows, tostring(skipVisuals_), tostring(mapRoot_ ~= nil)))
    end

    -- 如果范围没有变化，跳过
    if newMinY == visibleMinY_ and newMaxY == visibleMaxY_ then
        return
    end

    -- 移除超出新范围的行
    for y = visibleMinY_, visibleMaxY_ do
        if y < newMinY or y > newMaxY then
            -- 这些行不再可见，移除节点
            if blockNodes_[y] then
                for x = 1, MapData.Width do
                    if blockNodes_[y][x] then
                        blockNodes_[y][x]:Remove()
                        blockNodes_[y][x] = nil
                    end
                end
            end
        end
    end

    -- 创建新进入可见范围的行
    for y = newMinY, newMaxY do
        if y < visibleMinY_ or y > visibleMaxY_ or visibleMinY_ == 0 then
            -- 新进入可见范围的行
            if not blockNodes_[y] then
                blockNodes_[y] = {}
            end
            for x = 1, MapData.Width do
                local blockType = grid_[y] and grid_[y][x] or Config.BLOCK_EMPTY
                if blockType ~= Config.BLOCK_EMPTY and not blockNodes_[y][x] then
                    -- 检查是否被破坏（还在重生计时中）
                    local key = x .. "_" .. y
                    if not destroyed_[key] then
                        blockNodes_[y][x] = Map.CreateBlockNode(mapRoot_, x, y, blockType)
                    end
                end
            end
        end
    end

    visibleMinY_ = newMinY
    visibleMaxY_ = newMaxY
end

-- ============================================================================
-- 运行时操作
-- ============================================================================

--- 每帧更新（处理方块重生 + 碎片动画）
---@param dt number
function Map.Update(dt)
    -- 方块重生
    local toRespawn = {}
    for key, info in pairs(destroyed_) do
        info.timer = info.timer - dt
        if info.timer <= 0 then
            table.insert(toRespawn, key)
        end
    end
    for _, key in ipairs(toRespawn) do
        local info = destroyed_[key]
        if info then
            Map.RespawnBlock(info.x, info.y, info.blockType)
            destroyed_[key] = nil
        end
    end

    -- 视觉动画（服务端跳过）
    if not skipVisuals_ then
        Map.UpdateDebris(dt)
        Map.UpdateRespawnAnims(dt)
    end
end

--- 更新飞散方块动画（整块坠落，不缩小）
---@param dt number
function Map.UpdateDebris(dt)
    local gravity = -25.0
    local i = 1
    while i <= #debris_ do
        local d = debris_[i]

        d.velY = d.velY + gravity * dt

        if d.node then
            local pos = d.node.position
            d.node.position = Vector3(pos.x + d.velX * dt, pos.y + d.velY * dt, pos.z)

            local rot = d.node.rotation
            d.node.rotation = rot * Quaternion(d.rotSpeed * dt, Vector3(d.rotAxisX, d.rotAxisY, d.rotAxisZ))
        end

        if d.node and d.node.position.y < Config.DeathY - 10 then
            d.node:Remove()
            table.remove(debris_, i)
        else
            i = i + 1
        end
    end
end

--- 更新重生缩放动画
---@param dt number
function Map.UpdateRespawnAnims(dt)
    local i = 1
    while i <= #respawnAnims_ do
        local a = respawnAnims_[i]
        a.timer = a.timer + dt
        local t = a.timer / a.duration
        if t >= 1.0 then
            if a.node then
                a.node.scale = Vector3(1, 1, 1)
            end
            table.remove(respawnAnims_, i)
        else
            local s = 1.0 - (1.0 - t) * (1.0 - t)
            s = s + math.sin(s * math.pi) * 0.12
            if a.node then
                a.node.scale = Vector3(s, s, s)
            end
            i = i + 1
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

    local centerWX, centerWY = Map.GridToWorld(centerGX, centerGY)

    for dy = -radius, radius do
        for dx = -radius, radius do
            local gx = centerGX + dx
            local gy = centerGY + dy
            if dx * dx + dy * dy <= radiusSq then
                if Map.DestroyBlock(gx, gy, centerWX, centerWY) then
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

--- 破坏指定方块（整块炸飞）
---@param gx number
---@param gy number
---@param explodeCX number|nil 爆炸中心世界 X（nil 时直接向上飞）
---@param explodeCY number|nil 爆炸中心世界 Y
---@return boolean 是否成功破坏
function Map.DestroyBlock(gx, gy, explodeCX, explodeCY)
    if gx < 1 or gx > MapData.Width or gy < 1 or gy > MapData.Height then
        return false
    end

    local blockType = grid_[gy][gx]

    -- 使用 Config.IsIndestructible 判断不可破坏方块
    if blockType == Config.BLOCK_EMPTY or Config.IsIndestructible(blockType) then
        return false
    end

    -- 处理节点
    if blockNodes_[gy] and blockNodes_[gy][gx] then
        local origNode = blockNodes_[gy][gx]

        if skipVisuals_ then
            origNode:Remove()
        else
            -- 客户端/单机：把原节点变成飞散碎片
            local body = origNode:GetComponent("RigidBody")
            if body then origNode:RemoveComponent(body) end
            local shape = origNode:GetComponent("CollisionShape")
            if shape then origNode:RemoveComponent(shape) end

            local pos = origNode.position
            local dirX, dirY = 0, 1
            if explodeCX and explodeCY then
                dirX = pos.x - explodeCX
                dirY = pos.y - explodeCY
                local len = math.sqrt(dirX * dirX + dirY * dirY)
                if len > 0.01 then
                    dirX = dirX / len
                    dirY = dirY / len
                else
                    dirX = 0
                    dirY = 1
                end
            end

            local baseSpeed = 5.0 + math.random() * 4.0
            local spreadAngle = (math.random() - 0.5) * 0.8
            local cosA = math.cos(spreadAngle)
            local sinA = math.sin(spreadAngle)
            local vx = (dirX * cosA - dirY * sinA) * baseSpeed
            local vy = (dirX * sinA + dirY * cosA) * baseSpeed + 2.0

            table.insert(debris_, {
                node = origNode,
                velX = vx,
                velY = vy,
                rotSpeed = 120 + math.random() * 240,
                rotAxisX = 0,
                rotAxisY = 0,
                rotAxisZ = 1,
            })
        end

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

--- 重生方块（带从小变大的缩放动效）
---@param gx number
---@param gy number
---@param blockType number
function Map.RespawnBlock(gx, gy, blockType)
    if gx < 1 or gx > MapData.Width or gy < 1 or gy > MapData.Height then
        return
    end

    -- 恢复网格数据
    grid_[gy][gx] = blockType

    -- 只有在可见范围内才创建节点
    if mapRoot_ and gy >= visibleMinY_ and gy <= visibleMaxY_ then
        local node = Map.CreateBlockNode(mapRoot_, gx, gy, blockType)
        if not blockNodes_[gy] then
            blockNodes_[gy] = {}
        end
        blockNodes_[gy][gx] = node

        if not skipVisuals_ then
            node.scale = Vector3(0.01, 0.01, 0.01)
            table.insert(respawnAnims_, {
                node = node,
                timer = 0,
                duration = 0.3,
            })
        end
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
---@return table
local destroyedBlocksCache_ = {}
function Map.GetDestroyedBlocks()
    local idx = 0
    for _, info in pairs(destroyed_) do
        idx = idx + 1
        local entry = destroyedBlocksCache_[idx]
        if not entry then
            entry = { x = 0, y = 0, timer = 0, totalTime = 0 }
            destroyedBlocksCache_[idx] = entry
        end
        entry.x = info.x
        entry.y = info.y
        entry.timer = info.timer
        entry.totalTime = Config.PlatformRespawnTime
    end
    for i = idx + 1, #destroyedBlocksCache_ do
        destroyedBlocksCache_[i] = nil
    end
    return destroyedBlocksCache_
end

--- 清除全部地图
function Map.Clear()
    if mapRoot_ then
        mapRoot_:Remove()
        mapRoot_ = nil
    end
    grid_ = {}
    blockNodes_ = {}
    destroyed_ = {}
    debris_ = {}
    respawnAnims_ = {}
    visibleMinY_ = 0
    visibleMaxY_ = 0
end

--- 重置地图（回到完整状态）
---@param seed number|nil
function Map.Reset(seed)
    Map.Build(seed)
end

-- ============================================================================
-- 编辑器支持 API
-- ============================================================================

--- 获取当前 grid 引用
---@return table
function Map.GetGrid()
    return grid_
end

--- 获取地图尺寸
---@return number, number  -- width, height
function Map.GetDimensions()
    return MapData.Width, MapData.Height
end

--- 在指定网格位置放置方块（编辑器用）
---@param gx number
---@param gy number
---@param blockType number
function Map.SetBlock(gx, gy, blockType)
    if gx < 1 or gx > MapData.Width or gy < 1 or gy > MapData.Height then
        return
    end

    Map.RemoveBlock(gx, gy)

    grid_[gy][gx] = blockType

    if blockType == Config.BLOCK_EMPTY then
        return
    end

    -- 只有在可见范围内才创建节点
    if mapRoot_ and gy >= visibleMinY_ and gy <= visibleMaxY_ then
        local node = Map.CreateBlockNode(mapRoot_, gx, gy, blockType)
        if not blockNodes_[gy] then blockNodes_[gy] = {} end
        blockNodes_[gy][gx] = node
    end
end

--- 移除指定网格位置的方块（编辑器用）
---@param gx number
---@param gy number
function Map.RemoveBlock(gx, gy)
    if gx < 1 or gx > MapData.Width or gy < 1 or gy > MapData.Height then
        return
    end

    if blockNodes_[gy] and blockNodes_[gy][gx] then
        blockNodes_[gy][gx]:Remove()
        blockNodes_[gy][gx] = nil
    end

    if grid_[gy] then
        grid_[gy][gx] = Config.BLOCK_EMPTY
    end
end

--- 从外部 grid 数据重建整个地图（编辑器加载用）
---@param externalGrid table
function Map.BuildFromGrid(externalGrid)
    Map.Clear()

    grid_ = {}
    for y = 1, MapData.Height do
        grid_[y] = {}
        for x = 1, MapData.Width do
            grid_[y][x] = (externalGrid[y] and externalGrid[y][x]) or Config.BLOCK_EMPTY
        end
    end

    mapRoot_ = scene_:CreateChild("MapRoot", LOCAL)
    blockNodes_ = {}
    for y = 1, MapData.Height do
        blockNodes_[y] = {}
    end

    destroyed_ = {}
    debris_ = {}
    respawnAnims_ = {}
    visibleMinY_ = 0
    visibleMaxY_ = 0

    -- 初始渲染底部区域
    Map.UpdateVisibleChunk(5.0)

    local blockCount = 0
    for y = 1, MapData.Height do
        for x = 1, MapData.Width do
            if grid_[y][x] ~= Config.BLOCK_EMPTY then
                blockCount = blockCount + 1
            end
        end
    end
    print("[Map] Built from external grid: " .. blockCount .. " total blocks (chunk rendering active)")
end

return Map

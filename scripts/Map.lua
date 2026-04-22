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

-- 飞散碎片列表：{ node, velX, velY, rotSpeed, life }
local debris_ = {}

-- 重生缩放动画列表：{ node, timer, duration }
local respawnAnims_ = {}

-- 网络模式：服务端跳过视觉组件
local skipVisuals_ = false

--- 设置是否跳过视觉组件（必须在 Init 之前调用）
---@param skip boolean
function Map.SetSkipVisuals(skip)
    skipVisuals_ = skip
    print("[Map] Skip visuals set to: " .. tostring(skip))
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
    r = math.min(r, h * 0.5)  -- 圆角最大不超过半边长的一半
    local segs = 4  -- 每个圆角分段数

    -- 面定义：法线方向, 四个角的偏移轴（两个向量构成面内的基）
    -- 圆角只作用在正面和背面（Z 方向），侧面保持锐边即可
    -- 简化方案：6 个面，正面/背面做圆角轮廓拉伸，四个侧面仍然是平面

    geom:SetNumGeometries(1)
    geom:BeginGeometry(0, TRIANGLE_LIST)

    -- 辅助：添加一个三角形（3 个顶点）
    local function tri(p1, p2, p3, n)
        geom:DefineVertex(p1)
        geom:DefineNormal(n)
        geom:DefineVertex(p2)
        geom:DefineNormal(n)
        geom:DefineVertex(p3)
        geom:DefineNormal(n)
    end

    -- 辅助：添加一个四边形（2 个三角形）
    local function quad(p1, p2, p3, p4, n)
        tri(p1, p2, p3, n)
        tri(p1, p3, p4, n)
    end

    -- 生成圆角轮廓顶点（2D，在 XY 平面）
    -- 从右上角开始，逆时针
    local function roundedRectVerts()
        local verts = {}
        -- 4 个角的圆心位置
        local corners = {
            { x =  h - r, y =  h - r },  -- 右上
            { x = -h + r, y =  h - r },  -- 左上
            { x = -h + r, y = -h + r },  -- 左下
            { x =  h - r, y = -h + r },  -- 右下
        }
        -- 每个角的起始角度
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

    -- =========== 正面（Z+）===========
    local nFront = Vector3(0, 0, 1)
    -- 三角扇：中心点 + 轮廓
    local center = Vector3(0, 0, frontZ)
    for i = 1, nv do
        local j = (i % nv) + 1
        local p1 = Vector3(outline[i].x, outline[i].y, frontZ)
        local p2 = Vector3(outline[j].x, outline[j].y, frontZ)
        tri(center, p1, p2, nFront)
    end

    -- =========== 背面（Z-）===========
    local nBack = Vector3(0, 0, -1)
    local centerB = Vector3(0, 0, backZ)
    for i = 1, nv do
        local j = (i % nv) + 1
        local p1 = Vector3(outline[i].x, outline[i].y, backZ)
        local p2 = Vector3(outline[j].x, outline[j].y, backZ)
        tri(centerB, p2, p1, nBack)  -- 反向绕序
    end

    -- =========== 侧面（连接正面和背面轮廓）===========
    for i = 1, nv do
        local j = (i % nv) + 1
        local v1 = outline[i]
        local v2 = outline[j]

        local f1 = Vector3(v1.x, v1.y, frontZ)
        local f2 = Vector3(v2.x, v2.y, frontZ)
        local b1 = Vector3(v1.x, v1.y, backZ)
        local b2 = Vector3(v2.x, v2.y, backZ)

        -- 计算侧面法线（沿轮廓边的外法线）
        local dx = v2.x - v1.x
        local dy = v2.y - v1.y
        local len = math.sqrt(dx * dx + dy * dy)
        local nx, ny = dy / len, -dx / len  -- 外法线（逆时针轮廓的外法线）
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
        -- 缓存模型和技术
        boxModel_ = cache:GetResource("Model", "Models/Box.mdl")
        pbrTechnique_ = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")

        -- 预创建材质
        for blockType, color in pairs(Config.BlockColors) do
            materialCache_[blockType] = Map.CreateBlockMaterial(color, blockType)
        end

        -- 创建描边材质（深棕色，哑光）
        outlineMat_ = Material:new()
        outlineMat_:SetTechnique(0, pbrTechnique_)
        outlineMat_:SetShaderParameter("MatDiffColor", Variant(Config.BlockOutlineColor))
        outlineMat_:SetShaderParameter("Metallic", Variant(0.0))
        outlineMat_:SetShaderParameter("Roughness", Variant(1.0))
    end

    print("[Map] Initialized (skipVisuals=" .. tostring(skipVisuals_) .. ")")
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

    -- 特殊方块的自发光
    if blockType == Config.BLOCK_ENERGY_PAD then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.1, 0.25, 0.3)))
    elseif blockType == Config.BLOCK_SPAWN then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.05, 0.2, 0.05)))
    elseif blockType == Config.BLOCK_FINISH then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.6, 0.5, 0.05)))
    elseif Config.SpawnBlockEmissive[blockType] then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Config.SpawnBlockEmissive[blockType]))
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
    debris_ = {}

    print("[Map] Built " .. blockCount .. " blocks (" .. MapData.Width .. "x" .. MapData.Height .. ")")
end

--- 创建单个方块节点（使用圆角矩形 CustomGeometry）
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

    -- 视觉组件（服务端跳过）
    if not skipVisuals_ then
        -- 使用 CustomGeometry 创建圆角方块
        local geom = node:CreateComponent("CustomGeometry")
        buildRoundedBox(geom, bs, 0.1)  -- 0.1 米圆角半径（微妙圆角）
        geom.castShadows = true

        local mat = materialCache_[blockType]
        if mat then
            geom:SetMaterial(mat)
        end

        -- 描边子节点（在方块后面 Z+0.1，略大）
        local outlineNode = node:CreateChild("Outline")
        outlineNode.position = Vector3(0, 0, 0.1)
        outlineNode.scale = Vector3(1.12, 1.12, 1.0)
        local outlineGeom = outlineNode:CreateComponent("CustomGeometry")
        buildRoundedBox(outlineGeom, bs, 0.1)
        outlineGeom.castShadows = false
        if outlineMat_ then
            outlineGeom:SetMaterial(outlineMat_)
        end

        -- 终点方块：添加旗帜视觉效果（旗杆+三角旗）
        if blockType == Config.BLOCK_FINISH then
            Map.CreateFlag(node, bs)
        end
    end

    -- 物理碰撞（静态刚体，mass=0）- 碰撞形状仍是方盒（简化物理）
    local body = node:CreateComponent("RigidBody")
    body.collisionLayer = 1

    local shape = node:CreateComponent("CollisionShape")
    shape:SetBox(Vector3(bs, bs, bs))

    return node
end

--- 在终点方块上方创建旗帜（旗杆+三角旗）
---@param parentNode Node 终点方块节点
---@param bs number 方块边长
function Map.CreateFlag(parentNode, bs)
    local halfBS = bs * 0.5

    -- 旗杆（细长圆柱）
    local poleNode = parentNode:CreateChild("FlagPole")
    local poleHeight = bs * 2.0
    local poleRadius = bs * 0.04
    poleNode.position = Vector3(0, halfBS + poleHeight * 0.5, -0.05)
    poleNode.scale = Vector3(poleRadius * 2, poleHeight, poleRadius * 2)
    local poleModel = poleNode:CreateComponent("StaticModel")
    poleModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    -- 白色旗杆
    local poleMat = Material:new()
    poleMat:SetTechnique(0, pbrTechnique_)
    poleMat:SetShaderParameter("MatDiffColor", Variant(Color(0.95, 0.95, 0.95)))
    poleMat:SetShaderParameter("Metallic", Variant(0.6))
    poleMat:SetShaderParameter("Roughness", Variant(0.3))
    poleModel:SetMaterial(poleMat)

    -- 三角旗（使用 CustomGeometry）
    local flagNode = parentNode:CreateChild("Flag")
    flagNode.position = Vector3(0, halfBS + poleHeight * 0.75, -0.06)
    local flagGeom = flagNode:CreateComponent("CustomGeometry")
    flagGeom:SetNumGeometries(1)
    flagGeom:BeginGeometry(0, TRIANGLE_LIST)

    -- 三角旗尺寸
    local flagW = bs * 0.7   -- 旗帜宽度（向右伸出）
    local flagH = bs * 0.5   -- 旗帜高度

    -- 正面三角形（右侧展开）
    local p1 = Vector3(0, flagH * 0.5, 0)            -- 左上（旗杆顶部附近）
    local p2 = Vector3(0, -flagH * 0.5, 0)           -- 左下
    local p3 = Vector3(flagW, 0, 0)                   -- 右侧尖端
    local nF = Vector3(0, 0, -1)

    flagGeom:DefineVertex(p1)
    flagGeom:DefineNormal(nF)
    flagGeom:DefineVertex(p2)
    flagGeom:DefineNormal(nF)
    flagGeom:DefineVertex(p3)
    flagGeom:DefineNormal(nF)

    -- 背面三角形（反转绕序）
    local nB = Vector3(0, 0, 1)
    flagGeom:DefineVertex(p1)
    flagGeom:DefineNormal(nB)
    flagGeom:DefineVertex(p3)
    flagGeom:DefineNormal(nB)
    flagGeom:DefineVertex(p2)
    flagGeom:DefineNormal(nB)

    flagGeom:Commit()

    -- 旗帜材质：金色/黄色，高发光
    local flagMat = Material:new()
    flagMat:SetTechnique(0, pbrTechnique_)
    flagMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.85, 0.1)))
    flagMat:SetShaderParameter("Metallic", Variant(0.1))
    flagMat:SetShaderParameter("Roughness", Variant(0.6))
    flagMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.4, 0.02)))
    flagGeom:SetMaterial(flagMat)
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
        -- 更新飞散碎片
        Map.UpdateDebris(dt)

        -- 更新重生缩放动画
        Map.UpdateRespawnAnims(dt)
    end
end

--- 更新飞散方块动画（整块坠落，不缩小）
---@param dt number
function Map.UpdateDebris(dt)
    local gravity = -25.0  -- 重力加速度
    local i = 1
    while i <= #debris_ do
        local d = debris_[i]

        -- 速度更新（重力）
        d.velY = d.velY + gravity * dt

        -- 位置更新
        if d.node then
            local pos = d.node.position
            d.node.position = Vector3(pos.x + d.velX * dt, pos.y + d.velY * dt, pos.z)

            -- 旋转
            local rot = d.node.rotation
            d.node.rotation = rot * Quaternion(d.rotSpeed * dt, Vector3(d.rotAxisX, d.rotAxisY, d.rotAxisZ))
        end

        -- 移除条件：掉出屏幕足够远
        if d.node and d.node.position.y < Config.DeathY - 10 then
            d.node:Remove()
            table.remove(debris_, i)
        else
            i = i + 1
        end
    end
end

--- 更新重生缩放动画（从小变大，ease-out 曲线）
---@param dt number
function Map.UpdateRespawnAnims(dt)
    local i = 1
    while i <= #respawnAnims_ do
        local a = respawnAnims_[i]
        a.timer = a.timer + dt
        local t = a.timer / a.duration
        if t >= 1.0 then
            -- 动画完成，设为标准尺寸
            if a.node then
                a.node.scale = Vector3(1, 1, 1)
            end
            table.remove(respawnAnims_, i)
        else
            -- ease-out-back 曲线：先超过 1 再回弹，产生弹性感
            local s = 1.0 - (1.0 - t) * (1.0 - t)  -- ease-out-quad 基础
            s = s + math.sin(s * math.pi) * 0.12     -- 微妙回弹
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

    -- 计算爆炸中心世界坐标
    local centerWX, centerWY = Map.GridToWorld(centerGX, centerGY)

    for dy = -radius, radius do
        for dx = -radius, radius do
            local gx = centerGX + dx
            local gy = centerGY + dy
            -- 圆形范围判定
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

    -- 只能破坏普通方块和能量托台（出生点、安全、终点不可破坏）
    if blockType ~= Config.BLOCK_NORMAL and blockType ~= Config.BLOCK_ENERGY_PAD then
        return false
    end

    -- 处理节点
    if blockNodes_[gy] and blockNodes_[gy][gx] then
        local origNode = blockNodes_[gy][gx]

        if skipVisuals_ then
            -- 服务端：直接移除节点，不做碎片动画
            origNode:Remove()
        else
            -- 客户端/单机：把原节点变成飞散碎片
            -- 移除物理组件，让方块不再参与碰撞
            local body = origNode:GetComponent("RigidBody")
            if body then origNode:RemoveComponent(body) end
            local shape = origNode:GetComponent("CollisionShape")
            if shape then origNode:RemoveComponent(shape) end

            -- 计算飞散方向：从爆炸中心指向方块
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

            -- 飞散速度 + 随机扩散
            local baseSpeed = 5.0 + math.random() * 4.0
            local spreadAngle = (math.random() - 0.5) * 0.8
            local cosA = math.cos(spreadAngle)
            local sinA = math.sin(spreadAngle)
            local vx = (dirX * cosA - dirY * sinA) * baseSpeed
            local vy = (dirX * sinA + dirY * cosA) * baseSpeed + 2.0  -- 稍微向上抛

            table.insert(debris_, {
                node = origNode,
                velX = vx,
                velY = vy,
                -- 只绕 Z 轴旋转，保持 2D 平面感
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

    -- 创建新节点
    local mapRoot = scene_:GetChild("MapRoot")
    if mapRoot then
        local node = Map.CreateBlockNode(mapRoot, gx, gy, blockType)
        if not blockNodes_[gy] then
            blockNodes_[gy] = {}
        end
        blockNodes_[gy][gx] = node

        -- 缩放动画（服务端跳过）
        if not skipVisuals_ then
            -- 初始缩放为 0，启动缩放动画
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
    debris_ = {}
    respawnAnims_ = {}
end

--- 重置地图（回到完整状态）
function Map.Reset()
    Map.Build()
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

    -- 先移除已有方块
    Map.RemoveBlock(gx, gy)

    -- 更新 grid
    grid_[gy][gx] = blockType

    if blockType == Config.BLOCK_EMPTY then
        return
    end

    -- 创建新方块节点
    local mapRoot = scene_:GetChild("MapRoot")
    if mapRoot then
        local node = Map.CreateBlockNode(mapRoot, gx, gy, blockType)
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

    -- 移除节点
    if blockNodes_[gy] and blockNodes_[gy][gx] then
        blockNodes_[gy][gx]:Remove()
        blockNodes_[gy][gx] = nil
    end

    -- 更新 grid
    if grid_[gy] then
        grid_[gy][gx] = Config.BLOCK_EMPTY
    end
end

--- 从外部 grid 数据重建整个地图（编辑器加载用）
---@param externalGrid table
function Map.BuildFromGrid(externalGrid)
    Map.Clear()

    -- 创建空 grid 并复制数据
    grid_ = {}
    for y = 1, MapData.Height do
        grid_[y] = {}
        for x = 1, MapData.Width do
            grid_[y][x] = (externalGrid[y] and externalGrid[y][x]) or Config.BLOCK_EMPTY
        end
    end

    -- 创建地图父节点
    local mapRoot = scene_:CreateChild("MapRoot")
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

    destroyed_ = {}
    debris_ = {}

    print("[Map] Built from external grid: " .. blockCount .. " blocks")
end

return Map

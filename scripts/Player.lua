-- ============================================================================
-- Player.lua - 玩家实体系统
-- 管理：移动/跳跃/冲刺/能量/爆炸/死亡/重生
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local SFX = require("SFX")
local Camera = require("Camera")

local Player = {}

-- 所有玩家实例
Player.list = {}

-- 引用（由 main 注入）
---@type Scene
local scene_ = nil
local mapModule_ = nil  -- Map 模块引用

-- PBR 技术缓存
local pbrTechnique_ = nil
local pbrAlphaTechnique_ = nil

-- 网络模式："standalone" | "server" | "client"
local networkMode_ = "standalone"

--- 设置网络模式（必须在 Init 之前调用）
---@param mode string "standalone"|"server"|"client"
function Player.SetNetworkMode(mode)
    networkMode_ = mode
    print("[Player] Network mode set to: " .. mode)
end

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化玩家系统
---@param scene Scene
---@param mapRef table  Map 模块引用
function Player.Init(scene, mapRef)
    scene_ = scene
    mapModule_ = mapRef
    pbrTechnique_ = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")
    pbrAlphaTechnique_ = cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml")
    Player.list = {}
    print("[Player] Initialized")
end

--- 在节点上创建视觉组件（模型、描边、眼睛）
--- 用于单机模式的 Create 以及客户端的延迟挂载
---@param node Node 父节点
---@param index number 玩家编号 1~4
---@return Node visualNode, Material mat, Material outlineMat
function Player.CreateVisuals(node, index)
    -- 关键：所有视觉子节点用 LOCAL 模式创建
    -- 在 REPLICATED 父节点（Player_N）下若用默认 REPLICATED 模式，
    -- 客户端创建的子节点会与服务端节点同步逻辑产生 hash 冲突，导致视觉随机消失
    local visualNode = node:CreateChild("Visual", LOCAL)
    visualNode.scale = Vector3(0.9, 0.9, 0.9)

    -- 方块外观（圆角矩形）
    local geom = visualNode:CreateComponent("CustomGeometry", LOCAL)
    mapModule_.BuildRoundedBox(geom, Config.BlockSize, 0.1)
    geom.castShadows = true

    local mat = Material:new()
    mat:SetTechnique(0, pbrTechnique_)
    mat:SetShaderParameter("MatDiffColor", Variant(Config.PlayerColors[index]))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Config.PlayerEmissive[index]))
    mat:SetShaderParameter("Metallic", Variant(Config.RubberMetallic))
    mat:SetShaderParameter("Roughness", Variant(Config.RubberRoughness))
    geom:SetMaterial(mat)

    -- 描边子节点（LOCAL，避免与服务端节点同步冲突）
    local outlineNode = visualNode:CreateChild("Outline", LOCAL)
    outlineNode.position = Vector3(0, 0, 0.1)
    outlineNode.scale = Vector3(1.15, 1.15, 1.0)
    local outlineGeom = outlineNode:CreateComponent("CustomGeometry", LOCAL)
    mapModule_.BuildRoundedBox(outlineGeom, Config.BlockSize, 0.1)
    outlineGeom.castShadows = false
    local outlineMat = Material:new()
    outlineMat:SetTechnique(0, pbrTechnique_)
    outlineMat:SetShaderParameter("MatDiffColor", Variant(Config.PlayerOutlineColors[index]))
    outlineMat:SetShaderParameter("Metallic", Variant(0.0))
    outlineMat:SetShaderParameter("Roughness", Variant(1.0))
    outlineGeom:SetMaterial(outlineMat)

    -- 眼睛
    local sphereModel = cache:GetResource("Model", "Models/Sphere.mdl")
    local unlitTechnique = cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml")
    local eyeMat = Material:new()
    eyeMat:SetTechnique(0, unlitTechnique)
    eyeMat:SetShaderParameter("MatDiffColor", Variant(Config.PlayerOutlineColors[index]))

    local eyeBaseX = 0.16
    local eyeBaseY = 0.06
    local eyeBaseZ = -0.48
    local eyeRadius = 0.22

    local eyeL = visualNode:CreateChild("EyeL", LOCAL)
    eyeL.position = Vector3(-eyeBaseX, eyeBaseY, eyeBaseZ)
    eyeL.scale = Vector3(eyeRadius, eyeRadius, eyeRadius * 0.35)
    local eyeLModel = eyeL:CreateComponent("StaticModel", LOCAL)
    eyeLModel.model = sphereModel
    eyeLModel.castShadows = false
    eyeLModel:SetMaterial(eyeMat)

    local eyeR = visualNode:CreateChild("EyeR", LOCAL)
    eyeR.position = Vector3(eyeBaseX, eyeBaseY, eyeBaseZ)
    eyeR.scale = Vector3(eyeRadius, eyeRadius, eyeRadius * 0.35)
    local eyeRModel = eyeR:CreateComponent("StaticModel", LOCAL)
    eyeRModel.model = sphereModel
    eyeRModel.castShadows = false
    eyeRModel:SetMaterial(eyeMat)

    return visualNode, mat, outlineMat
end

--- 为已有玩家数据补挂视觉组件（客户端收到 REPLICATED 节点后调用）
---@param p table 玩家数据
function Player.AttachVisuals(p)
    if p.visualNode then return end  -- 已有视觉
    local visualNode, mat, outlineMat = Player.CreateVisuals(p.node, p.index)
    p.visualNode = visualNode
    p.material = mat
    p.outlineMat = outlineMat
    print("[Player] Visuals attached to player " .. p.index)
end

--- 创建一个玩家
---@param index number 玩家编号 1~4
---@param isHuman boolean 是否人类控制
---@param opts table|nil 可选参数 { existingNode=Node, skipVisuals=bool }
---@return table 玩家数据
function Player.Create(index, isHuman, opts)
    opts = opts or {}
    local spawnX, spawnY = MapData.GetSpawnPosition(index)

    local node
    if opts.existingNode then
        node = opts.existingNode
    elseif opts.nodeless then
        -- 客户端等待服务端 REPLICATED 节点到达期间的占位：不创建任何节点
        -- 节点会在 NodeAdded/ScanReplicatedNodes 中被赋值，并由 AttachVisuals 补挂视觉
        node = nil
    else
        -- 服务端：REPLICATED（默认），节点会同步到客户端，位置变化也会同步
        -- 单机：LOCAL
        local createMode = (networkMode_ == "server") and REPLICATED or LOCAL
        node = scene_:CreateChild("Player_" .. index, createMode)
        node.position = Vector3(spawnX, spawnY, 0)
    end

    -- 视觉组件（服务端跳过；nodeless 模式也跳过，等节点到位再 AttachVisuals）
    local visualNode = nil
    local mat = nil
    local outlineMat = nil
    local eyeBaseX = 0.16
    local eyeBaseY = 0.06
    local eyeBaseZ = -0.48
    local eyeRadius = 0.22

    if not opts.skipVisuals then
        visualNode, mat, outlineMat = Player.CreateVisuals(node, index)
    end

    -- 动态刚体（仅服务端/单机需要物理，客户端不创建——避免与服务端复制冲突）
    -- nodeless 模式：node 还未到位，物理设置全部跳过，等 NodeAdded 后再处理
    local body = nil
    if node and networkMode_ ~= "client" then
        -- 服务端：使用 LOCAL 标志创建物理组件，避免复制到客户端
        -- 单机：LOCAL 或 REPLICATED 都可以（无网络），统一用 LOCAL
        local createMode = LOCAL
        body = node:CreateComponent("RigidBody", createMode)
        body.mass = 1.0
        body.friction = 0.3
        body.linearDamping = 0.05
        body.collisionLayer = 2
        body.collisionMask = 0xFFFF
        body.collisionEventMode = COLLISION_ALWAYS

        -- 2.5D 约束：锁 Z 移动，锁全旋转
        body.linearFactor = Vector3(1, 1, 0)
        body.angularFactor = Vector3(0, 0, 0)

        local shape = node:CreateComponent("CollisionShape", createMode)
        shape:SetCapsule(0.9, 1.0)
    elseif node then
        -- 客户端：如果复制节点已带有物理组件（从服务端复制），移除它们
        -- 防止客户端本地物理模拟干扰服务端的位置同步
        local existingBody = node:GetComponent("RigidBody")
        if existingBody then
            node:RemoveComponent(existingBody)
            print("[Player] Removed replicated RigidBody from client player " .. index)
        end
        local existingShape = node:GetComponent("CollisionShape")
        if existingShape then
            node:RemoveComponent(existingShape)
            print("[Player] Removed replicated CollisionShape from client player " .. index)
        end
    end

    -- 玩家数据
    local p = {
        index = index,
        node = node,
        visualNode = visualNode,
        body = body,
        material = mat,
        outlineMat = outlineMat,
        isHuman = isHuman,

        -- 移动
        onGround = false,
        wasOnGround = false,   -- 上一帧是否在地面（用于着陆检测）
        hitCeiling = false,    -- 本帧是否撞到天花板
        hitWallX = 0,          -- 本帧撞墙方向：-1 左墙, 1 右墙, 0 无
        jumpCount = 0,
        prevVelY = 0,          -- 上一帧 Y 速度（用于计算落地冲击力）

        -- 土狼时间 & 跳跃缓冲
        coyoteTimer = 0,       -- 离开地面后的计时（<= CoyoteTime 时仍可跳）
        jumpBufferTimer = 0,   -- 按下跳跃后的计时（<= JumpBufferTime 时着地自动跳）

        -- 冲刺
        dashTimer = 0,        -- >0 表示冲刺中
        dashCooldown = 0,     -- 冲刺冷却计时
        dashDir = 1,          -- 冲刺方向 1/-1
        lastFaceDir = 1,      -- 最后面朝方向

        -- 能量
        energy = 0,

        -- 爆炸（蓄力机制）
        charging = false,       -- 是否在蓄力中
        chargeTimer = 0,        -- 蓄力计时（0→ChargeTime）
        chargeProgress = 0,     -- 蓄力进度（0→1）
        explodeRecovery = 0,    -- 爆炸后摇

        -- 生命状态
        alive = true,
        respawnTimer = 0,
        invincibleTimer = 0,

        -- 比赛
        finished = false,      -- 是否已到达终点
        finishOrder = 0,       -- 到达终点的名次

        -- 击杀统计（每回合重置）
        kills = 0,             -- 本回合击杀数
        killStreak = 0,        -- 连续击杀数（死亡重置）
        multiKillCount = 0,    -- 短时间内连续击杀数
        multiKillTimer = 0,    -- 连杀判定计时器

        -- 下砸
        slamming = false,      -- 是否正在下砸中
        slamLanded = false,    -- 下砸是否已着地（触发击退）
        slamRecovery = 0,      -- 下砸着地后摇

        -- 输入缓存（AI 或人类写入）
        inputMoveX = 0,
        inputJump = false,
        inputDash = false,
        inputSlam = false,           -- S键/↓键（下砸）
        inputCharging = false,       -- 右键按住中
        inputExplodeRelease = false, -- 右键松开（触发爆炸）
        wasChargingInput = false,    -- 上帧右键状态（用于松开检测）

        -- 视觉动效（squash & stretch）
        squashScaleX = 1.0,    -- 当前形变 X 比例
        squashScaleY = 1.0,    -- 当前形变 Y 比例
        squashVelX = 0,        -- 弹簧速度 X
        squashVelY = 0,        -- 弹簧速度 Y
        dashRoll = 0,          -- 冲刺旋转角度（度）

        -- 眼睛动画参数
        eyeOffsetX = 0,        -- 当前眼球水平偏移量
        eyeOffsetY = 0,        -- 当前眼球垂直偏移量
        eyeBaseX = eyeBaseX,   -- 眼睛基础水平距离
        eyeBaseY = eyeBaseY,   -- 眼睛基础垂直偏移
        eyeBaseZ = eyeBaseZ,   -- 眼睛基础Z
        eyeRadius = eyeRadius, -- 眼睛基础半径
        blinkTimer = 0,        -- 眨眼计时器
        blinkInterval = 3.0 + math.random() * 3.0,  -- 下次眨眼间隔（3~6秒随机）
        blinkPhase = 0,        -- 眨眼阶段进度 0~1
        isBlinking = false,    -- 是否在眨眼中
        idleTimer = 0,         -- 静止计时器
    }

    -- 注册碰撞回调（仅服务端/单机需要，客户端没有物理体无需碰撞检测）
    if networkMode_ ~= "client" then
        node:CreateScriptObject("PlayerCollision")
        local scriptObj = node:GetScriptObject()
        if scriptObj then
            scriptObj.playerData = p
        end
    end

    table.insert(Player.list, p)
    print("[Player] Created player " .. index .. (isHuman and " (human)" or " (AI)")
        .. " mode=" .. networkMode_
        .. " body=" .. tostring(p.body ~= nil)
        .. " visual=" .. tostring(p.visualNode ~= nil)
        .. " pos=" .. tostring(node.position))

    return p
end

--- 创建全部玩家
function Player.CreateAll()
    Player.list = {}
    -- 玩家1 是人类，其余是 AI
    for i = 1, Config.NumPlayers do
        Player.Create(i, i == 1)
    end
end

-- ============================================================================
-- 碰撞检测组件（ScriptObject）
-- ============================================================================

PlayerCollision = ScriptObject()

function PlayerCollision:Start()
    self.playerData = nil
    -- 每帧碰撞（用于地面检测）
    self:SubscribeToEvent(self.node, "NodeCollision", "PlayerCollision:HandleCollision")
end

function PlayerCollision:HandleCollision(eventType, eventData)
    if self.playerData == nil then return end
    if eventData["Trigger"]:GetBool() then return end

    local contacts = eventData["Contacts"]:GetBuffer()
    local foundGround = false
    local hitCeiling = false
    local hitWallX = 0

    while not contacts.eof do
        local contactPosition = contacts:ReadVector3()
        local contactNormal = contacts:ReadVector3()
        local contactDistance = contacts:ReadFloat()
        local contactImpulse = contacts:ReadFloat()

        -- 地面检测：法线向上 > 0.75
        if contactNormal.y > 0.75 then
            foundGround = true
        end
        -- 天花板检测：法线向下 < -0.75
        if contactNormal.y < -0.75 then
            hitCeiling = true
        end
        -- 墙壁检测：法线水平分量大，垂直分量小
        if math.abs(contactNormal.y) < 0.3 then
            if contactNormal.x > 0.5 then
                hitWallX = -1  -- 碰到左侧墙壁（法线朝右 = 撞左墙）
            elseif contactNormal.x < -0.5 then
                hitWallX = 1   -- 碰到右侧墙壁（法线朝左 = 撞右墙）
            end
        end
    end

    if foundGround then
        self.playerData.onGround = true
    end
    if hitCeiling then
        self.playerData.hitCeiling = true
    end
    if hitWallX ~= 0 then
        self.playerData.hitWallX = hitWallX
    end
end

-- ============================================================================
-- 更新
-- ============================================================================

--- 每帧更新所有玩家
---@param dt number
function Player.UpdateAll(dt)
    for _, p in ipairs(Player.list) do
        Player.UpdateOne(p, dt)
    end
end

--- 更新单个玩家
---@param p table
---@param dt number
function Player.UpdateOne(p, dt)
    if not p.alive then
        -- 死亡状态：等待重生
        p.respawnTimer = p.respawnTimer - dt
        if p.respawnTimer <= 0 then
            Player.Respawn(p)
        end
        -- 哭脸弹出动画（弹性缩放 0→过冲→稳定）
        if p.deathFacePlane and p.deathFaceTimer ~= nil then
            p.deathFaceTimer = p.deathFaceTimer + dt
            local dur = 0.2
            local t = math.min(p.deathFaceTimer / dur, 1.0)
            -- 弹性缓动：过冲后回弹
            local s
            if t < 1.0 then
                s = 1.0 - math.cos(t * math.pi * 0.5)  -- 先快速增长
                s = s + math.sin(t * math.pi * 2.5) * (1.0 - t) * 0.35  -- 弹性振荡
                s = s * 1.15  -- 过冲
            else
                s = 1.0
            end
            local sz = p.deathFaceTargetSize * s
            p.deathFacePlane.scale = Vector3(sz, 1.0, sz)
        end
        return
    end

    if p.finished then
        -- 已完成，不再更新移动
        return
    end

    -- =====================
    -- 土狼时间计时器
    -- =====================
    if p.onGround then
        p.coyoteTimer = 0  -- 在地面上时重置
    else
        p.coyoteTimer = p.coyoteTimer + dt  -- 离开地面后递增
    end

    -- =====================
    -- 跳跃缓冲计时器
    -- =====================
    if p.jumpBufferTimer > 0 then
        p.jumpBufferTimer = p.jumpBufferTimer - dt
    end
    -- 新的跳跃输入 → 设置缓冲
    if p.inputJump then
        p.jumpBufferTimer = Config.JumpBufferTime
        p.inputJump = false  -- 消费输入信号，后续由 buffer 驱动
    end

    -- =====================
    -- 着陆检测
    -- =====================
    if p.onGround and not p.wasOnGround then
        -- 刚着陆
        p.jumpCount = 0
        -- 落地压扁：根据落地前的下落速度决定压扁幅度
        local impactSpeed = math.abs(p.prevVelY)
        local squashAmount = math.min(impactSpeed / 30.0, 0.35)  -- 最多压扁 35%
        if squashAmount > 0.04 then
            p.squashScaleY = 1.0 - squashAmount       -- 压扁 Y
            p.squashScaleX = 1.0 + squashAmount * 0.6 -- 横向膨胀
            p.squashVelY = 0
            p.squashVelX = 0
        end

        -- 下砸着地：触发击退 + 后摇
        if p.slamming then
            p.slamming = false
            p.slamLanded = true
            p.slamRecovery = Config.SlamRecovery
            Player.DoSlamImpact(p)
            -- 更强的落地压扁
            p.squashScaleY = 0.55
            p.squashScaleX = 1.45
            p.squashVelY = 0
            p.squashVelX = 0
        end

        -- 着陆时检查跳跃缓冲：缓冲窗口内有按键 → 自动起跳
        if p.jumpBufferTimer > 0 and p.slamRecovery <= 0 then
            p.jumpBufferTimer = 0
            Player.DoJump(p)
        end
    end

    -- 连杀窗口计时递减
    if p.multiKillTimer > 0 then
        p.multiKillTimer = p.multiKillTimer - dt
        if p.multiKillTimer <= 0 then
            p.multiKillCount = 0
        end
    end

    -- 无敌计时
    if p.invincibleTimer > 0 then
        p.invincibleTimer = p.invincibleTimer - dt
        -- 闪烁效果（控制视觉子节点）
        local blink = (math.floor(p.invincibleTimer * 10) % 2 == 0)
        if p.visualNode then
            p.visualNode.enabled = blink
        end
        if p.invincibleTimer <= 0 then
            if p.visualNode then p.visualNode.enabled = true end
        end
    end

    -- 下砸后摇（着地短暂不接受输入）
    if p.slamRecovery > 0 then
        p.slamRecovery = p.slamRecovery - dt
        p.inputMoveX = 0
        p.inputJump = false
        p.inputDash = false
        p.inputSlam = false
        if p.slamRecovery <= 0 then
            p.slamLanded = false
        end
        goto updateVisuals
    end

    -- 爆炸后摇（后摇期间不接受输入，但重力和物理仍生效）
    if p.explodeRecovery > 0 then
        p.explodeRecovery = p.explodeRecovery - dt
        -- 清除所有输入，但不跳过物理更新
        p.inputMoveX = 0
        p.inputJump = false
        p.inputDash = false
        p.inputCharging = false
        p.inputExplodeRelease = false
        -- 应用重力（不调用完整 UpdateMovement 以避免输入干扰）
        if p.body then
            local vel = p.body.linearVelocity
            local vy = vel.y
            if not p.onGround and vy < 0 then
                local extraGravity = -9.81 * (Config.FallGravityMul - 1.0)
                vy = vy + extraGravity * dt
                if vy < -Config.MaxFallSpeed then vy = -Config.MaxFallSpeed end
            end
            -- 后摇期间水平速度快速衰减到 0
            local vx = vel.x * 0.85
            p.body.linearVelocity = Vector3(vx, vy, 0)
        end
        goto updateVisuals
    end

    -- 蓄力中（允许水平移动，禁止跳跃/冲刺）
    if p.charging then
        -- 持续蓄力：计时递增
        p.chargeTimer = math.min(p.chargeTimer + dt, Config.ExplosionChargeTime)
        p.chargeProgress = p.chargeTimer / Config.ExplosionChargeTime
        -- 视觉效果
        Player.UpdateExplodeVisual(p)
        -- 松开右键 → 触发爆炸
        if p.inputExplodeRelease then
            Player.DoExplode(p, p.chargeProgress)
            p.inputExplodeRelease = false
            p.inputCharging = false
        end
        p.inputCharging = false
        p.inputExplodeRelease = false

        -- 蓄力期间仍允许水平移动和重力（但禁止跳跃/冲刺）
        p.inputJump = false
        p.inputDash = false
        p.dashCooldown = p.dashCooldown  -- 保持冷却

        -- 冲刺冷却递减
        if p.dashCooldown > 0 then
            p.dashCooldown = p.dashCooldown - dt
        end

        -- 调用移动更新（跳跃/冲刺输入已被清除）
        Player.UpdateMovement(p, dt)

        -- 能量自动充能
        Player.UpdateEnergy(p, dt)

        goto updateVisuals
    end

    -- 冲刺冷却
    if p.dashCooldown > 0 then
        p.dashCooldown = p.dashCooldown - dt
    end

    -- 更新移动
    Player.UpdateMovement(p, dt)

    -- 能量自动充能
    Player.UpdateEnergy(p, dt)

    -- 处理蓄力输入（右键按住开始蓄力）
    if p.inputCharging and not p.charging then
        if p.energy >= 1.0 then
            Player.StartCharging(p)
        end
    end
    p.inputCharging = false
    p.inputExplodeRelease = false

    -- 死亡区域检测（客户端不做权威判定，由服务端物理驱动）
    if networkMode_ ~= "client" then
        if p.node and p.node.position.y < Config.DeathY then
            Player.Kill(p, "fall")
        end
    end

    -- 终点检测（服务端权威）
    if networkMode_ ~= "client" then
        if p.node and MapData.IsAtFinish(p.node.position.x, p.node.position.y) then
            p.finished = true
            print("[Player] Player " .. p.index .. " reached the finish!")
        end
    end

    -- =====================
    -- 视觉动效、帧末状态更新（蓄力/后摇 goto 跳转到此处）
    -- =====================
    ::updateVisuals::

    Player.UpdateVisualEffects(p, dt)

    -- 记录本帧速度，下帧着陆检测用
    if p.body then
        p.prevVelY = p.body.linearVelocity.y
    end

    -- 保存本帧地面状态，下帧用于着陆检测
    p.wasOnGround = p.onGround
    -- 重置帧碰撞状态
    p.onGround = false    -- 每帧重置，碰撞回调会重新设置
    p.hitCeiling = false   -- 每帧重置天花板碰撞
    p.hitWallX = 0         -- 每帧重置墙壁碰撞
end

--- 执行跳跃：给一个向上初速度，由物理重力自然完成抛物线
---@param p table
function Player.DoJump(p)
    p.jumpCount = p.jumpCount + 1
    p.coyoteTimer = Config.CoyoteTime + 1  -- 跳跃后禁止再次土狼跳

    -- 设置向上初速度
    if p.body then
        local vel = p.body.linearVelocity
        p.body.linearVelocity = Vector3(vel.x, Config.JumpSpeed, 0)
    end

    if networkMode_ ~= "server" then
        SFX.Play("jump", 0.5)
    end
end

--- 更新移动
---@param p table
---@param dt number
function Player.UpdateMovement(p, dt)
    if p.body == nil then return end
    local vel = p.body.linearVelocity

    -- 冲刺中（不受重力影响，Y 速度锁定为 0）
    if p.dashTimer > 0 then
        p.dashTimer = p.dashTimer - dt
        p.body.linearVelocity = Vector3(p.dashDir * Config.DashSpeed, 0, 0)
        return
    end

    -- 下砸中：锁定向下高速，水平速度为 0
    if p.slamming then
        p.body.linearVelocity = Vector3(0, -Config.SlamSpeed, 0)
        -- 跳跃/冲刺在下砸中不处理
        p.inputJump = false
        p.inputDash = false
        p.jumpBufferTimer = 0
        return
    end

    -- =====================
    -- 水平移动（独立于跳跃）
    -- =====================
    local moveX = p.inputMoveX
    local speed = Config.MoveSpeed

    local finalVx
    if p.onGround then
        -- 地面：直接设置速度
        finalVx = moveX * speed
    else
        -- 空中控制
        local targetVx = moveX * speed * Config.AirControlRatio
        local currentVx = vel.x
        finalVx = currentVx + (targetVx - currentVx) * Config.AirControlRatio * 5 * dt
    end

    -- 记录面朝方向
    if moveX ~= 0 then
        p.lastFaceDir = moveX > 0 and 1 or -1
    end

    -- =====================
    -- 天花板碰撞处理
    -- =====================
    if p.hitCeiling and vel.y > 0 then
        -- 撞到天花板且正在上升 → 立刻清零向上速度
        vel = Vector3(vel.x, 0, 0)
    end

    -- =====================
    -- 下落加速重力（fast-fall）
    -- 当角色正在下落（vy < 0）时，额外施加重力让下落更快更利落
    -- =====================
    local vy = vel.y
    if not p.onGround and vy < 0 then
        -- 下落中：施加额外重力
        local extraGravity = -9.81 * (Config.FallGravityMul - 1.0)  -- 只补差值，基础重力已由物理引擎施加
        vy = vy + extraGravity * dt
        -- 限制最大下落速度
        if vy < -Config.MaxFallSpeed then
            vy = -Config.MaxFallSpeed
        end
    end

    p.body.linearVelocity = Vector3(finalVx, vy, 0)

    -- =====================
    -- 跳跃输入（土狼时间 + 缓冲联合判定 + 空中起跳）
    -- =====================
    if p.jumpBufferTimer > 0 then
        local canJump = false

        if p.onGround then
            canJump = (p.jumpCount < Config.MaxJumps)
        elseif p.coyoteTimer <= Config.CoyoteTime then
            canJump = (p.jumpCount < Config.MaxJumps)
        elseif p.jumpCount < Config.MaxJumps then
            -- 空中跳跃：无论 jumpCount 是 0（走下平台）还是 1（已跳一次），
            -- 只要 jumpCount < MaxJumps 就允许跳跃
            canJump = true
        end

        if canJump then
            p.jumpBufferTimer = 0
            -- 空中起跳时（走下平台，jumpCount=0），消耗第一次跳跃次数
            if not p.onGround and p.coyoteTimer > Config.CoyoteTime and p.jumpCount == 0 then
                p.jumpCount = 1  -- 标记为已用一次，这样二段跳是第二次
            end
            Player.DoJump(p)
        end
    end

    -- =====================
    -- 冲刺
    -- =====================
    if p.inputDash then
        if p.dashCooldown <= 0 then
            p.dashTimer = Config.DashDuration
            p.dashDir = p.lastFaceDir
            p.dashCooldown = Config.DashCooldown
            p.slamming = false  -- 冲刺取消下砸
            if networkMode_ ~= "server" then
                SFX.Play("dash", 0.6)
            end
        end
        p.inputDash = false
    end

    -- =====================
    -- 下砸输入（S 键，仅空中触发）
    -- =====================
    if p.inputSlam then
        if not p.onGround and not p.slamming and p.dashTimer <= 0 then
            p.slamming = true
            p.slamLanded = false
            -- 立即设置向下速度，取消水平速度
            p.body.linearVelocity = Vector3(0, -Config.SlamSpeed, 0)
            if networkMode_ ~= "server" then
                SFX.Play("dash", 0.4)  -- 复用音效
            end
        end
        p.inputSlam = false
    end

    -- =====================
    -- 冲刺中击退检测（服务端/单机权威）
    -- =====================
    if p.dashTimer > 0 and networkMode_ ~= "client" then
        Player.CheckDashKnockback(p)
    end
end

--- 下砸着地击退：对周围敌人施加水平击退力（服务端/单机权威）
---@param p table
function Player.DoSlamImpact(p)
    if networkMode_ == "client" then return end
    if p.node == nil then return end

    local pos = p.node.position
    local radius = Config.SlamKnockRadius * Config.BlockSize

    for _, other in ipairs(Player.list) do
        if other.index ~= p.index and other.alive and other.node and other.invincibleTimer <= 0 then
            local diff = other.node.position - pos
            local dist = math.sqrt(diff.x * diff.x + diff.y * diff.y)
            if dist <= radius and dist > 0.01 then
                -- 水平方向击退
                local dir = (diff.x >= 0) and 1 or -1
                if other.body then
                    other.body.linearVelocity = Vector3(
                        dir * Config.SlamKnockForce,
                        Config.SlamKnockUpForce,
                        0
                    )
                end
                -- 视觉：被击退的玩家 squash
                other.squashScaleX = 0.7
                other.squashScaleY = 1.3
                other.squashVelX = 0
                other.squashVelY = 0
            end
        end
    end

    -- 屏幕震动
    if networkMode_ ~= "server" then
        Camera.Shake(0.2, 0.15)
        SFX.Play("explosion", 0.4)
    end
end

--- 冲刺击退检测：冲刺中碰到敌人施加更大的水平击退力
---@param p table
function Player.CheckDashKnockback(p)
    if p.node == nil then return end

    local pos = p.node.position
    local radius = Config.DashKnockRadius * Config.BlockSize

    for _, other in ipairs(Player.list) do
        if other.index ~= p.index and other.alive and other.node and other.invincibleTimer <= 0 then
            local diff = other.node.position - pos
            local dist = math.sqrt(diff.x * diff.x + diff.y * diff.y)
            if dist <= radius and dist > 0.01 then
                -- 冲刺方向击退（比下砸更远）
                local dir = p.dashDir
                if other.body then
                    other.body.linearVelocity = Vector3(
                        dir * Config.DashKnockForce,
                        Config.DashKnockUpForce,
                        0
                    )
                end
                -- 视觉：被撞飞的玩家 squash
                other.squashScaleX = 0.65
                other.squashScaleY = 1.35
                other.squashVelX = 0
                other.squashVelY = 0

                if networkMode_ ~= "server" then
                    Camera.Shake(0.25, 0.2)
                end
            end
        end
    end
end

-- ============================================================================
-- 视觉动效：Squash & Stretch + 冲刺旋转
-- ============================================================================

-- 弹簧参数（临界阻尼偏过阻尼，Q弹但不会振荡太久）
local SPRING_STIFFNESS = 600   -- 弹簧刚度 k
local SPRING_DAMPING   = 30    -- 阻尼系数 c
local SQUASH_REST      = 1.0   -- 静止比例
local DASH_ROLL_SPEED  = 720   -- 冲刺旋转速度（度/秒）
local DASH_ROLL_DECAY  = 1200  -- 非冲刺时旋转回弹速度（度/秒）

--- 更新视觉动效（squash & stretch + 旋转）
---@param p table
---@param dt number
function Player.UpdateVisualEffects(p, dt)
    if not p.visualNode or not p.node then return end

    -- =====================
    -- 由位置推算速度（兼容客户端无刚体场景）
    -- =====================
    local curX = p.node.position.x
    local curY = p.node.position.y
    local invDt = 1.0 / math.max(dt, 1e-4)
    local estVx = ((p.lastVisX ~= nil) and (curX - p.lastVisX) * invDt) or 0
    local estVy = ((p.lastVisY ~= nil) and (curY - p.lastVisY) * invDt) or 0
    p.lastVisX = curX
    p.lastVisY = curY

    -- =====================
    -- 撞墙 squash 触发
    -- 服务端：用 hitWallX + 刚体速度
    -- 客户端：用速度突变（上一帧水平速度大、本帧骤降）
    -- =====================
    if p.body and p.hitWallX ~= 0 then
        local vx = math.abs(p.body.linearVelocity.x)
        if vx > 2.0 then
            local squashAmount = math.min(vx / 12.0, 0.5)
            if squashAmount > 0.04 then
                p.squashScaleX = 1.0 - squashAmount
                p.squashScaleY = 1.0 + squashAmount * 0.7
                p.squashVelX = 0
                p.squashVelY = 0
            end
        end
    elseif not p.body then
        local prevVx = p.prevEstVx or 0
        local absPrev = math.abs(prevVx)
        local absCur = math.abs(estVx)
        if absPrev > 2.5 and absCur < absPrev * 0.5 then
            local squashAmount = math.min(absPrev / 12.0, 0.5)
            if squashAmount > 0.04 then
                p.squashScaleX = 1.0 - squashAmount
                p.squashScaleY = 1.0 + squashAmount * 0.7
                p.squashVelX = 0
                p.squashVelY = 0
            end
        end
        -- 落地 squash:垂直速度从下落骤减为 0 附近
        local prevVy = p.prevEstVy or 0
        if prevVy < -2.0 and estVy > -0.5 then
            local landAmount = math.min(math.abs(prevVy) / 12.0, 0.5)
            if landAmount > 0.04 then
                p.squashScaleY = 1.0 - landAmount
                p.squashScaleX = 1.0 + landAmount * 0.7
                p.squashVelX = 0
                p.squashVelY = 0
            end
        end
        p.prevEstVx = estVx
        p.prevEstVy = estVy
    end

    -- =====================
    -- 玩家互相挤压（优化：用距离平方避免 sqrt，提前跳过远距离玩家）
    -- =====================
    local pPosX = p.node.position.x
    local pPosY = p.node.position.y
    local threshSq = 0.95 * 0.95  -- 0.9025
    for _, other in ipairs(Player.list) do
        if other.index ~= p.index and other.alive and other.node then
            local dx = other.node.position.x - pPosX
            local dy = other.node.position.y - pPosY
            local distSq = dx * dx + dy * dy
            if distSq < threshSq and distSq > 0.0001 then
                local dist = math.sqrt(distSq)
                local overlap = 0.95 - dist
                local squeeze = overlap * 0.15
                if squeeze > 0.03 then
                    if math.abs(dx) > math.abs(dy) then
                        p.squashScaleX = math.min(p.squashScaleX, 1.0 - squeeze)
                        p.squashScaleY = math.max(p.squashScaleY, 1.0 + squeeze * 0.4)
                    else
                        p.squashScaleY = math.min(p.squashScaleY, 1.0 - squeeze)
                        p.squashScaleX = math.max(p.squashScaleX, 1.0 + squeeze * 0.4)
                    end
                end
            end
        end
    end

    -- =====================
    -- 弹簧物理：恢复 squash 到 1.0
    -- F = -k * displacement - c * velocity
    -- =====================
    local dispX = p.squashScaleX - SQUASH_REST
    local dispY = p.squashScaleY - SQUASH_REST

    local forceX = -SPRING_STIFFNESS * dispX - SPRING_DAMPING * p.squashVelX
    local forceY = -SPRING_STIFFNESS * dispY - SPRING_DAMPING * p.squashVelY

    p.squashVelX = p.squashVelX + forceX * dt
    p.squashVelY = p.squashVelY + forceY * dt

    p.squashScaleX = p.squashScaleX + p.squashVelX * dt
    p.squashScaleY = p.squashScaleY + p.squashVelY * dt

    -- 下落拉伸（stretch）：自由下落时纵向拉长
    do
        local vy = (p.body and p.body.linearVelocity.y) or estVy
        if vy < -4.0 then
            local stretch = math.min((-vy - 4.0) / 18.0, 0.25)
            p.squashScaleY = math.max(p.squashScaleY, 1.0 + stretch)
            p.squashScaleX = math.min(p.squashScaleX, 1.0 - stretch * 0.5)
        end
    end

    -- 安全钳位，防止极端形变
    p.squashScaleX = math.max(0.4, math.min(1.7, p.squashScaleX))
    p.squashScaleY = math.max(0.4, math.min(1.7, p.squashScaleY))

    -- =====================
    -- 冲刺旋转
    -- =====================
    if p.dashTimer > 0 then
        -- 冲刺中：朝冲刺方向旋转（绕 Z 轴）
        p.dashRoll = p.dashRoll + p.dashDir * (-DASH_ROLL_SPEED) * dt
    else
        -- 非冲刺：旋转回弹到 0
        if math.abs(p.dashRoll) > 0.5 then
            local decay = DASH_ROLL_DECAY * dt
            if p.dashRoll > 0 then
                p.dashRoll = math.max(0, p.dashRoll - decay)
            else
                p.dashRoll = math.min(0, p.dashRoll + decay)
            end
        else
            p.dashRoll = 0
        end
    end

    -- =====================
    -- 应用到 visualNode
    -- =====================
    local baseScale = 0.9  -- 原始缩放
    p.visualNode.scale = Vector3(
        baseScale * p.squashScaleX,
        baseScale * p.squashScaleY,
        baseScale
    )

    -- 旋转只在 Z 轴（2D 平面内的翻滚）
    if p.dashRoll ~= 0 then
        p.visualNode.rotation = Quaternion(p.dashRoll, Vector3.FORWARD)
    else
        p.visualNode.rotation = Quaternion.IDENTITY
    end

    -- =====================
    -- 眼睛动画
    -- =====================
    Player.UpdateEyes(p, dt)
end

--- 更新眼睛动画：方向偏移 + 挤压表情 + 眨眼
---@param p table
---@param dt number
function Player.UpdateEyes(p, dt)
    if not p.visualNode then return end

    local eyeL = p.visualNode:GetChild("EyeL")
    local eyeR = p.visualNode:GetChild("EyeR")
    if eyeL == nil or eyeR == nil then return end

    local bx = p.eyeBaseX
    local by = p.eyeBaseY
    local bz = p.eyeBaseZ
    local r  = p.eyeRadius

    -- =====================
    -- 1) 水平偏移：跟随移动方向
    -- =====================
    local targetOffsetX = p.inputMoveX * 0.13
    p.eyeOffsetX = p.eyeOffsetX + (targetOffsetX - p.eyeOffsetX) * math.min(1.0, dt * 10)

    -- =====================
    -- 2) 垂直偏移：跟随跳跃/下落
    -- =====================
    local targetOffsetY = 0
    local vy = 0
    if p.body then
        vy = p.body.linearVelocity.y
    elseif p.prevVelY then
        -- 客户端无物理体：使用位置差值推断的垂直速度
        vy = p.prevVelY
    end
    if vy > 2.0 then
        targetOffsetY = math.min(vy / 15.0, 1.0) * 0.10
    elseif vy < -2.0 then
        targetOffsetY = math.max(vy / 15.0, -1.0) * 0.10
    end
    p.eyeOffsetY = p.eyeOffsetY + (targetOffsetY - p.eyeOffsetY) * math.min(1.0, dt * 8)

    -- =====================
    -- 3) 挤压检测：纵向 OR 横向挤压都触发 >_<
    -- =====================
    local isSquished = (p.squashScaleY < 0.93) or (p.squashScaleX < 0.93)

    if isSquished then
        -- >_< 表情：眼睛变成扁线 + 向内倾斜
        local minSquash = math.min(p.squashScaleX, p.squashScaleY)
        local squishFactor = math.max(0.15, (minSquash - 0.5) / (0.93 - 0.5))
        local flatY = r * 0.22 * squishFactor
        local flatX = r * 1.3

        eyeL.scale = Vector3(flatX, flatY, r * 0.35)
        eyeR.scale = Vector3(flatX, flatY, r * 0.35)

        eyeL.rotation = Quaternion(-25, Vector3.FORWARD)
        eyeR.rotation = Quaternion(25, Vector3.FORWARD)

        -- 挤压时不偏移、不眨眼
        eyeL.position = Vector3(-bx, by, bz)
        eyeR.position = Vector3(bx, by, bz)
        return
    end

    -- =====================
    -- 4) 眨眼动画（仅在静止时触发）
    -- =====================
    local isIdle = (p.inputMoveX == 0 and p.onGround)
    if isIdle then
        p.idleTimer = p.idleTimer + dt
    else
        p.idleTimer = 0
        p.isBlinking = false
        p.blinkPhase = 0
    end

    -- 静止超过 1 秒后才开始眨眼计时
    local blinkScaleY = 1.0
    if p.idleTimer > 1.0 then
        p.blinkTimer = p.blinkTimer + dt
        if not p.isBlinking and p.blinkTimer >= p.blinkInterval then
            -- 开始眨眼
            p.isBlinking = true
            p.blinkPhase = 0
            p.blinkTimer = 0
            p.blinkInterval = 2.5 + math.random() * 3.5
        end
        if p.isBlinking then
            p.blinkPhase = p.blinkPhase + dt * 8.0  -- 眨眼速度
            if p.blinkPhase >= 1.0 then
                -- 眨眼结束
                p.isBlinking = false
                p.blinkPhase = 0
            else
                -- 眨眼曲线：0→1→0 正弦，中间完全闭眼
                blinkScaleY = 1.0 - math.sin(p.blinkPhase * math.pi) * 0.92
            end
        end
    else
        p.blinkTimer = 0
    end

    -- =====================
    -- 5) 应用正常表情
    -- =====================
    eyeL.rotation = Quaternion.IDENTITY
    eyeR.rotation = Quaternion.IDENTITY

    local scaleY = r * blinkScaleY
    eyeL.scale = Vector3(r, scaleY, r * 0.35)
    eyeR.scale = Vector3(r, scaleY, r * 0.35)

    local posY = by + p.eyeOffsetY
    eyeL.position = Vector3(-bx + p.eyeOffsetX, posY, bz)
    eyeR.position = Vector3(bx + p.eyeOffsetX, posY, bz)
end

--- 更新能量
---@param p table
---@param dt number
function Player.UpdateEnergy(p, dt)
    if p.energy < 1.0 then
        p.energy = p.energy + dt / Config.EnergyChargeTime
        if p.energy > 1.0 then
            p.energy = 1.0
        end
    end
end

-- ============================================================================
-- 爆炸前摇视觉效果
-- ============================================================================

--- 蓄力中"红温"闪烁 + 缩放脉冲
--- 不停在高饱和度/高明度的危险红色和原色之间快速切换
---@param p table
function Player.UpdateExplodeVisual(p)
    if not p.material then return end
    local progress = p.chargeProgress  -- 0→1

    -- 用 chargeTimer 驱动闪烁，频率随蓄力进度加快：3→8 Hz
    local freq = 3 + progress * 5
    local phase = p.chargeTimer * freq
    -- 用 floor 取整实现硬切换（而非 sin 的平滑过渡，确保闪烁清晰可见）
    local isRed = (math.floor(phase * 2) % 2 == 0)

    -- "红温"强度随蓄力进度增大（刚开始微红，蓄满时全红）
    local intensity = 0.3 + progress * 0.7  -- 0.3→1.0

    if isRed then
        -- 红温状态：高饱和度、高明度的危险红
        local r = 1.0
        local g = 0.05 * (1.0 - intensity)
        local b = 0.02 * (1.0 - intensity)
        p.material:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, 1.0)))
        -- 强烈红色自发光（"红得发光"）
        local emR = 0.8 + intensity * 0.2   -- 0.8→1.0
        local emG = 0.05 * (1.0 - intensity)
        p.material:SetShaderParameter("MatEmissiveColor", Variant(Color(emR, emG, 0.0)))
        -- 描边也变红
        if p.outlineMat then
            p.outlineMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0 * intensity, 0.02, 0.01, 1.0)))
        end
    else
        -- 短暂恢复原色（形成闪烁对比）
        local c = Config.PlayerColors[p.index]
        local e = Config.PlayerEmissive[p.index]
        p.material:SetShaderParameter("MatDiffColor", Variant(c))
        p.material:SetShaderParameter("MatEmissiveColor", Variant(e))
        if p.outlineMat then
            p.outlineMat:SetShaderParameter("MatDiffColor", Variant(Config.PlayerOutlineColors[p.index]))
        end
    end

    -- 缩放脉冲：幅度随蓄力进度增大
    if p.visualNode then
        local pulseAmp = 0.03 + progress * 0.09
        local pulseT = math.sin(p.chargeTimer * freq * math.pi * 2)
        local pulseScale = 1.0 + math.abs(pulseT) * pulseAmp
        local baseScale = 0.9
        p.visualNode.scale = Vector3(
            baseScale * pulseScale,
            baseScale * pulseScale,
            baseScale * pulseScale
        )
    end
end

--- 恢复玩家材质颜色
---@param p table
function Player.RestoreMaterial(p)
    if not p.material then return end
    local c = Config.PlayerColors[p.index]
    local e = Config.PlayerEmissive[p.index]
    p.material:SetShaderParameter("MatDiffColor", Variant(c))
    p.material:SetShaderParameter("MatEmissiveColor", Variant(e))
    -- 恢复描边颜色
    if p.outlineMat then
        p.outlineMat:SetShaderParameter("MatDiffColor", Variant(Config.PlayerOutlineColors[p.index]))
    end
end

-- ============================================================================
-- 爆炸
-- ============================================================================

--- 开始蓄力
---@param p table
function Player.StartCharging(p)
    if p.charging then return end
    p.charging = true
    p.chargeTimer = 0
    p.chargeProgress = 0
    print("[Player] Player " .. p.index .. " started charging explosion!")
end

--- 执行爆炸（蓄力释放）
---@param p table
---@param progress number 蓄力进度 0→1，决定爆炸半径
function Player.DoExplode(p, progress)
    p.charging = false
    p.chargeTimer = 0
    p.chargeProgress = 0
    p.energy = 0
    p.explodeRecovery = Config.ExplosionRecovery
    -- 强制重置地面状态：爆炸可能摧毁脚下平台，确保玩家立刻下落
    p.onGround = false
    p.wasOnGround = false
    Player.RestoreMaterial(p)

    if p.node == nil then return end

    -- 根据蓄力进度计算实际爆炸半径（最少 1 格）
    local actualRadius = math.max(1, math.floor(Config.ExplosionRadius * progress))

    local pos = p.node.position
    local centerGX, centerGY = mapModule_.WorldToGrid(pos.x, pos.y)

    -- 破坏地图方块（服务端权威，客户端不在这里破坏）
    local destroyed = 0
    if networkMode_ ~= "client" then
        destroyed = mapModule_.Explode(centerGX, centerGY, actualRadius)
    end

    -- 通知服务端广播爆炸事件（服务端侧调用）
    if networkMode_ == "server" and Player.onExplode then
        Player.onExplode(p.index, centerGX, centerGY, actualRadius)
    end

    -- 检测范围内其他玩家（服务端权威，客户端不判定击杀）
    if networkMode_ ~= "client" then
        -- 边缘判定：爆炸边缘碰到玩家描边线即可击杀
        -- 玩家描边外半径 ≈ BlockSize * 0.9 * 1.15 * 0.5 ≈ 0.52
        local playerOutlineRadius = Config.BlockSize * 0.9 * 1.15 * 0.5
        local killRadius = actualRadius * Config.BlockSize + playerOutlineRadius
        for _, other in ipairs(Player.list) do
            if other.index ~= p.index and other.alive and other.invincibleTimer <= 0 then
                if other.node then
                    local diff = other.node.position - pos
                    local dist = math.sqrt(diff.x * diff.x + diff.y * diff.y)
                    if dist <= killRadius then
                        Player.Kill(other, "explosion", p.index)
                        print("[Player] Player " .. p.index .. " killed Player " .. other.index .. "!")
                    end
                end
            end
        end
    end

    -- 视觉/音效（服务端跳过）
    if networkMode_ ~= "server" then
        -- 生成爆炸粒子特效
        Player.SpawnExplosionFX(pos, p.index)

        -- 屏幕震动（强度随爆炸半径缩放）
        local shakeIntensity = 0.15 + actualRadius * 0.05  -- 1格≈0.20, 7格≈0.50
        Camera.Shake(shakeIntensity, 0.25)

        -- 爆炸音效
        SFX.Play("explosion", 0.8)
    end

    print("[Player] Player " .. p.index .. " exploded! Radius=" .. actualRadius .. " Destroyed=" .. destroyed .. " blocks")
end

--- 生成爆炸粒子特效
---@param pos Vector3 爆炸中心
---@param playerIndex number 玩家编号（用于颜色）
function Player.SpawnExplosionFX(pos, playerIndex)
    if scene_ == nil then return end

    local fxNode = scene_:CreateChild("ExplosionFX", LOCAL)
    fxNode.position = Vector3(pos.x, pos.y, -0.5)

    -- 程序化创建粒子效果
    local effect = ParticleEffect:new()

    -- 创建粒子材质（透明）- 极高饱和度颜色
    local mat = Material:new()
    mat:SetTechnique(0, pbrAlphaTechnique_)
    local color = Config.PlayerColors[playerIndex]
    -- 将颜色推向极高饱和度：找到最大通道，压低其他通道
    local maxC = math.max(color.r, color.g, color.b, 0.01)
    local satR = math.min(1.0, (color.r / maxC) ^ 0.3) * 1.0  -- 增强对比
    local satG = math.min(1.0, (color.g / maxC) ^ 0.3) * 1.0
    local satB = math.min(1.0, (color.b / maxC) ^ 0.3) * 1.0
    -- 再压低非主导通道，拉到极致饱和
    local minSat = math.min(satR, satG, satB)
    satR = math.min(1.0, satR - minSat * 0.6 + 0.05)
    satG = math.min(1.0, satG - minSat * 0.6 + 0.05)
    satB = math.min(1.0, satB - minSat * 0.6 + 0.05)
    mat:SetShaderParameter("MatDiffColor", Variant(Color(satR, satG, satB, 0.95)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(satR * 0.8, satG * 0.8, satB * 0.8)))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    mat:SetShaderParameter("Roughness", Variant(0.3))
    effect:SetMaterial(mat)

    -- 粒子参数
    effect:SetNumParticles(60)
    effect:SetEmitterType(EMITTER_SPHERE)
    effect:SetEmitterSize(Vector3(1.5, 1.5, 0.5))

    -- 方向和速度（向外扩散）
    effect:SetMinDirection(Vector3(-1, -1, -0.2))
    effect:SetMaxDirection(Vector3(1, 1, 0.2))
    effect:SetMinVelocity(3.0)
    effect:SetMaxVelocity(8.0)
    effect:SetDampingForce(2.0)
    effect:SetConstantForce(Vector3(0, -3, 0))

    -- 粒子大小
    effect:SetMinParticleSize(Vector2(0.15, 0.15))
    effect:SetMaxParticleSize(Vector2(0.4, 0.4))
    effect:SetSizeAdd(-0.3)

    -- 生命期
    effect:SetMinTimeToLive(0.3)
    effect:SetMaxTimeToLive(0.8)

    -- 旋转
    effect:SetMinRotationSpeed(-200)
    effect:SetMaxRotationSpeed(200)

    -- 发射速率（短暂爆发）
    effect:SetMinEmissionRate(200)
    effect:SetMaxEmissionRate(300)
    effect:SetActiveTime(0.15)
    effect:SetInactiveTime(999)

    -- 颜色渐变：极亮高饱和 → 玩家饱和色 → 消失
    effect:SetNumColorFrames(3)
    effect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 0.3, 1.0), 0.0))  -- 初始闪光
    effect:SetColorFrame(1, ColorFrame(Color(satR, satG, satB, 0.9), 0.25))  -- 高饱和玩家色
    effect:SetColorFrame(2, ColorFrame(Color(satR * 0.5, satG * 0.3, satB * 0.2, 0.0), 1.0))  -- 渐暗消失

    -- 创建发射器
    local emitter = fxNode:CreateComponent("ParticleEmitter")
    emitter.effect = effect
    emitter.emitting = true
    emitter.autoRemoveMode = REMOVE_NODE

    -- 也添加一个大的快速扩散环（冲击波）
    local ringNode = scene_:CreateChild("ShockwaveFX", LOCAL)
    ringNode.position = Vector3(pos.x, pos.y, -0.5)

    local ringEffect = ParticleEffect:new()

    local ringMat = Material:new()
    ringMat:SetTechnique(0, pbrAlphaTechnique_)
    ringMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.6, 0.0, 0.85)))
    ringMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.4, 0.0)))
    ringMat:SetShaderParameter("Metallic", Variant(0.0))
    ringMat:SetShaderParameter("Roughness", Variant(0.3))
    ringEffect:SetMaterial(ringMat)

    ringEffect:SetNumParticles(20)
    ringEffect:SetEmitterType(EMITTER_SPHERE)
    ringEffect:SetEmitterSize(Vector3(0.5, 0.5, 0.2))

    ringEffect:SetMinDirection(Vector3(-1, -0.3, -0.1))
    ringEffect:SetMaxDirection(Vector3(1, 0.3, 0.1))
    ringEffect:SetMinVelocity(8.0)
    ringEffect:SetMaxVelocity(14.0)
    ringEffect:SetDampingForce(5.0)

    ringEffect:SetMinParticleSize(Vector2(0.3, 0.3))
    ringEffect:SetMaxParticleSize(Vector2(0.6, 0.6))

    ringEffect:SetMinTimeToLive(0.2)
    ringEffect:SetMaxTimeToLive(0.5)

    ringEffect:SetMinEmissionRate(200)
    ringEffect:SetMaxEmissionRate(200)
    ringEffect:SetActiveTime(0.05)
    ringEffect:SetInactiveTime(999)

    ringEffect:SetNumColorFrames(2)
    ringEffect:SetColorFrame(0, ColorFrame(Color(1.0, 0.95, 0.1, 1.0), 0.0))  -- 极亮黄白闪光
    ringEffect:SetColorFrame(1, ColorFrame(Color(1.0, 0.3, 0.0, 0.0), 1.0))   -- 高饱和橙红消散

    local ringEmitter = ringNode:CreateComponent("ParticleEmitter")
    ringEmitter.effect = ringEffect
    ringEmitter.emitting = true
    ringEmitter.autoRemoveMode = REMOVE_NODE
end

-- ============================================================================
-- 死亡与重生
-- ============================================================================

--- 击杀事件回调（由 GameManager 注册）
---@type fun(killerIndex: number, victimIndex: number, multiKillCount: number, killStreak: number)|nil
Player.onKill = nil

--- 爆炸事件回调（由 Server 注册，用于广播爆炸同步）
---@type fun(playerIndex: number, centerGX: number, centerGY: number, actualRadius: number)|nil
Player.onExplode = nil

--- 玩家死亡事件回调（由 Server 注册，用于广播死亡同步）
---@type fun(playerIndex: number, reason: string, killerIndex: number|nil)|nil
Player.onDeath = nil

--- 击杀玩家
---@param p table
---@param reason string "explosion"|"fall"
---@param killerIndex number|nil 击杀者玩家编号（爆炸击杀时提供）
function Player.Kill(p, reason, killerIndex)
    if not p.alive then return end
    if p.invincibleTimer > 0 then return end

    p.alive = false
    p.respawnTimer = Config.RespawnDelay

    -- 击杀者统计
    if killerIndex and killerIndex ~= p.index then
        for _, killer in ipairs(Player.list) do
            if killer.index == killerIndex then
                killer.kills = killer.kills + 1
                killer.killStreak = killer.killStreak + 1

                -- 短时间连杀判定
                if killer.multiKillTimer > 0 then
                    killer.multiKillCount = killer.multiKillCount + 1
                else
                    killer.multiKillCount = 1
                end
                killer.multiKillTimer = Config.MultiKillWindow

                -- 通知 GameManager
                if Player.onKill then
                    Player.onKill(killerIndex, p.index, killer.multiKillCount, killer.killStreak)
                end
                break
            end
        end
    end

    -- 通知服务端广播死亡事件
    if networkMode_ == "server" and Player.onDeath then
        Player.onDeath(p.index, reason, killerIndex)
    end

    -- 隐藏玩家节点 + 停止物理
    if p.node then
        local deathPos = p.node.position

        -- 1) 先停止物理（必须在禁用节点之前，否则访问已禁用组件可能无效）
        if p.body then
            p.body.linearVelocity = Vector3.ZERO
        end

        -- 2) 显式隐藏视觉子节点（双重保险）
        if p.visualNode then
            p.visualNode.enabled = false
        end

        -- 3) 禁用整个玩家节点（统一用属性赋值风格）
        p.node.enabled = false

        -- 爆炸死亡：喷溅特效 + 哭脸形象（服务端跳过）
        if reason == "explosion" and networkMode_ ~= "server" then
            Player.SpawnSplatFX(deathPos, p.index)
            Player.SpawnDeathFace(p, deathPos)
        end
    end

    -- 死亡重置连杀
    p.killStreak = 0

    if networkMode_ ~= "server" then
        SFX.Play("death", 0.7)
    end

    print("[Player] Player " .. p.index .. " died (" .. reason .. ")")
end

--- 生成玩家被炸死的喷溅特效（夸张版）
---@param pos Vector3 死亡位置
---@param playerIndex number 玩家编号（用于颜色）
function Player.SpawnSplatFX(pos, playerIndex)
    if scene_ == nil then return end

    local color = Config.PlayerColors[playerIndex]
    local r, g, b = color.r, color.g, color.b

    -- === 第 1 层：大量碎片向四周飞散（主体喷溅） ===
    local fxNode = scene_:CreateChild("SplatFX", LOCAL)
    fxNode.position = Vector3(pos.x, pos.y, -0.3)

    local effect = ParticleEffect:new()
    local mat = Material:new()
    mat:SetTechnique(0, pbrAlphaTechnique_)
    mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, 1.0)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(r * 0.5, g * 0.5, b * 0.5)))
    mat:SetShaderParameter("Metallic", Variant(0.05))
    mat:SetShaderParameter("Roughness", Variant(0.5))
    effect:SetMaterial(mat)

    effect:SetNumParticles(120)
    effect:SetEmitterType(EMITTER_SPHERE)
    effect:SetEmitterSize(Vector3(0.2, 0.2, 0.05))

    effect:SetMinDirection(Vector3(-1, -0.6, -0.05))
    effect:SetMaxDirection(Vector3(1, 1.5, 0.05))
    effect:SetMinVelocity(6.0)
    effect:SetMaxVelocity(18.0)
    effect:SetDampingForce(2.5)
    effect:SetConstantForce(Vector3(0, -12, 0))

    effect:SetMinParticleSize(Vector2(0.04, 0.04))
    effect:SetMaxParticleSize(Vector2(0.18, 0.18))

    effect:SetMinTimeToLive(0.3)
    effect:SetMaxTimeToLive(0.9)

    effect:SetMinRotationSpeed(-400)
    effect:SetMaxRotationSpeed(400)

    effect:SetMinEmissionRate(600)
    effect:SetMaxEmissionRate(800)
    effect:SetActiveTime(0.1)
    effect:SetInactiveTime(999)

    effect:SetNumColorFrames(3)
    effect:SetColorFrame(0, ColorFrame(Color(r, g, b, 1.0), 0.0))
    effect:SetColorFrame(1, ColorFrame(Color(r * 0.7, g * 0.7, b * 0.7, 0.9), 0.35))
    effect:SetColorFrame(2, ColorFrame(Color(r * 0.2, g * 0.2, b * 0.2, 0.0), 1.0))

    local emitter = fxNode:CreateComponent("ParticleEmitter")
    emitter.effect = effect
    emitter.emitting = true
    emitter.autoRemoveMode = REMOVE_NODE

    -- === 第 2 层：中心闪光爆裂（白→玩家色，大粒子快速膨胀消失） ===
    local flashNode = scene_:CreateChild("SplatFlash", LOCAL)
    flashNode.position = Vector3(pos.x, pos.y, -0.35)

    local flashEffect = ParticleEffect:new()
    local flashMat = Material:new()
    flashMat:SetTechnique(0, pbrAlphaTechnique_)
    flashMat:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1.0)))
    flashMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1, 1, 0.8)))
    flashMat:SetShaderParameter("Metallic", Variant(0.0))
    flashMat:SetShaderParameter("Roughness", Variant(0.2))
    flashEffect:SetMaterial(flashMat)

    flashEffect:SetNumParticles(8)
    flashEffect:SetEmitterType(EMITTER_SPHERE)
    flashEffect:SetEmitterSize(Vector3(0.05, 0.05, 0.01))

    flashEffect:SetMinDirection(Vector3(-0.5, -0.5, 0))
    flashEffect:SetMaxDirection(Vector3(0.5, 0.5, 0))
    flashEffect:SetMinVelocity(0.5)
    flashEffect:SetMaxVelocity(2.0)
    flashEffect:SetDampingForce(4.0)

    flashEffect:SetMinParticleSize(Vector2(0.4, 0.4))
    flashEffect:SetMaxParticleSize(Vector2(0.8, 0.8))
    flashEffect:SetSizeAdd(1.5)

    flashEffect:SetMinTimeToLive(0.1)
    flashEffect:SetMaxTimeToLive(0.25)

    flashEffect:SetMinEmissionRate(200)
    flashEffect:SetMaxEmissionRate(200)
    flashEffect:SetActiveTime(0.03)
    flashEffect:SetInactiveTime(999)

    flashEffect:SetNumColorFrames(3)
    flashEffect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 1.0, 1.0), 0.0))
    flashEffect:SetColorFrame(1, ColorFrame(Color(r, g, b, 0.7), 0.3))
    flashEffect:SetColorFrame(2, ColorFrame(Color(r, g, b, 0.0), 1.0))

    local flashEmitter = flashNode:CreateComponent("ParticleEmitter")
    flashEmitter.effect = flashEffect
    flashEmitter.emitting = true
    flashEmitter.autoRemoveMode = REMOVE_NODE

    -- === 第 3 层：彩色星星/碎屑飞散（白色小亮点） ===
    local starNode = scene_:CreateChild("SplatStars", LOCAL)
    starNode.position = Vector3(pos.x, pos.y, -0.32)

    local starEffect = ParticleEffect:new()
    local starMat = Material:new()
    starMat:SetTechnique(0, pbrAlphaTechnique_)
    starMat:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 0.9, 1.0)))
    starMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1, 1, 0.7)))
    starMat:SetShaderParameter("Metallic", Variant(0.0))
    starMat:SetShaderParameter("Roughness", Variant(0.3))
    starEffect:SetMaterial(starMat)

    starEffect:SetNumParticles(30)
    starEffect:SetEmitterType(EMITTER_SPHERE)
    starEffect:SetEmitterSize(Vector3(0.1, 0.1, 0.02))

    starEffect:SetMinDirection(Vector3(-1, -0.2, -0.02))
    starEffect:SetMaxDirection(Vector3(1, 1.8, 0.02))
    starEffect:SetMinVelocity(8.0)
    starEffect:SetMaxVelocity(22.0)
    starEffect:SetDampingForce(3.0)
    starEffect:SetConstantForce(Vector3(0, -15, 0))

    starEffect:SetMinParticleSize(Vector2(0.02, 0.02))
    starEffect:SetMaxParticleSize(Vector2(0.06, 0.06))

    starEffect:SetMinTimeToLive(0.4)
    starEffect:SetMaxTimeToLive(1.0)

    starEffect:SetMinRotationSpeed(-500)
    starEffect:SetMaxRotationSpeed(500)

    starEffect:SetMinEmissionRate(400)
    starEffect:SetMaxEmissionRate(500)
    starEffect:SetActiveTime(0.06)
    starEffect:SetInactiveTime(999)

    starEffect:SetNumColorFrames(3)
    starEffect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 0.8, 1.0), 0.0))
    starEffect:SetColorFrame(1, ColorFrame(Color(1.0, 0.9, 0.3, 0.8), 0.3))
    starEffect:SetColorFrame(2, ColorFrame(Color(r * 0.5, g * 0.5, b * 0.5, 0.0), 1.0))

    local starEmitter = starNode:CreateComponent("ParticleEmitter")
    starEmitter.effect = starEffect
    starEmitter.emitting = true
    starEmitter.autoRemoveMode = REMOVE_NODE

    -- === 屏幕震动 ===
    Camera.Shake(0.3, 0.3)
end

--- 在死亡位置生成哭脸贴图（替代角色形象，直到重生时移除）
--- 带弹出动画：从 0 弹性缩放到正常大小
---@param p table 玩家数据
---@param pos Vector3 死亡位置
function Player.SpawnDeathFace(p, pos)
    if scene_ == nil then return end

    -- 移除之前可能残留的哭脸
    Player.RemoveDeathFace(p)

    -- 与角色完全重合：角色 visualNode 的 scale 是 0.9，BlockSize 是 1.0
    local charSize = Config.BlockSize * 0.9

    local fxNode = scene_:CreateChild("DeathFace_" .. p.index, LOCAL)
    fxNode.position = Vector3(pos.x, pos.y, 0)

    local planeNode = fxNode:CreateChild("FacePlane")
    planeNode.position = Vector3(0, 0, -0.5)
    planeNode.scale = Vector3(0, 1.0, 0) -- 从 0 开始，动画弹出
    planeNode.rotation = Quaternion(-90, Vector3.RIGHT)

    local planeModel = planeNode:CreateComponent("StaticModel")
    planeModel.model = cache:GetResource("Model", "Models/Plane.mdl")
    planeModel.castShadows = false

    local faceMat = Material:new()
    local alphaTexTech = cache:GetResource("Technique", "Techniques/DiffAlpha.xml")
    faceMat:SetTechnique(0, alphaTexTech)
    local faceTex = cache:GetResource("Texture2D", "image/Group 4.png")
    faceMat:SetTexture(TU_DIFFUSE, faceTex)
    faceMat:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
    planeModel:SetMaterial(faceMat)

    p.deathFaceNode = fxNode
    p.deathFacePlane = planeNode
    p.deathFaceTimer = 0
    p.deathFaceTargetSize = charSize
end

--- 移除哭脸贴图
---@param p table 玩家数据
function Player.RemoveDeathFace(p)
    if p.deathFaceNode then
        p.deathFaceNode:Remove()
        p.deathFaceNode = nil
    end
    p.deathFacePlane = nil
    p.deathFaceTimer = nil
    p.deathFaceTargetSize = nil
end

--- 重生玩家
---@param p table
function Player.Respawn(p)
    Player.RemoveDeathFace(p)
    p.alive = true
    p.invincibleTimer = Config.InvincibleDuration
    p.energy = 0
    p.charging = false
    p.chargeTimer = 0
    p.chargeProgress = 0
    p.explodeRecovery = 0
    Player.RestoreMaterial(p)
    p.jumpCount = 0
    p.wasOnGround = false
    p.dashTimer = 0
    p.dashCooldown = 0
    p.slamming = false
    p.slamLanded = false
    p.slamRecovery = 0
    p.inputSlam = false

    -- 重置视觉动效
    p.squashScaleX = 1.0
    p.squashScaleY = 1.0
    p.squashVelX = 0
    p.squashVelY = 0
    p.dashRoll = 0
    p.prevVelY = 0
    p.hitWallX = 0
    if p.visualNode then
        p.visualNode.scale = Vector3(0.9, 0.9, 0.9)
        p.visualNode.rotation = Quaternion.IDENTITY
        p.visualNode.enabled = true
    end

    -- 回到起点
    local sx, sy = MapData.GetSpawnPosition(p.index)
    if p.node then
        p.node.enabled = true
        p.node.position = Vector3(sx, sy, 0)
    end
    if p.body then
        p.body.linearVelocity = Vector3(0, 0, 0)
    end

    print("[Player] Player " .. p.index .. " respawned")
end

--- 重置所有玩家（新回合）
function Player.ResetAll()
    for _, p in ipairs(Player.list) do
        Player.RemoveDeathFace(p)
        p.alive = true
        p.finished = false
        p.finishOrder = 0
        p.kills = 0
        p.killStreak = 0
        p.multiKillCount = 0
        p.multiKillTimer = 0
        p.energy = 0
        p.charging = false
        p.chargeTimer = 0
        p.chargeProgress = 0
        p.explodeRecovery = 0
        Player.RestoreMaterial(p)
        p.invincibleTimer = 0
        p.respawnTimer = 0
        p.jumpCount = 0
        p.wasOnGround = false
        p.dashTimer = 0
        p.dashCooldown = 0
        p.inputMoveX = 0
        p.inputJump = false
        p.inputDash = false
        p.inputSlam = false
        p.inputCharging = false
        p.inputExplodeRelease = false
        p.wasChargingInput = false
        p.slamming = false
        p.slamLanded = false
        p.slamRecovery = 0

        -- 重置视觉动效
        p.squashScaleX = 1.0
        p.squashScaleY = 1.0
        p.squashVelX = 0
        p.squashVelY = 0
        p.dashRoll = 0
        p.prevVelY = 0
        p.hitWallX = 0
        if p.visualNode then
            p.visualNode.scale = Vector3(0.9, 0.9, 0.9)
            p.visualNode.rotation = Quaternion.IDENTITY
            p.visualNode.enabled = true
        end

        local sx, sy = MapData.GetSpawnPosition(p.index)
        if p.node then
            p.node.enabled = true
            p.node.position = Vector3(sx, sy, 0)
        end
        if p.body then
            p.body.linearVelocity = Vector3(0, 0, 0)
        end
    end
end

--- 添加能量
---@param p table
---@param amount number 0~1
function Player.AddEnergy(p, amount)
    p.energy = math.min(1.0, p.energy + amount)
end

--- 获取活跃玩家位置列表
---@return table
function Player.GetAlivePositions()
    local positions = {}
    for _, p in ipairs(Player.list) do
        if p.alive and p.node then
            table.insert(positions, p.node.position)
        end
    end
    return positions
end

-- ============================================================================
-- 客户端专用更新（仅视觉，不做物理/爆炸/击杀/死亡判定）
-- ============================================================================

-- 客户端诊断计时器（每15秒输出一次简要摘要，减少字符串拼接开销）
local clientDiagTimer_ = 0

--- 客户端专用：更新所有玩家（仅视觉效果）
---@param dt number
function Player.UpdateAllClient(dt)
    -- 每15秒输出一次简要诊断
    clientDiagTimer_ = clientDiagTimer_ + dt
    if clientDiagTimer_ >= 15.0 then
        clientDiagTimer_ = 0
        local n = #Player.list
        local alive = 0
        for _, p in ipairs(Player.list) do
            if p.alive then alive = alive + 1 end
        end
        print(string.format("[Player.Diag] %d players, %d alive", n, alive))
    end

    for _, p in ipairs(Player.list) do
        Player.UpdateOneClient(p, dt)
    end
end

--- 客户端专用：更新单个玩家（仅视觉，不做物理/输入/爆炸/死亡）
---@param p table
---@param dt number
function Player.UpdateOneClient(p, dt)
    if not p.alive then
        -- 死亡状态：检测服务端是否已通过场景复制重新启用节点
        p.respawnTimer = p.respawnTimer - dt
        if p.node and p.node.enabled then
            -- 服务端已 Respawn 并 enable 了节点（通过复制同步到客户端）
            -- 客户端本地执行 Respawn 恢复 alive 和视觉状态
            Player.Respawn(p)
            print("[Player] Client detected server respawn for player " .. p.index)
            return
        end
        -- 哭脸弹出动画
        if p.deathFacePlane and p.deathFaceTimer ~= nil then
            p.deathFaceTimer = p.deathFaceTimer + dt
            local dur = 0.2
            local t = math.min(p.deathFaceTimer / dur, 1.0)
            local s
            if t < 1.0 then
                s = 1.0 - math.cos(t * math.pi * 0.5)
                s = s + math.sin(t * math.pi * 2.5) * (1.0 - t) * 0.35
                s = s * 1.15
            else
                s = 1.0
            end
            local sz = p.deathFaceTargetSize * s
            p.deathFacePlane.scale = Vector3(sz, 1.0, sz)
        end
        return
    end

    if p.finished then return end

    -- 无敌闪烁
    if p.invincibleTimer > 0 then
        p.invincibleTimer = p.invincibleTimer - dt
        local blink = (math.floor(p.invincibleTimer * 10) % 2 == 0)
        if p.visualNode then
            p.visualNode.enabled = blink
        end
        if p.invincibleTimer <= 0 then
            if p.visualNode then p.visualNode.enabled = true end
        end
    end

    -- 爆炸后摇视觉（计时递减，不做物理）
    if p.explodeRecovery > 0 then
        p.explodeRecovery = p.explodeRecovery - dt
    end

    -- 蓄力视觉效果（本机玩家本地即时反馈）
    if p.isHuman then
        local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
        if leftDown and not p.charging and p.energy >= 1.0 then
            -- 开始蓄力视觉
            p.charging = true
            p.chargeTimer = 0
            p.chargeProgress = 0
        end
        if p.charging then
            if leftDown then
                p.chargeTimer = math.min(p.chargeTimer + dt, Config.ExplosionChargeTime)
                p.chargeProgress = p.chargeTimer / Config.ExplosionChargeTime
                Player.UpdateExplodeVisual(p)
            else
                -- 松开时：等待服务端 EXPLODE_SYNC 来执行实际爆炸
                -- 这里不做任何事情，HandleRemoteExplode 会重置蓄力状态
            end
        end
    end

    -- 着陆 squash 由 UpdateVisualEffects 的速度估算分支处理（客户端无可靠 onGround）

    -- 连杀窗口递减（视觉用）
    if p.multiKillTimer > 0 then
        p.multiKillTimer = p.multiKillTimer - dt
        if p.multiKillTimer <= 0 then p.multiKillCount = 0 end
    end

    -- 面朝方向（客户端无物理体，从位置变化推断）
    if p.node and p.node.enabled then
        local curPos = p.node.position
        if p.prevPosition then
            local dx = curPos.x - p.prevPosition.x
            local dy = curPos.y - p.prevPosition.y
            -- 用位置差值推断水平方向
            if dx > 0.02 then p.lastFaceDir = 1
            elseif dx < -0.02 then p.lastFaceDir = -1 end
            -- 推断 inputMoveX（供眼睛动画用）
            if math.abs(dx) > 0.02 then
                p.inputMoveX = dx > 0 and 1 or -1
            else
                p.inputMoveX = 0
            end
            -- 垂直速度估算（保留供其他视觉用，squash 由 UpdateVisualEffects 自行估算）
            if dt > 0 then
                p.prevVelY = dy / dt
            end
        end
        p.prevPosition = Vector3(curPos.x, curPos.y, curPos.z)
    end

    -- 视觉动效（squash & stretch、眼睛动画）
    Player.UpdateVisualEffects(p, dt)

    -- 记录帧状态
    p.wasOnGround = p.onGround
    p.onGround = false
    p.hitCeiling = false
    p.hitWallX = 0
end

--- 客户端处理远程爆炸同步：执行地图破坏 + 视觉/音效
---@param playerIndex number 爆炸者玩家编号
---@param centerGX number 爆炸中心网格 X
---@param centerGY number 爆炸中心网格 Y
---@param actualRadius number 爆炸半径（格）
function Player.HandleRemoteExplode(playerIndex, centerGX, centerGY, actualRadius)
    -- 在客户端地图上执行破坏（客户端 MapRoot 是 LOCAL 的）
    mapModule_.Explode(centerGX, centerGY, actualRadius)

    -- 找到爆炸者的位置用于特效
    local pos = nil
    for _, p in ipairs(Player.list) do
        if p.index == playerIndex then
            if p.node then
                pos = p.node.position
            end
            -- 重置该玩家的蓄力视觉
            p.charging = false
            p.chargeTimer = 0
            p.chargeProgress = 0
            p.explodeRecovery = Config.ExplosionRecovery
            p.onGround = false
            p.wasOnGround = false
            Player.RestoreMaterial(p)
            break
        end
    end

    if pos then
        -- 视觉特效
        Player.SpawnExplosionFX(pos, playerIndex)
        -- 屏幕震动
        local shakeIntensity = 0.15 + actualRadius * 0.05
        Camera.Shake(shakeIntensity, 0.25)
        -- 音效
        SFX.Play("explosion", 0.8)
    end

    print("[Player] Remote explode: player=" .. playerIndex .. " radius=" .. actualRadius)
end

--- 客户端处理远程死亡同步：执行死亡视觉效果
---@param playerIndex number 死亡玩家编号
---@param reason string "explosion"|"fall"
---@param killerIndex number|nil 击杀者编号
function Player.ClientDeath(playerIndex, reason, killerIndex)
    for _, p in ipairs(Player.list) do
        if p.index == playerIndex then
            if not p.alive then return end  -- 已经死了，不重复处理

            p.alive = false
            p.respawnTimer = Config.RespawnDelay
            p.killStreak = 0

            -- 隐藏玩家 + 停止物理
            if p.node then
                local deathPos = p.node.position

                if p.body then
                    p.body.linearVelocity = Vector3.ZERO
                end
                if p.visualNode then
                    p.visualNode.enabled = false
                end
                p.node.enabled = false

                -- 爆炸死亡：喷溅特效 + 哭脸
                if reason == "explosion" then
                    Player.SpawnSplatFX(deathPos, p.index)
                    Player.SpawnDeathFace(p, deathPos)
                end
            end

            SFX.Play("death", 0.7)
            print("[Player] Client death: player=" .. playerIndex .. " reason=" .. reason)
            return
        end
    end
end

--- 获取人类玩家位置（即使死亡也返回重生点，保证相机始终能跟踪）
---@return Vector3|nil
function Player.GetHumanPosition()
    for _, p in ipairs(Player.list) do
        if p.isHuman then
            if p.alive and p.node then
                return p.node.position
            else
                -- 死亡时返回重生点位置
                local sx, sy = MapData.GetSpawnPosition(p.index)
                return Vector3(sx, sy, 0)
            end
        end
    end
    return nil
end

return Player

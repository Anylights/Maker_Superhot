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

--- 创建一个玩家
---@param index number 玩家编号 1~4
---@param isHuman boolean 是否人类控制
---@return table 玩家数据
function Player.Create(index, isHuman)
    local spawnX, spawnY = MapData.GetSpawnPosition(index)

    local node = scene_:CreateChild("Player_" .. index)
    node.position = Vector3(spawnX, spawnY, 0)

    -- 视觉子节点（模型挂在子节点上，方便做缩放/旋转动效而不影响物理碰撞体）
    local visualNode = node:CreateChild("Visual")
    visualNode.scale = Vector3(0.9, 0.9, 0.9)

    -- 方块外观（圆角矩形，与地图方块统一风格）
    local geom = visualNode:CreateComponent("CustomGeometry")
    mapModule_.BuildRoundedBox(geom, Config.BlockSize, 0.1)
    geom.castShadows = true

    local mat = Material:new()
    mat:SetTechnique(0, pbrTechnique_)
    mat:SetShaderParameter("MatDiffColor", Variant(Config.PlayerColors[index]))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Config.PlayerEmissive[index]))
    mat:SetShaderParameter("Metallic", Variant(Config.RubberMetallic))
    mat:SetShaderParameter("Roughness", Variant(Config.RubberRoughness))
    geom:SetMaterial(mat)

    -- 描边子节点（在角色后面 Z+0.1，略大）
    local outlineNode = visualNode:CreateChild("Outline")
    outlineNode.position = Vector3(0, 0, 0.1)
    outlineNode.scale = Vector3(1.15, 1.15, 1.0)
    local outlineGeom = outlineNode:CreateComponent("CustomGeometry")
    mapModule_.BuildRoundedBox(outlineGeom, Config.BlockSize, 0.1)
    outlineGeom.castShadows = false
    local outlineMat = Material:new()
    outlineMat:SetTechnique(0, pbrTechnique_)
    outlineMat:SetShaderParameter("MatDiffColor", Variant(Config.PlayerOutlineColors[index]))
    outlineMat:SetShaderParameter("Metallic", Variant(0.0))
    outlineMat:SetShaderParameter("Roughness", Variant(1.0))
    outlineGeom:SetMaterial(outlineMat)

    -- 眼睛（两个扁圆片，无光照纯色，颜色与描边相同）
    local sphereModel = cache:GetResource("Model", "Models/Sphere.mdl")
    local unlitTechnique = cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml")
    local eyeMat = Material:new()
    eyeMat:SetTechnique(0, unlitTechnique)
    eyeMat:SetShaderParameter("MatDiffColor", Variant(Config.PlayerOutlineColors[index]))

    -- 眼睛基础参数（记录到 p 数据表用于动画）
    local eyeBaseX = 0.16        -- 眼睛到中心的水平距离
    local eyeBaseY = 0.06        -- 眼睛垂直偏移
    local eyeBaseZ = -0.48       -- 前表面
    local eyeRadius = 0.22       -- 眼睛半径（直径≈0.44，占体宽~44%）

    local eyeL = visualNode:CreateChild("EyeL")
    eyeL.position = Vector3(-eyeBaseX, eyeBaseY, eyeBaseZ)
    eyeL.scale = Vector3(eyeRadius, eyeRadius, eyeRadius * 0.35)
    local eyeLModel = eyeL:CreateComponent("StaticModel")
    eyeLModel.model = sphereModel
    eyeLModel.castShadows = false
    eyeLModel:SetMaterial(eyeMat)

    local eyeR = visualNode:CreateChild("EyeR")
    eyeR.position = Vector3(eyeBaseX, eyeBaseY, eyeBaseZ)
    eyeR.scale = Vector3(eyeRadius, eyeRadius, eyeRadius * 0.35)
    local eyeRModel = eyeR:CreateComponent("StaticModel")
    eyeRModel.model = sphereModel
    eyeRModel.castShadows = false
    eyeRModel:SetMaterial(eyeMat)

    -- 动态刚体
    local body = node:CreateComponent("RigidBody")
    body.mass = 1.0
    body.friction = 0.3  -- 降低摩擦：移动由代码直接设置速度，低摩擦避免被地面约束卡住
    body.linearDamping = 0.05
    body.collisionLayer = 2
    body.collisionMask = 0xFFFF
    body.collisionEventMode = COLLISION_ALWAYS

    -- 2.5D 约束：锁 Z 移动，锁全旋转
    body.linearFactor = Vector3(1, 1, 0)
    body.angularFactor = Vector3(0, 0, 0)

    local shape = node:CreateComponent("CollisionShape")
    -- 使用胶囊体代替方盒：底部圆弧可滑过方块接缝，避免边缘卡顿
    -- 直径0.9 高度1.0（缩放0.9后有效尺寸: 直径0.81 高度0.9）
    shape:SetCapsule(0.9, 1.0)

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

        -- 输入缓存（AI 或人类写入）
        inputMoveX = 0,
        inputJump = false,
        inputDash = false,
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

    -- 注册碰撞回调
    node:CreateScriptObject("PlayerCollision")
    local scriptObj = node:GetScriptObject()
    if scriptObj then
        scriptObj.playerData = p
    end

    table.insert(Player.list, p)
    print("[Player] Created player " .. index .. (isHuman and " (human)" or " (AI)"))

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
        -- 着陆时检查跳跃缓冲：缓冲窗口内有按键 → 自动起跳
        if p.jumpBufferTimer > 0 then
            p.jumpBufferTimer = 0
            Player.DoJump(p)
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

    -- 死亡区域检测
    if p.node and p.node.position.y < Config.DeathY then
        Player.Kill(p, "fall")
    end

    -- 终点检测
    if p.node and MapData.IsAtFinish(p.node.position.x, p.node.position.y) then
        p.finished = true
        print("[Player] Player " .. p.index .. " reached the finish!")
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

    SFX.Play("jump", 0.5)
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
    -- 跳跃输入（土狼时间 + 缓冲联合判定）
    -- =====================
    if p.jumpBufferTimer > 0 then
        local canJump = false

        if p.onGround then
            canJump = (p.jumpCount < Config.MaxJumps)
        elseif p.coyoteTimer <= Config.CoyoteTime then
            canJump = (p.jumpCount < Config.MaxJumps)
        elseif p.jumpCount > 0 and p.jumpCount < Config.MaxJumps then
            -- 多段跳
            canJump = true
        end

        if canJump then
            p.jumpBufferTimer = 0
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
            SFX.Play("dash", 0.6)
        end
        p.inputDash = false
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
    if not p.visualNode then return end

    -- =====================
    -- 撞墙 squash 触发
    -- =====================
    if p.hitWallX ~= 0 and p.body then
        local vx = math.abs(p.body.linearVelocity.x)
        -- 只有水平速度足够大才触发（避免贴墙静止时触发）
        if vx > 2.0 then
            local squashAmount = math.min(vx / 25.0, 0.3)
            if squashAmount > 0.04 then
                p.squashScaleX = 1.0 - squashAmount       -- 横向压扁
                p.squashScaleY = 1.0 + squashAmount * 0.5 -- 纵向膨胀
                p.squashVelX = 0
                p.squashVelY = 0
            end
        end
    end

    -- =====================
    -- 玩家互相挤压
    -- =====================
    for _, other in ipairs(Player.list) do
        if other.index ~= p.index and other.alive and other.node and p.node then
            local dx = other.node.position.x - p.node.position.x
            local dy = other.node.position.y - p.node.position.y
            local dist = math.sqrt(dx * dx + dy * dy)
            -- 方块有效尺寸约0.9，两个贴在一起时 dist ≈ 0.9
            if dist < 0.95 and dist > 0.01 then
                local overlap = 0.95 - dist  -- 重叠程度
                local squeeze = overlap * 0.15  -- 形变量（柔和）
                if squeeze > 0.03 then
                    -- 沿挤压方向压缩
                    if math.abs(dx) > math.abs(dy) then
                        -- 水平挤压
                        p.squashScaleX = math.min(p.squashScaleX, 1.0 - squeeze)
                        p.squashScaleY = math.max(p.squashScaleY, 1.0 + squeeze * 0.4)
                    else
                        -- 垂直挤压
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

    -- 安全钳位，防止极端形变
    p.squashScaleX = math.max(0.5, math.min(1.5, p.squashScaleX))
    p.squashScaleY = math.max(0.5, math.min(1.5, p.squashScaleY))

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
    if p.body then
        local vy = p.body.linearVelocity.y
        if vy > 2.0 then
            -- 上升：眼睛看上方
            targetOffsetY = math.min(vy / 15.0, 1.0) * 0.10
        elseif vy < -2.0 then
            -- 下落：眼睛看下方
            targetOffsetY = math.max(vy / 15.0, -1.0) * 0.10
        end
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

    -- 破坏地图方块
    local destroyed = mapModule_.Explode(centerGX, centerGY, actualRadius)

    -- 检测范围内其他玩家（杀伤范围同比缩放）
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
                    Player.Kill(other, "explosion")
                    print("[Player] Player " .. p.index .. " killed Player " .. other.index .. "!")
                end
            end
        end
    end

    -- 生成爆炸粒子特效
    Player.SpawnExplosionFX(pos, p.index)

    -- 屏幕震动（强度随爆炸半径缩放）
    local shakeIntensity = 0.15 + actualRadius * 0.05  -- 1格≈0.20, 7格≈0.50
    Camera.Shake(shakeIntensity, 0.25)

    -- 爆炸音效
    SFX.Play("explosion", 0.8)

    print("[Player] Player " .. p.index .. " exploded! Radius=" .. actualRadius .. " Destroyed=" .. destroyed .. " blocks")
end

--- 生成爆炸粒子特效
---@param pos Vector3 爆炸中心
---@param playerIndex number 玩家编号（用于颜色）
function Player.SpawnExplosionFX(pos, playerIndex)
    if scene_ == nil then return end

    local fxNode = scene_:CreateChild("ExplosionFX")
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
    local ringNode = scene_:CreateChild("ShockwaveFX")
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

--- 击杀玩家
---@param p table
---@param reason string "explosion"|"fall"
function Player.Kill(p, reason)
    if not p.alive then return end
    if p.invincibleTimer > 0 then return end

    p.alive = false
    p.respawnTimer = Config.RespawnDelay

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

        -- 爆炸死亡：喷溅特效 + 哭脸形象（用保存的死亡位置）
        if reason == "explosion" then
            Player.SpawnSplatFX(deathPos, p.index)
            Player.SpawnDeathFace(p, deathPos)
        end
    end

    SFX.Play("death", 0.7)

    print("[Player] Player " .. p.index .. " died (" .. reason .. ")")
end

--- 生成玩家被炸死的喷溅特效
---@param pos Vector3 死亡位置
---@param playerIndex number 玩家编号（用于颜色）
function Player.SpawnSplatFX(pos, playerIndex)
    if scene_ == nil then return end

    local color = Config.PlayerColors[playerIndex]
    local r, g, b = color.r, color.g, color.b

    -- 主喷溅粒子：大量碎片向四周飞散
    local fxNode = scene_:CreateChild("SplatFX")
    fxNode.position = Vector3(pos.x, pos.y, -0.3)

    local effect = ParticleEffect:new()

    local mat = Material:new()
    mat:SetTechnique(0, pbrAlphaTechnique_)
    mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, 0.9)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(r * 0.3, g * 0.3, b * 0.3)))
    mat:SetShaderParameter("Metallic", Variant(0.05))
    mat:SetShaderParameter("Roughness", Variant(0.6))
    effect:SetMaterial(mat)

    effect:SetNumParticles(50)
    effect:SetEmitterType(EMITTER_SPHERE)
    effect:SetEmitterSize(Vector3(0.15, 0.15, 0.05))

    -- 向四周飞散（偏 2D 平面）
    effect:SetMinDirection(Vector3(-1, -0.5, -0.05))
    effect:SetMaxDirection(Vector3(1, 1.2, 0.05))
    effect:SetMinVelocity(5.0)
    effect:SetMaxVelocity(12.0)
    effect:SetDampingForce(3.0)
    effect:SetConstantForce(Vector3(0, -10, 0))  -- 重力让碎片下坠

    -- 粒子大小（小颗粒碎片感）
    effect:SetMinParticleSize(Vector2(0.03, 0.03))
    effect:SetMaxParticleSize(Vector2(0.1, 0.1))

    -- 生命期
    effect:SetMinTimeToLive(0.2)
    effect:SetMaxTimeToLive(0.5)

    -- 旋转
    effect:SetMinRotationSpeed(-300)
    effect:SetMaxRotationSpeed(300)

    -- 短暂爆发
    effect:SetMinEmissionRate(300)
    effect:SetMaxEmissionRate(400)
    effect:SetActiveTime(0.08)
    effect:SetInactiveTime(999)

    -- 颜色渐变：玩家色 → 深色 → 消失
    effect:SetNumColorFrames(3)
    effect:SetColorFrame(0, ColorFrame(Color(r, g, b, 1.0), 0.0))
    effect:SetColorFrame(1, ColorFrame(Color(r * 0.6, g * 0.6, b * 0.6, 0.8), 0.4))
    effect:SetColorFrame(2, ColorFrame(Color(r * 0.2, g * 0.2, b * 0.2, 0.0), 1.0))

    local emitter = fxNode:CreateComponent("ParticleEmitter")
    emitter.effect = effect
    emitter.emitting = true
    emitter.autoRemoveMode = REMOVE_NODE
end

--- 在死亡位置生成哭脸贴图（替代角色形象，直到重生时移除）
---@param p table 玩家数据
---@param pos Vector3 死亡位置
function Player.SpawnDeathFace(p, pos)
    if scene_ == nil then return end

    -- 移除之前可能残留的哭脸
    Player.RemoveDeathFace(p)

    -- 与角色完全重合：角色 visualNode 的 scale 是 0.9，BlockSize 是 1.0
    -- 角色实际视觉尺寸 = BlockSize * 0.9 = 0.9 x 0.9
    local charSize = Config.BlockSize * 0.9

    local fxNode = scene_:CreateChild("DeathFace_" .. p.index)
    -- 位置与角色节点位置完全一致（角色的 node.position 就是中心点）
    fxNode.position = Vector3(pos.x, pos.y, 0)

    -- 用平面模型贴图，面朝摄像机（摄像机在 Z=-40 看向 +Z）
    -- Plane 默认在 XZ 平面，法线 +Y；左手坐标系绕 X 轴旋转 -90° 使法线指向 -Z（面向摄像机）
    local planeNode = fxNode:CreateChild("FacePlane")
    planeNode.position = Vector3(0, 0, -0.5)  -- 角色正面 z 偏移
    planeNode.scale = Vector3(charSize, 1.0, charSize) -- Plane 默认 1x1，缩放到角色大小
    planeNode.rotation = Quaternion(-90, Vector3.RIGHT) -- 法线从 +Y 转到 -Z，面向摄像机

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

    print("[Player] SpawnDeathFace for player " .. p.index .. " at (" .. pos.x .. ", " .. pos.y .. ")")

    p.deathFaceNode = fxNode
end

--- 移除哭脸贴图
---@param p table 玩家数据
function Player.RemoveDeathFace(p)
    if p.deathFaceNode then
        p.deathFaceNode:Remove()
        p.deathFaceNode = nil
    end
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
        p.inputCharging = false
        p.inputExplodeRelease = false
        p.wasChargingInput = false

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

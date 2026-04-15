-- ============================================================================
-- Player.lua - 玩家实体系统
-- 管理：移动/跳跃/冲刺/能量/爆炸/死亡/重生
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local SFX = require("SFX")

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
local boxModel_ = nil

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
    boxModel_ = cache:GetResource("Model", "Models/Box.mdl")
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
    node.scale = Vector3(0.9, 0.9, 0.9)

    -- 方块外观
    local model = node:CreateComponent("StaticModel")
    model.model = boxModel_

    local mat = Material:new()
    mat:SetTechnique(0, pbrTechnique_)
    mat:SetShaderParameter("MatDiffColor", Variant(Config.PlayerColors[index]))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Config.PlayerEmissive[index]))
    mat:SetShaderParameter("Metallic", Variant(0.1))
    mat:SetShaderParameter("Roughness", Variant(0.5))
    model:SetMaterial(mat)
    model.castShadows = true

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
        body = body,
        material = mat,
        isHuman = isHuman,

        -- 移动
        onGround = false,
        wasOnGround = false,   -- 上一帧是否在地面（用于着陆检测）
        hitCeiling = false,    -- 本帧是否撞到天花板
        jumpCount = 0,

        -- 土狼时间 & 跳跃缓冲
        coyoteTimer = 0,       -- 离开地面后的计时（<= CoyoteTime 时仍可跳）
        jumpBufferTimer = 0,   -- 按下跳跃后的计时（<= JumpBufferTime 时着地自动跳）
        jumpHeld = false,      -- 跳跃键是否持续按住（用于可变跳跃高度）

        -- 冲刺
        dashTimer = 0,        -- >0 表示冲刺中
        dashCooldown = 0,     -- 冲刺冷却计时
        dashDir = 1,          -- 冲刺方向 1/-1
        lastFaceDir = 1,      -- 最后面朝方向

        -- 能量
        energy = 0,

        -- 爆炸
        exploding = false,     -- 是否在爆炸前摇中
        explodeTimer = 0,
        explodeRecovery = 0,   -- 爆炸后摇

        -- 生命状态
        alive = true,
        respawnTimer = 0,
        invincibleTimer = 0,

        -- 比赛
        finished = false,      -- 是否已到达终点
        finishOrder = 0,       -- 到达终点的名次

        -- 曲线跳跃状态
        curveJumping = false,   -- 是否处于曲线跳跃中
        jumpPhase = "none",     -- "rise" | "fall" | "none"
        jumpElapsed = 0,        -- 当前阶段已经过时间
        jumpStartY = 0,         -- 跳跃起始 Y 坐标

        -- 输入缓存（AI 或人类写入）
        inputMoveX = 0,
        inputJump = false,
        inputDash = false,
        inputExplode = false,
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
    end

    if foundGround then
        self.playerData.onGround = true
    end
    if hitCeiling then
        self.playerData.hitCeiling = true
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
        -- 曲线跳跃中落地 → 结束跳跃
        if p.curveJumping then
            p.curveJumping = false
            p.jumpPhase = "none"
        end
        -- 着陆时检查跳跃缓冲：缓冲窗口内有按键 → 自动起跳
        if p.jumpBufferTimer > 0 then
            p.jumpBufferTimer = 0
            Player.StartCurveJump(p)
        end
    end

    -- 无敌计时
    if p.invincibleTimer > 0 then
        p.invincibleTimer = p.invincibleTimer - dt
        -- 闪烁效果
        local blink = (math.floor(p.invincibleTimer * 10) % 2 == 0)
        if p.node then
            local model = p.node:GetComponent("StaticModel")
            if model then
                model.enabled = blink
            end
        end
        if p.invincibleTimer <= 0 then
            -- 确保显示
            local model = p.node:GetComponent("StaticModel")
            if model then model.enabled = true end
        end
    end

    -- 爆炸后摇
    if p.explodeRecovery > 0 then
        p.explodeRecovery = p.explodeRecovery - dt
        return  -- 后摇期间不能移动
    end

    -- 爆炸前摇
    if p.exploding then
        p.explodeTimer = p.explodeTimer - dt
        -- 红色闪烁效果
        Player.UpdateExplodeVisual(p)
        if p.explodeTimer <= 0 then
            Player.DoExplode(p)
        end
        return  -- 前摇期间不能移动
    end

    -- 冲刺冷却
    if p.dashCooldown > 0 then
        p.dashCooldown = p.dashCooldown - dt
    end

    -- 更新移动
    Player.UpdateMovement(p, dt)

    -- 能量自动充能
    Player.UpdateEnergy(p, dt)

    -- 处理爆炸输入（仅在当前帧能量足够时触发，否则丢弃）
    if p.inputExplode then
        if p.energy >= 1.0 then
            Player.StartExplode(p)
        end
        p.inputExplode = false  -- 无论是否触发都清除，防止信号锁存
    end

    -- 死亡区域检测
    if p.node and p.node.position.y < Config.DeathY then
        Player.Kill(p, "fall")
    end

    -- 终点检测
    if p.node and MapData.IsAtFinish(p.node.position.x, p.node.position.y) then
        p.finished = true
        print("[Player] Player " .. p.index .. " reached the finish!")
    end

    -- 保存本帧地面状态，下帧用于着陆检测
    p.wasOnGround = p.onGround
    -- 重置帧碰撞状态
    p.onGround = false    -- 每帧重置，碰撞回调会重新设置
    p.hitCeiling = false   -- 每帧重置天花板碰撞
end

--- 曲线跳跃：计算当前阶段的 Y 位移（相对于起跳点）
--- 上升阶段：y(t) = H * (1 - (1-t)^e)，t = elapsed / riseTime
--- 下落阶段：y(t) = H * (1 - t^e)，t = elapsed / fallTime
---@param phase string "rise" | "fall"
---@param elapsed number 当前阶段已过时间
---@return number Y 位移（相对起跳点）
local function CurveJumpY(phase, elapsed)
    local H = Config.JumpHeight
    if phase == "rise" then
        local T = Config.JumpRiseTime
        local e = Config.JumpRiseExponent
        local t = math.min(elapsed / T, 1.0)
        return H * (1.0 - (1.0 - t) ^ e)
    else -- fall
        local T = Config.JumpFallTime
        local e = Config.JumpFallExponent
        local t = math.min(elapsed / T, 1.0)
        return H * (1.0 - t ^ e)
    end
end

--- 启动曲线跳跃（提取为独立函数，UpdateOne 的 jumpBuffer 也会调用）
---@param p table
function Player.StartCurveJump(p)
    p.curveJumping = true
    p.jumpPhase = "rise"
    p.jumpElapsed = 0
    p.jumpStartY = p.node.position.y
    p.jumpCount = p.jumpCount + 1
    p.coyoteTimer = Config.CoyoteTime + 1  -- 跳跃后禁止再次土狼跳

    -- 清零当前 Y 速度，由曲线接管
    if p.body then
        local vel = p.body.linearVelocity
        p.body.linearVelocity = Vector3(vel.x, 0, 0)
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
        -- 冲刺打断曲线跳跃
        if p.curveJumping then
            p.curveJumping = false
            p.jumpPhase = "none"
        end
        p.body.linearVelocity = Vector3(p.dashDir * Config.DashSpeed, 0, 0)
        return
    end

    -- =====================
    -- 水平移动（独立于跳跃）
    -- =====================
    local moveX = p.inputMoveX
    local speed = Config.MoveSpeed

    local finalVx
    if p.onGround and not p.curveJumping then
        -- 地面：直接设置速度
        finalVx = moveX * speed
    else
        -- 空中控制（跳跃中 或 自由下落）
        speed = speed * Config.AirControlRatio
        local targetVx = moveX * speed
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
    if p.hitCeiling and p.curveJumping and p.jumpPhase == "rise" then
        -- 撞到天花板 → 立刻切换到下落阶段
        p.jumpPhase = "fall"
        p.jumpElapsed = 0
        -- 以当前实际位置作为顶点（不是理论顶点）
        p.jumpStartY = p.node.position.y
        -- 立刻给一个向下的小速度，避免卡在天花板
        p.body.linearVelocity = Vector3(finalVx, -1.0, 0)
    end

    -- =====================
    -- 可变跳跃高度（松开跳跃键 → 截断上升）
    -- =====================
    if p.curveJumping and p.jumpPhase == "rise" and not p.jumpHeld then
        -- 松开了跳跃键 → 提前切换到下落阶段
        -- 但要给一个最低上升时间（避免按键过短导致完全不跳）
        local minRiseRatio = 0.25  -- 至少完成 25% 的上升
        if p.jumpElapsed >= Config.JumpRiseTime * minRiseRatio then
            p.jumpPhase = "fall"
            p.jumpElapsed = 0
            p.jumpStartY = p.node.position.y  -- 以当前位置为顶点
        end
    end

    -- =====================
    -- 曲线跳跃驱动 Y 轴
    -- =====================
    if p.curveJumping then
        p.jumpElapsed = p.jumpElapsed + dt

        if p.jumpPhase == "rise" then
            local displacement = CurveJumpY("rise", p.jumpElapsed)
            local targetY = p.jumpStartY + displacement

            -- 用速度驱动（让物理引擎处理碰撞）
            local currentY = p.node.position.y
            local vy = (targetY - currentY) / dt

            -- 检查是否上升阶段结束
            if p.jumpElapsed >= Config.JumpRiseTime then
                -- 切换到下落阶段
                p.jumpPhase = "fall"
                p.jumpElapsed = 0
                p.jumpStartY = currentY + (targetY - currentY)  -- 实际顶点 Y
            end

            p.body.linearVelocity = Vector3(finalVx, vy, 0)

        elseif p.jumpPhase == "fall" then
            -- 计算当前下落进度（归一化 0~1）
            local T_fall = Config.JumpFallTime
            local fallProgress = math.min(p.jumpElapsed / T_fall, 1.0)

            -- =====================
            -- 顶点滞空（Apex Hang Time）
            -- 在下落初期（刚过顶点），减缓时间流速 → 滞空感
            -- =====================
            local effectiveDt = dt
            if fallProgress < Config.ApexHangThreshold then
                effectiveDt = dt * Config.ApexHangGravityMul
                -- 减慢 jumpElapsed 增长（上面已经 += dt，需要补偿）
                p.jumpElapsed = p.jumpElapsed - dt + effectiveDt
            end

            local displacement = CurveJumpY("fall", p.jumpElapsed)
            local currentHeight = displacement  -- CurveJumpY("fall") 返回 H*(1-t^e)，从 H 递减到 0
            local targetY = p.jumpStartY - (Config.JumpHeight - currentHeight)

            local currentY = p.node.position.y
            local vy = (targetY - currentY) / dt

            -- 下落阶段结束 或 落地
            if p.jumpElapsed >= T_fall or p.onGround then
                p.curveJumping = false
                p.jumpPhase = "none"
                -- 落地后恢复物理控制，清零 Y 速度
                p.body.linearVelocity = Vector3(finalVx, 0, 0)
                return
            end

            p.body.linearVelocity = Vector3(finalVx, vy, 0)
        end
    else
        -- 非跳跃中：正常物理 Y（重力自然下落）
        p.body.linearVelocity = Vector3(finalVx, vel.y, 0)
    end

    -- =====================
    -- 跳跃输入（土狼时间 + 缓冲联合判定）
    -- =====================
    if p.jumpBufferTimer > 0 and not p.curveJumping then
        -- 判断是否可以跳跃
        local canJump = false

        if p.onGround then
            -- 在地面上
            canJump = (p.jumpCount < Config.MaxJumps)
        elseif p.coyoteTimer <= Config.CoyoteTime then
            -- 土狼时间窗口内（刚离开地面不久）
            canJump = (p.jumpCount < Config.MaxJumps)
        elseif p.jumpCount > 0 and p.jumpCount < Config.MaxJumps then
            -- 多段跳（空中二段跳等）
            canJump = true
        end

        if canJump then
            p.jumpBufferTimer = 0
            Player.StartCurveJump(p)
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

--- 爆炸前摇红色闪烁
---@param p table
function Player.UpdateExplodeVisual(p)
    if not p.material then return end
    -- 快速闪烁：原始颜色 ↔ 红色，频率随前摇剩余时间加快
    local freq = 6 + (Config.ExplosionWindup - p.explodeTimer) / Config.ExplosionWindup * 14  -- 6→20 Hz
    local flash = math.sin(p.explodeTimer * freq * math.pi * 2)
    if flash > 0 then
        -- 红色
        p.material:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.15, 0.1, 1.0)))
        p.material:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.05, 0.02)))
    else
        -- 恢复原色
        local c = Config.PlayerColors[p.index]
        local e = Config.PlayerEmissive[p.index]
        p.material:SetShaderParameter("MatDiffColor", Variant(c))
        p.material:SetShaderParameter("MatEmissiveColor", Variant(e))
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
end

-- ============================================================================
-- 爆炸
-- ============================================================================

--- 开始爆炸前摇
---@param p table
function Player.StartExplode(p)
    if p.exploding then return end
    p.exploding = true
    p.explodeTimer = Config.ExplosionWindup
    p.inputExplode = false
    print("[Player] Player " .. p.index .. " charging explosion!")
end

--- 执行爆炸
---@param p table
function Player.DoExplode(p)
    p.exploding = false
    p.energy = 0
    p.explodeRecovery = Config.ExplosionRecovery
    Player.RestoreMaterial(p)

    if p.node == nil then return end

    local pos = p.node.position
    local centerGX, centerGY = mapModule_.WorldToGrid(pos.x, pos.y)

    -- 破坏地图方块
    local destroyed = mapModule_.Explode(centerGX, centerGY, Config.ExplosionRadius)

    -- 检测范围内其他玩家
    local radius = Config.ExplosionRadius * Config.BlockSize
    for _, other in ipairs(Player.list) do
        if other.index ~= p.index and other.alive and other.invincibleTimer <= 0 then
            if other.node then
                local diff = other.node.position - pos
                local dist = math.sqrt(diff.x * diff.x + diff.y * diff.y)
                if dist <= radius then
                    Player.Kill(other, "explosion")
                    print("[Player] Player " .. p.index .. " killed Player " .. other.index .. "!")
                end
            end
        end
    end

    -- 生成爆炸粒子特效
    Player.SpawnExplosionFX(pos, p.index)

    -- 爆炸音效
    SFX.Play("explosion", 0.8)

    print("[Player] Player " .. p.index .. " exploded! Destroyed " .. destroyed .. " blocks")
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

    -- 创建粒子材质（透明）
    local mat = Material:new()
    mat:SetTechnique(0, pbrAlphaTechnique_)
    local color = Config.PlayerColors[playerIndex]
    mat:SetShaderParameter("MatDiffColor", Variant(Color(color.r, color.g, color.b, 0.8)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(color.r * 0.5, color.g * 0.5, color.b * 0.5)))
    mat:SetShaderParameter("Metallic", Variant(0.1))
    mat:SetShaderParameter("Roughness", Variant(0.5))
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

    -- 颜色渐变：亮 → 暗 → 消失
    effect:SetNumColorFrames(3)
    effect:SetColorFrame(0, ColorFrame(Color(1.0, 0.9, 0.5, 1.0), 0.0))
    effect:SetColorFrame(1, ColorFrame(Color(color.r, color.g, color.b, 0.8), 0.3))
    effect:SetColorFrame(2, ColorFrame(Color(0.2, 0.2, 0.2, 0.0), 1.0))

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
    ringMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.8, 0.3, 0.6)))
    ringMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.3, 0.05)))
    ringMat:SetShaderParameter("Metallic", Variant(0.0))
    ringMat:SetShaderParameter("Roughness", Variant(1.0))
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
    ringEffect:SetColorFrame(0, ColorFrame(Color(1.0, 0.9, 0.4, 0.8), 0.0))
    ringEffect:SetColorFrame(1, ColorFrame(Color(1.0, 0.5, 0.1, 0.0), 1.0))

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

    -- 隐藏节点
    if p.node then
        p.node.enabled = false
    end

    SFX.Play("death", 0.7)

    print("[Player] Player " .. p.index .. " died (" .. reason .. ")")
end

--- 重生玩家
---@param p table
function Player.Respawn(p)
    p.alive = true
    p.invincibleTimer = Config.InvincibleDuration
    p.energy = 0
    p.exploding = false
    p.explodeTimer = 0
    p.explodeRecovery = 0
    Player.RestoreMaterial(p)
    p.jumpCount = 0
    p.wasOnGround = false
    p.dashTimer = 0
    p.dashCooldown = 0
    p.curveJumping = false
    p.jumpPhase = "none"
    p.jumpElapsed = 0
    p.jumpStartY = 0

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
        p.alive = true
        p.finished = false
        p.finishOrder = 0
        p.energy = 0
        p.exploding = false
        p.explodeTimer = 0
        p.explodeRecovery = 0
        Player.RestoreMaterial(p)
        p.invincibleTimer = 0
        p.respawnTimer = 0
        p.jumpCount = 0
        p.wasOnGround = false
        p.dashTimer = 0
        p.dashCooldown = 0
        p.curveJumping = false
        p.jumpPhase = "none"
        p.jumpElapsed = 0
        p.jumpStartY = 0
        p.inputMoveX = 0
        p.inputJump = false
        p.inputDash = false
        p.inputExplode = false

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

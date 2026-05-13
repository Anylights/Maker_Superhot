-- ============================================================================
-- Player.lua - 玩家实体系统
-- 管理：移动/跳跃/冲刺/能量/爆炸/死亡/重生
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local SFX = require("SFX")
local Camera = require("Camera")
local RandomEvent = require("RandomEvent")
local CharacterClass = require("CharacterClass")
local Economy = require("Economy")

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

-- 圆形粒子纹理 & Unlit 透明技术缓存
local circleTexture_ = nil
local unlitAlphaTechnique_ = nil



-- ============================================================================
-- 粒子辅助
-- ============================================================================

--- 程序化生成圆形粒子纹理（白色实心圆，硬边缘）
---@param size number 纹理尺寸（像素，正方形）
---@return Texture2D
local function createCircleTexture(size)
    local img = Image()
    img:SetSize(size, size, 4)  -- RGBA
    local center = size * 0.5
    local radius = center - 1.0
    for y = 0, size - 1 do
        for x = 0, size - 1 do
            local dx = (x + 0.5) - center
            local dy = (y + 0.5) - center
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= radius then
                img:SetPixel(x, y, Color(1, 1, 1, 1))  -- 实心白
            else
                img:SetPixel(x, y, Color(1, 1, 1, 0))  -- 完全透明
            end
        end
    end
    local tex = Texture2D:new()
    tex:SetData(img, false)
    return tex
end

--- 提升颜色饱和度（找到主导通道，压低其他通道）
---@param r number
---@param g number
---@param b number
---@return number, number, number
local function boostSaturation(r, g, b)
    local maxC = math.max(r, g, b, 0.01)
    local sr = math.min(1.0, (r / maxC) ^ 0.3)
    local sg = math.min(1.0, (g / maxC) ^ 0.3)
    local sb = math.min(1.0, (b / maxC) ^ 0.3)
    local minS = math.min(sr, sg, sb)
    sr = math.min(1.0, sr - minS * 0.6 + 0.05)
    sg = math.min(1.0, sg - minS * 0.6 + 0.05)
    sb = math.min(1.0, sb - minS * 0.6 + 0.05)
    return sr, sg, sb
end

--- 创建圆形粒子材质（Unlit + 透明通道 + 圆形纹理）
---@param r number 红
---@param g number 绿
---@param b number 蓝
---@return Material
local function makeCircleMat(r, g, b)
    local mat = Material:new()
    mat:SetTechnique(0, unlitAlphaTechnique_)
    mat:SetTexture(0, circleTexture_)  -- TU_DIFFUSE
    mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, 1.0)))
    return mat
end

--- 通过 playerIndex 获取玩家专属颜色（优先使用存储的职业色）
---@param playerIndex number
---@return Color
local function getPlayerColor(playerIndex)
    for _, p in ipairs(Player.list) do
        if p.index == playerIndex and p.bodyColor then
            return p.bodyColor
        end
    end
    return Config.GetPlayerColor(playerIndex)
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
    unlitAlphaTechnique_ = cache:GetResource("Technique", "Techniques/DiffUnlitAlpha.xml")
    circleTexture_ = createCircleTexture(32)
    Player.list = {}
    print("[Player] Initialized")
end

--- 在节点上创建视觉组件（模型、描边、眼睛）
---@param node Node 父节点
---@param index number 玩家编号 1~N
---@param classId? number 职业 ID（传入时使用职业专属颜色）
---@return Node visualNode, Material mat, Material outlineMat
function Player.CreateVisuals(node, index, classId)
    -- 决定颜色来源：有职业 ID 时用职业色，否则用默认配色
    local bodyColor, outlineColor, emissiveColor
    if classId and classId > 1 then
        bodyColor, outlineColor, emissiveColor = CharacterClass.GetColors(classId)
    else
        bodyColor = Config.GetPlayerColor(index)
        outlineColor = Config.GetPlayerOutlineColor(index)
        emissiveColor = Config.GetPlayerEmissive(index)
    end

    local visualNode = node:CreateChild("Visual")
    visualNode.scale = Vector3(0.9, 0.9, 0.9)

    -- 方块外观（圆角矩形）
    local geom = visualNode:CreateComponent("CustomGeometry")
    mapModule_.BuildRoundedBox(geom, Config.BlockSize, 0.1)
    geom.castShadows = true

    local mat = Material:new()
    mat:SetTechnique(0, pbrTechnique_)
    mat:SetShaderParameter("MatDiffColor", Variant(bodyColor))
    mat:SetShaderParameter("MatEmissiveColor", Variant(emissiveColor))
    mat:SetShaderParameter("Metallic", Variant(Config.RubberMetallic))
    mat:SetShaderParameter("Roughness", Variant(Config.RubberRoughness))
    geom:SetMaterial(mat)

    -- 描边子节点
    local outlineNode = visualNode:CreateChild("Outline")
    outlineNode.position = Vector3(0, 0, 0.1)
    outlineNode.scale = Vector3(1.15, 1.15, 1.0)
    local outlineGeom = outlineNode:CreateComponent("CustomGeometry")
    mapModule_.BuildRoundedBox(outlineGeom, Config.BlockSize, 0.1)
    outlineGeom.castShadows = false
    local outlineMat = Material:new()
    outlineMat:SetTechnique(0, pbrTechnique_)
    outlineMat:SetShaderParameter("MatDiffColor", Variant(outlineColor))
    outlineMat:SetShaderParameter("Metallic", Variant(0.0))
    outlineMat:SetShaderParameter("Roughness", Variant(1.0))
    outlineGeom:SetMaterial(outlineMat)

    -- 眼睛
    local sphereModel = cache:GetResource("Model", "Models/Sphere.mdl")
    local unlitTechnique = cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml")
    local eyeMat = Material:new()
    eyeMat:SetTechnique(0, unlitTechnique)
    eyeMat:SetShaderParameter("MatDiffColor", Variant(outlineColor))

    local eyeBaseX = 0.16
    local eyeBaseY = 0.06
    local eyeBaseZ = -0.48
    local eyeRadius = 0.22

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

    -- 眩晕闪烁黑色覆盖层（半透明黑色，略大于本体，默认隐藏）
    local stunOverlay = visualNode:CreateChild("StunOverlay")
    stunOverlay.position = Vector3(0, 0, -0.15)  -- 在本体前面
    stunOverlay.scale = Vector3(1.06, 1.06, 1.0)
    stunOverlay.enabled = false
    local stunGeom = stunOverlay:CreateComponent("CustomGeometry")
    mapModule_.BuildRoundedBox(stunGeom, Config.BlockSize, 0.1)
    stunGeom.castShadows = false
    local stunMat = Material:new()
    stunMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    stunMat:SetShaderParameter("MatDiffColor", Variant(Color(0, 0, 0, 0.45)))
    stunMat:SetShaderParameter("Metallic", Variant(0.0))
    stunMat:SetShaderParameter("Roughness", Variant(1.0))
    stunGeom:SetMaterial(stunMat)

    return visualNode, mat, outlineMat
end

--- 创建一个玩家
---@param index number 玩家编号 1~4
---@param isHuman boolean 是否人类控制
---@return table 玩家数据
function Player.Create(index, isHuman)
    local spawnX, spawnY = MapData.GetSpawnPosition(index)

    local node = scene_:CreateChild("Player_" .. index, LOCAL)
    node.position = Vector3(spawnX, spawnY, 0)

    -- 视觉组件
    local eyeBaseX = 0.16
    local eyeBaseY = 0.06
    local eyeBaseZ = -0.48
    local eyeRadius = 0.22

    -- 人类玩家（index==1）使用选中的职业，AI 随机分配职业
    local classId = 1
    if isHuman then
        classId = Economy.GetSelectedClassId()
    else
        classId = math.random(1, CharacterClass.GetCount())
    end
    local visualNode, mat, outlineMat = Player.CreateVisuals(node, index, classId)

    -- 动态刚体
    local body = node:GetComponent("RigidBody") or node:CreateComponent("RigidBody")
    body.mass = 1.0
    body.friction = 0.3  -- 降低摩擦：移动由代码直接设置速度，低摩擦避免被地面约束卡住
    body.linearDamping = 0.05
    body.collisionLayer = 2
    body.collisionMask = 0xFFFF
    body.collisionEventMode = COLLISION_ALWAYS
    -- CCD 防止高速下砸穿墙（胶囊半径0.45，阈值略小于半径）
    body.ccdRadius = 0.4
    body.ccdMotionThreshold = 0.3

    -- 2.5D 约束：锁 Z 移动，锁全旋转
    body.linearFactor = Vector3(1, 1, 0)
    body.angularFactor = Vector3(0, 0, 0)

    local shape = node:GetComponent("CollisionShape") or node:CreateComponent("CollisionShape")
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

        -- 欲穷千里事件：落地额外得分
        lastLandingBaseHeight = 0,  -- 上次落地时的基础高度分
        climbBonusScore = 0,        -- 欲穷千里累计额外加分

        -- 爆炸（蓄力机制）
        charging = false,       -- 是否在蓄力中
        chargeTimer = 0,        -- 蓄力计时（0→ChargeTime）
        chargeProgress = 0,     -- 蓄力进度（0→1）
        explodeRecovery = 0,    -- 爆炸后摇

        -- 生命状态
        alive = true,
        respawnTimer = 0,
        invincibleTimer = 0,

        -- 计分系统
        score = 0,             -- 总分
        heightScore = 0,       -- 高度得分（实时计算）
        killScore = 0,         -- 击杀得分
        pickupScore = 0,       -- 拾取得分
        maxHeight = 0,         -- 历史最高高度（用于统计）
        deaths = 0,            -- 死亡次数
        slamHits = 0,          -- 下砸砸晕人数
        gotSlammed = 0,        -- 被别人砸晕次数
        gotKilled = 0,         -- 被别人击杀次数
        killScoreBonus = 0,    -- 检查点累加的额外击杀基础分

        -- 检查点
        activatedCheckpoints = {},  -- 已激活的检查点 { [cpIndex]=true }
        lastCheckpointIndex = 0,    -- 最后激活的检查点索引

        -- 击杀统计（每回合重置）
        kills = 0,             -- 本回合击杀数
        killStreak = 0,        -- 连续击杀数（死亡重置）
        multiKillCount = 0,    -- 短时间内连续击杀数
        multiKillTimer = 0,    -- 连杀判定计时器

        -- 输入缓存（AI 或人类写入）
        inputMoveX = 0,
        inputJump = false,
        inputDash = false,
        inputCharging = false,       -- 右键按住中
        inputExplodeRelease = false, -- 右键松开（触发爆炸）
        inputSlam = false,           -- 下砸输入
        wasChargingInput = false,    -- 上帧右键状态（用于松开检测）

        -- 下砸
        slamming = false,            -- 是否正在下砸中

        -- 眩晕（被下砸击中后）
        stunTimer = 0,               -- 眩晕剩余时间（> 0 表示正在眩晕中）

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

    -- =====================
    -- 拖尾粒子发射器（在 scene 下创建，每帧跟随角色位置）
    -- 必须挂在 scene 而不是角色子节点，否则粒子会跟着角色走，看不到拖尾
    -- =====================
    do
        local trailEffect = ParticleEffect:new()
        local clr
        if classId and classId > 1 then
            clr = CharacterClass.GetColors(classId)
        else
            clr = Config.GetPlayerColor(index)
        end
        -- 拉到最大亮度确保鲜艳
        local maxC = math.max(clr.r, clr.g, clr.b, 0.01)
        local tR = math.min(1.0, clr.r / maxC * 1.2)
        local tG = math.min(1.0, clr.g / maxC * 1.2)
        local tB = math.min(1.0, clr.b / maxC * 1.2)
        local trailMat = makeCircleMat(tR, tG, tB)
        trailEffect:SetMaterial(trailMat)
        trailEffect:SetNumParticles(60)
        trailEffect:SetEmitterType(EMITTER_SPHERE)
        trailEffect:SetEmitterSize(Vector3(0.15, 0.15, 0.05))
        -- 粒子几乎不主动移动，留在原地形成拖尾
        trailEffect:SetMinDirection(Vector3(-0.1, 0.05, 0))
        trailEffect:SetMaxDirection(Vector3(0.1, 0.15, 0))
        trailEffect:SetMinVelocity(0.05)
        trailEffect:SetMaxVelocity(0.3)
        trailEffect:SetDampingForce(3.0)
        -- 粒子大小
        trailEffect:SetMinParticleSize(Vector2(0.08, 0.08))
        trailEffect:SetMaxParticleSize(Vector2(0.15, 0.15))
        trailEffect:SetSizeAdd(-0.08)
        -- 生命期
        trailEffect:SetMinTimeToLive(0.2)
        trailEffect:SetMaxTimeToLive(0.45)
        trailEffect:SetMinEmissionRate(30)
        trailEffect:SetMaxEmissionRate(50)
        -- 颜色渐变：鲜艳 → 淡出
        trailEffect:SetNumColorFrames(3)
        trailEffect:SetColorFrame(0, ColorFrame(Color(tR, tG, tB, 0.85), 0.0))
        trailEffect:SetColorFrame(1, ColorFrame(Color(tR, tG, tB, 0.4), 0.5))
        trailEffect:SetColorFrame(2, ColorFrame(Color(tR, tG, tB, 0.0), 1.0))

        -- 挂在 scene 下而不是角色子节点
        local trailNode = scene_:CreateChild("TrailFX_" .. index, LOCAL)
        local pos = node.position
        trailNode.position = Vector3(pos.x, pos.y, -0.3)
        local trailEmitter = trailNode:CreateComponent("ParticleEmitter")
        trailEmitter.effect = trailEffect
        trailEmitter.emitting = false  -- 初始关闭，运动时开启

        p.trailEmitter = trailEmitter
        p.trailNode = trailNode
        p.trailColorR = tR
        p.trailColorG = tG
        p.trailColorB = tB
    end

    -- 注入职业属性（覆盖默认 Config 值）
    CharacterClass.ApplyToPlayer(p, classId)

    -- 存储玩家专属颜色（用于材质恢复、粒子特效等）
    if classId and classId > 1 then
        p.bodyColor, p.outlineColor, p.emissiveColor = CharacterClass.GetColors(classId)
    else
        p.bodyColor = Config.GetPlayerColor(index)
        p.outlineColor = Config.GetPlayerOutlineColor(index)
        p.emissiveColor = Config.GetPlayerEmissive(index)
    end

    -- 注册碰撞回调
    node:CreateScriptObject("PlayerCollision")
    local scriptObj = node:GetScriptObject()
    if scriptObj then
        scriptObj.playerData = p
    end

    table.insert(Player.list, p)
    local className = p.className or "默认"
    print("[Player] Created player " .. index .. (isHuman and " (human)" or " (AI)") .. " class=" .. className)

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
    if Player.frozen then return end  -- 结算时冻结，跳过所有更新
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

    -- (终点庆祝已移除 - 大地图模式无终点)

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

        -- 下砸着陆：击退周围玩家
        if p.slamming then
            p.slamming = false
            Player.DoSlamLanding(p)
        end

        -- 欲穷千里事件：落地时给予额外高度得分（累加，不会回退）
        if RandomEvent.GetHeightScoreMul() > 1 and p.node then
            local spawnX, spawnY = MapData.GetSpawnPosition(p.index)
            local heightBlocks = (p.node.position.y - spawnY) / Config.BlockSize
            local currentBase = math.floor(heightBlocks) * Config.HeightScoreUnit
            local extraScore = (currentBase - p.lastLandingBaseHeight) * 2  -- 额外2倍部分
            if extraScore > 0 then
                p.climbBonusScore = (p.climbBonusScore or 0) + extraScore
                if p.isHuman then
                    local HUD = require("HUD")
                    HUD.AddScorePopup(
                        p.node.position.x, p.node.position.y + 1.5,
                        "额外加分+" .. math.floor(extraScore), 80, 255, 80, 22
                    )
                end
            end
            p.lastLandingBaseHeight = currentBase
        end

        -- 着陆时检查跳跃缓冲：缓冲窗口内有按键 → 自动起跳
        if p.jumpBufferTimer > 0 then
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

    -- 爆炸后摇（后摇期间不接受输入，但重力和物理仍生效）
    if p.explodeRecovery > 0 then
        p.explodeRecovery = p.explodeRecovery - dt
        -- 清除所有输入，但不跳过物理更新
        p.inputMoveX = 0
        p.inputJump = false
        p.inputDash = false
        p.inputSlam = false
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

    -- 眩晕状态（被下砸击中后，禁止所有输入，水平速度快速衰减）
    if p.stunTimer > 0 then
        p.stunTimer = p.stunTimer - dt
        -- 清除所有输入
        p.inputMoveX = 0
        p.inputJump = false
        p.inputDash = false
        p.inputSlam = false
        p.inputCharging = false
        p.inputExplodeRelease = false
        -- 打断蓄力
        if p.charging then
            p.charging = false
            p.chargeTimer = 0
            p.chargeProgress = 0
            Player.RestoreMaterial(p)
        end
        -- 应用重力，水平速度快速衰减
        if p.body then
            local vel = p.body.linearVelocity
            local vy = vel.y
            if not p.onGround and vy < 0 then
                local extraGravity = -9.81 * (Config.FallGravityMul - 1.0)
                vy = vy + extraGravity * dt
                if vy < -Config.MaxFallSpeed then vy = -Config.MaxFallSpeed end
            end
            local vx = vel.x * 0.88
            p.body.linearVelocity = Vector3(vx, vy, 0)
        end
        goto updateVisuals
    end

    -- 蓄力中（允许水平移动，禁止跳跃/冲刺）
    if p.charging then
        -- 持续蓄力：计时递增
        p.chargeTimer = math.min(p.chargeTimer + dt, p.explosionChargeTime)
        p.chargeProgress = p.chargeTimer / p.explosionChargeTime
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

    -- 检查点激活检测（必须从上方踩上去，不能从下方顶到）
    if p.node and p.onGround then
        local cpIndex = MapData.GetCheckpointAt(p.node.position.y, true)
        if cpIndex and not p.activatedCheckpoints[cpIndex] then
            p.activatedCheckpoints[cpIndex] = true
            p.lastCheckpointIndex = cpIndex
            p.killScoreBonus = (p.killScoreBonus or 0) + 10
            local pp = p.node.position
            SFX.Play("pickup_large", 0.7, pp.x, pp.y)
            Camera.Shake(0.1, 0.15)
            -- 通知 HUD 显示浮动文字
            if Player.onCheckpointBonus then
                Player.onCheckpointBonus(p.index, p.killScoreBonus)
            end
            print("[Player] Player " .. p.index .. " activated checkpoint #" .. cpIndex ..
                  " at Y=" .. MapData.CheckpointYList[cpIndex] ..
                  " killScoreBonus=" .. p.killScoreBonus)
        end
    end

    -- 高度得分实时计算（基于当前 Y 位置）
    if p.node then
        local currentY = p.node.position.y
        -- 记录历史最高
        if currentY > p.maxHeight then
            p.maxHeight = currentY
        end
        -- 实时高度得分 = (当前Y - 出生Y) / BlockSize * HeightScoreUnit
        -- 下降时分数也减少
        local spawnX, spawnY = MapData.GetSpawnPosition(p.index)
        local heightBlocks = (currentY - spawnY) / Config.BlockSize
        p.heightScore = math.floor(heightBlocks) * Config.HeightScoreUnit
        -- 总分 = 高度 + 击杀 + 拾取 + 欲穷千里额外
        p.score = p.heightScore + p.killScore + p.pickupScore + (p.climbBonusScore or 0)
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

--- 冲刺击退：冲刺中撞到其他玩家，将其击飞
---@param p table
function Player.DoDashKnockback(p)
    if not p.node then return end
    local pos = p.node.position
    for _, other in ipairs(Player.list) do
        if other.index ~= p.index and other.alive and other.node and other.body then
            if other.invincibleTimer > 0 then goto continueKB end
            local diff = other.node.position - pos
            local dist = math.sqrt(diff.x * diff.x + diff.y * diff.y)
            if dist < Config.DashKnockbackRadius then
                -- 击飞方向：冲刺方向
                local kbDir = p.dashDir
                other.body.linearVelocity = Vector3(
                    kbDir * Config.DashKnockbackForce,
                    Config.DashKnockbackUp,
                    0
                )
                -- 触发被击退的视觉效果
                other.squashScaleX = 0.7
                other.squashScaleY = 1.3
                other.squashVelX = 0
                other.squashVelY = 0
                local op = other.node.position
                SFX.Play("explosion", 0.4, op.x, op.y)
            end
            ::continueKB::
        end
    end
end

--- 下砸着陆：击退周围小范围的玩家（水平力）
---@param p table
function Player.DoSlamLanding(p)
    if not p.node then return end
    local pos = p.node.position

    -- 视觉效果：强力压扁
    p.squashScaleY = 0.55
    p.squashScaleX = 1.45
    p.squashVelY = 0
    p.squashVelX = 0

    -- 屏幕震动（仅在视野内，幅度适中）
    Camera.Shake(0.10, 0.15, pos)
    SFX.Play("explosion", 0.6, pos.x, pos.y)

    -- 下砸落地粒子爆发（水平扩散的小圆粒子，高饱和鲜艳）
    if scene_ then
        local slamFXNode = scene_:CreateChild("SlamLandFX", LOCAL)
        slamFXNode.position = Vector3(pos.x, pos.y - 0.3, -0.4)

        local slamEffect = ParticleEffect:new()
        local clr = getPlayerColor(p.index)
        -- 直接用原始颜色并拉到最大亮度，确保鲜艳
        local maxC = math.max(clr.r, clr.g, clr.b, 0.01)
        local sR = math.min(1.0, clr.r / maxC * 1.2)
        local sG = math.min(1.0, clr.g / maxC * 1.2)
        local sB = math.min(1.0, clr.b / maxC * 1.2)
        local slamMat = makeCircleMat(sR, sG, sB)
        slamEffect:SetMaterial(slamMat)
        slamEffect:SetNumParticles(30)
        slamEffect:SetEmitterType(EMITTER_SPHERE)
        slamEffect:SetEmitterSize(Vector3(0.25, 0.05, 0.1))
        -- 水平向两侧扩散，略微向上
        slamEffect:SetMinDirection(Vector3(-1.0, 0.2, -0.1))
        slamEffect:SetMaxDirection(Vector3(1.0, 0.8, 0.1))
        slamEffect:SetMinVelocity(2.5)
        slamEffect:SetMaxVelocity(6.0)
        slamEffect:SetDampingForce(3.0)
        slamEffect:SetConstantForce(Vector3(0, -5, 0))
        slamEffect:SetMinParticleSize(Vector2(0.06, 0.06))
        slamEffect:SetMaxParticleSize(Vector2(0.12, 0.12))
        slamEffect:SetSizeAdd(-0.08)
        slamEffect:SetMinTimeToLive(0.2)
        slamEffect:SetMaxTimeToLive(0.45)
        slamEffect:SetMinEmissionRate(250)
        slamEffect:SetMaxEmissionRate(350)
        slamEffect:SetActiveTime(0.08)
        slamEffect:SetInactiveTime(999)
        slamEffect:SetNumColorFrames(3)
        -- 起始极亮白闪 → 高饱和玩家色 → 淡出
        slamEffect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 1.0, 1.0), 0.0))
        slamEffect:SetColorFrame(1, ColorFrame(Color(sR, sG, sB, 0.9), 0.2))
        slamEffect:SetColorFrame(2, ColorFrame(Color(sR, sG, sB, 0.0), 1.0))

        local slamEmitter = slamFXNode:CreateComponent("ParticleEmitter")
        slamEmitter.effect = slamEffect
        slamEmitter.emitting = true
        slamEmitter.autoRemoveMode = REMOVE_NODE
    end

    -- 击退周围玩家
    local hitAnyPlayer = false
    for _, other in ipairs(Player.list) do
        if other.index ~= p.index and other.alive and other.node and other.body then
            if other.invincibleTimer > 0 then goto continueSL end
            local diff = other.node.position - pos
            local dx = math.abs(diff.x)
            local dy = math.abs(diff.y)
            -- 水平距离在 SlamRadius 内且垂直距离合理（不超过 2 格）
            if dx < Config.SlamRadius and dy < 2.0 and (dx + dy) > 0.01 then
                hitAnyPlayer = true
                p.slamHits = (p.slamHits or 0) + 1
                other.gotSlammed = (other.gotSlammed or 0) + 1
                -- 击飞方向：从砸地点水平朝外
                local kbDir = (diff.x >= 0) and 1 or -1
                other.body.linearVelocity = Vector3(
                    kbDir * Config.SlamKnockbackForce,
                    Config.SlamKnockbackUp,
                    0
                )
                -- 被击退视觉效果
                other.squashScaleX = 0.7
                other.squashScaleY = 1.3
                other.squashVelX = 0
                other.squashVelY = 0
                -- 施加眩晕（使用攻击者的职业眩晕时长）
                other.stunTimer = p.slamStunDuration
            end
            ::continueSL::
        end
    end

    -- 砸中其他玩家时弹跳起（约两次跳跃高度）
    if hitAnyPlayer and p.body then
        local bounceSpeed = p.jumpSpeed * 1.42  -- sqrt(2) ≈ 两倍跳跃高度
        p.body.linearVelocity = Vector3(p.body.linearVelocity.x, bounceSpeed, 0)
        p.slamming = false
        p.jumpCount = 0  -- 重置跳跃次数，允许空中再跳
        -- 弹跳视觉：纵向拉伸
        p.squashScaleY = 1.35
        p.squashScaleX = 0.7
        p.squashVelY = 0
        p.squashVelX = 0
    end
end

--- 执行跳跃：给一个向上初速度，由物理重力自然完成抛物线
---@param p table
function Player.DoJump(p)
    p.jumpCount = p.jumpCount + 1
    p.coyoteTimer = Config.CoyoteTime + 1  -- 跳跃后禁止再次土狼跳

    -- 设置向上初速度（受随机事件"超重"影响）
    if p.body then
        local vel = p.body.linearVelocity
        local jumpSpeed = p.jumpSpeed * RandomEvent.GetJumpSpeedMul()
        p.body.linearVelocity = Vector3(vel.x, jumpSpeed, 0)
    end

    if p.node then
        local pp = p.node.position
        SFX.Play("jump", 0.5, pp.x, pp.y)
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
        p.body.linearVelocity = Vector3(p.dashDir * p.dashSpeed, 0, 0)
        -- 冲刺击退：检测附近其他玩家并击飞
        Player.DoDashKnockback(p)
        return
    end

    -- 下砸输入处理：空中按下S → 快速下落
    if p.inputSlam and not p.onGround and not p.slamming then
        p.slamming = true
        p.inputSlam = false
        -- 立即给一个超快的向下速度
        p.body.linearVelocity = Vector3(0, -Config.SlamSpeed, 0)
        local pp = p.node.position
        SFX.Play("dash", 0.5, pp.x, pp.y)
        return
    end
    p.inputSlam = false

    -- 下砸中：锁定为高速下落，忽略水平输入
    if p.slamming then
        local slamVy = p.body.linearVelocity.y
        -- 保持高速下落（比正常重力快）
        if slamVy > -Config.SlamSpeed then
            slamVy = -Config.SlamSpeed
        end
        p.body.linearVelocity = Vector3(0, slamVy, 0)
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

    -- 随机事件：八级大风（施加水平力）
    local windForce = RandomEvent.GetWindForce()
    if windForce ~= 0 then
        finalVx = finalVx + windForce * dt
    end

    p.body.linearVelocity = Vector3(finalVx, vy, 0)

    -- =====================
    -- 跳跃输入（土狼时间 + 缓冲联合判定）
    -- =====================
    if p.jumpBufferTimer > 0 then
        local canJump = false

        if p.onGround then
            canJump = (p.jumpCount < p.maxJumps)
        elseif p.coyoteTimer <= Config.CoyoteTime then
            canJump = (p.jumpCount < p.maxJumps)
        elseif p.jumpCount < p.maxJumps then
            -- 空中跳跃（含第一次起跳和多段跳）
            canJump = true
        end

        if canJump then
            p.jumpBufferTimer = 0
            Player.DoJump(p)
        end
    end

    -- =====================
    -- 冲刺（支持双冲职业）
    -- =====================
    if p.inputDash then
        local canDash = false
        if p.dashCooldown <= 0 then
            -- 冷却已结束，重置已用次数
            p.dashesUsed = 0
            canDash = true
        elseif (p.dashCount or 1) > 1 and (p.dashesUsed or 0) < p.dashCount then
            -- 双冲职业：冷却中但还有剩余冲刺次数
            canDash = true
        end
        if canDash then
            p.dashTimer = p.dashDuration
            p.dashDir = p.lastFaceDir
            p.dashesUsed = (p.dashesUsed or 0) + 1
            -- 只在第一次冲刺时启动冷却
            if p.dashesUsed == 1 then
                p.dashCooldown = p.dashCooldownMax or Config.DashCooldown
            end
            local pp = p.node.position
            SFX.Play("dash", 0.6, pp.x, pp.y)
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
    -- 眩晕形变：在挤扁和压扁之间来回振荡 + 黑色闪烁
    -- =====================
    local stunOverlay = p.visualNode and p.visualNode:GetChild("StunOverlay")
    if p.stunTimer > 0 then
        local wobbleSpeed = 10.0  -- 振荡频率（越大越快）
        local wobbleAmount = 0.25 -- 形变幅度（0.25 = ±25%）
        -- 用 sin 产生平滑来回：正值→横向拉伸纵向压扁，负值→横向压扁纵向拉伸
        local wave = math.sin(p.stunTimer * wobbleSpeed * math.pi)
        p.squashScaleX = 1.0 + wave * wobbleAmount
        p.squashScaleY = 1.0 - wave * wobbleAmount

        -- 黑色覆盖层快速闪烁（8Hz，每秒闪8次）
        if stunOverlay then
            local blink = math.sin(p.stunTimer * 16.0 * math.pi) > 0
            stunOverlay.enabled = blink
        end
    else
        if stunOverlay then stunOverlay.enabled = false end
    end

    -- =====================
    -- 拖尾粒子：每帧同步位置到角色 + 速度判断开关
    -- trailNode 挂在 scene 下，需要手动跟随
    -- =====================
    if p.trailEmitter and p.trailNode and p.node then
        local pos = p.node.position
        p.trailNode.position = Vector3(pos.x, pos.y, -0.3)
        local vel = p.body and p.body.linearVelocity or Vector3.ZERO
        local speedH = math.abs(vel.x)
        local speedV = vel.y
        -- 水平移动速度 > 1.5 或下落速度 > 3.0 时开启拖尾
        local shouldTrail = p.alive and (speedH > 1.5 or speedV < -3.0)
        p.trailEmitter.emitting = shouldTrail
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

    if isSquished and p.stunTimer <= 0 then
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
    -- 4) 眩晕表情：眼睛绕圆圈转动 @_@
    -- =====================
    if p.stunTimer > 0 then
        local spinSpeed = 12.0  -- 转圈速度（弧度/秒）
        local spinRadius = 0.06 -- 转圈半径
        local t = p.stunTimer * spinSpeed
        local ox = math.cos(t) * spinRadius
        local oy = math.sin(t) * spinRadius

        -- 两只眼睛反向旋转，形成 @_@ 效果
        eyeL.position = Vector3(-bx + ox, by + oy, bz)
        eyeR.position = Vector3(bx - ox, by - oy, bz)

        -- 眼睛略微缩小表示虚弱
        local smallR = r * 0.75
        eyeL.scale = Vector3(smallR, smallR, r * 0.35)
        eyeR.scale = Vector3(smallR, smallR, r * 0.35)
        eyeL.rotation = Quaternion.IDENTITY
        eyeR.rotation = Quaternion.IDENTITY
        return
    end

    -- =====================
    -- 5) 眨眼动画（仅在静止时触发）
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
        p.energy = p.energy + dt / p.energyChargeTime * RandomEvent.GetEnergyChargeMul()
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
        local c = p.bodyColor or Config.GetPlayerColor(p.index)
        local e = p.emissiveColor or Config.GetPlayerEmissive(p.index)
        p.material:SetShaderParameter("MatDiffColor", Variant(c))
        p.material:SetShaderParameter("MatEmissiveColor", Variant(e))
        if p.outlineMat then
            local oc = p.outlineColor or Config.GetPlayerOutlineColor(p.index)
            p.outlineMat:SetShaderParameter("MatDiffColor", Variant(oc))
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
    local c = p.bodyColor or Config.GetPlayerColor(p.index)
    local e = p.emissiveColor or Config.GetPlayerEmissive(p.index)
    p.material:SetShaderParameter("MatDiffColor", Variant(c))
    p.material:SetShaderParameter("MatEmissiveColor", Variant(e))
    -- 恢复描边颜色
    if p.outlineMat then
        local oc = p.outlineColor or Config.GetPlayerOutlineColor(p.index)
        p.outlineMat:SetShaderParameter("MatDiffColor", Variant(oc))
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

    -- 检测范围内其他玩家
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

    -- 视觉/音效
    -- 生成爆炸粒子特效
    Player.SpawnExplosionFX(pos, p.index)

    -- 屏幕震动（强度随爆炸半径缩放，仅在视野内）
    local shakeIntensity = 0.15 + actualRadius * 0.05  -- 1格≈0.20, 7格≈0.50
    Camera.Shake(shakeIntensity, 0.25, pos)

    -- 爆炸音效
    SFX.Play("explosion", 0.8, pos.x, pos.y)

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

    -- 圆形粒子材质 - 极高饱和度、低不透明度
    local color = getPlayerColor(playerIndex)
    local satR, satG, satB = boostSaturation(color.r, color.g, color.b)
    local mat = makeCircleMat(satR, satG, satB)
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

    -- 颜色渐变：极亮→饱和→微暗→回亮→消失（生命周期差异产生明暗变化）
    effect:SetNumColorFrames(5)
    effect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 0.6, 1.0), 0.0))                           -- 初始极亮闪光
    effect:SetColorFrame(1, ColorFrame(Color(satR, satG, satB, 1.0), 0.15))                        -- 高饱和玩家色
    effect:SetColorFrame(2, ColorFrame(Color(satR * 0.55, satG * 0.55, satB * 0.55, 1.0), 0.4))   -- 微暗
    effect:SetColorFrame(3, ColorFrame(Color(satR * 0.9, satG * 0.85, satB * 0.8, 1.0), 0.7))     -- 回亮
    effect:SetColorFrame(4, ColorFrame(Color(satR * 0.3, satG * 0.2, satB * 0.1, 0.0), 1.0))      -- 消失

    -- 创建发射器
    local emitter = fxNode:CreateComponent("ParticleEmitter")
    emitter.effect = effect
    emitter.emitting = true
    emitter.autoRemoveMode = REMOVE_NODE

    -- 也添加一个大的快速扩散环（冲击波）
    local ringNode = scene_:CreateChild("ShockwaveFX", LOCAL)
    ringNode.position = Vector3(pos.x, pos.y, -0.5)

    local ringEffect = ParticleEffect:new()
    local ringMat = makeCircleMat(1.0, 0.6, 0.0)
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

    ringEffect:SetNumColorFrames(3)
    ringEffect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 0.4, 1.0), 0.0))    -- 极亮黄白
    ringEffect:SetColorFrame(1, ColorFrame(Color(1.0, 0.5, 0.0, 1.0), 0.4))    -- 高饱和橙
    ringEffect:SetColorFrame(2, ColorFrame(Color(1.0, 0.2, 0.0, 0.0), 1.0))    -- 消散

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

--- 击杀玩家
---@param p table
---@param reason string "explosion"|"fall"
---@param killerIndex number|nil 击杀者玩家编号（爆炸击杀时提供）
function Player.Kill(p, reason, killerIndex)
    if not p.alive then return end
    if p.invincibleTimer > 0 then return end

    p.alive = false
    p.respawnTimer = Config.RespawnDelay
    p.deaths = (p.deaths or 0) + 1

    -- 死亡惩罚
    p.pickupScore = math.max(0, p.pickupScore - Config.DeathPenalty)
    p.score = p.heightScore + p.killScore + p.pickupScore + (p.climbBonusScore or 0)

    -- 被击杀计数
    if killerIndex and killerIndex ~= p.index then
        p.gotKilled = (p.gotKilled or 0) + 1
    end

    -- 击杀者统计与得分
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

                -- 击杀得分：(基础分 + 检查点加成) + 连杀线性加成
                local killBonus = Config.KillScoreBase + (killer.killScoreBonus or 0)
                local mkCount = killer.multiKillCount
                -- 连杀额外加分：N次连杀 = N * 单次连杀奖励（线性）
                local multiBonus = Config.MultiKillBonus[2] or 50  -- 双杀奖励作为单位
                if mkCount >= 2 then
                    killBonus = killBonus + mkCount * multiBonus
                end
                killBonus = killBonus * RandomEvent.GetKillScoreMul()
                killer.killScore = killer.killScore + killBonus
                killer.score = killer.heightScore + killer.killScore + killer.pickupScore + (killer.climbBonusScore or 0)

                -- 击杀得分头顶弹出
                if killer.node then
                    local HUD = require("HUD")
                    local label = "击杀+" .. math.floor(killBonus)
                    local r, g, b = 255, 80, 80  -- 红色
                    if RandomEvent.GetKillScoreMul() > 1 then
                        label = "嗜血击杀+" .. math.floor(killBonus)
                        r, g, b = 255, 50, 50
                    end
                    HUD.AddScorePopup(
                        killer.node.position.x, killer.node.position.y + 1.5,
                        label, r, g, b, 22
                    )
                end

                -- 通知 GameManager
                if Player.onKill then
                    Player.onKill(killerIndex, p.index, killer.multiKillCount, killer.killStreak)
                end
                break
            end
        end
    end

    -- 隐藏玩家节点 + 停止物理
    local deathPos = p.node and p.node.position or nil
    if p.node then

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

        -- 爆炸死亡：喷溅特效 + 哭脸形象
        if reason == "explosion" then
            Player.SpawnSplatFX(deathPos, p.index)
            Player.SpawnDeathFace(p, deathPos)
        end
    end

    -- 死亡重置连杀
    p.killStreak = 0

    if deathPos then
        SFX.Play("death", 0.7, deathPos.x, deathPos.y)
    else
        SFX.Play("death", 0.7)
    end

    print("[Player] Player " .. p.index .. " died (" .. reason .. ")")
end

--- 生成玩家被炸死的喷溅特效（夸张版）
---@param pos Vector3 死亡位置
---@param playerIndex number 玩家编号（用于颜色）
function Player.SpawnSplatFX(pos, playerIndex)
    if scene_ == nil then return end

    local color = getPlayerColor(playerIndex)
    local r, g, b = boostSaturation(color.r, color.g, color.b)

    -- === 第 1 层：大量碎片向四周飞散（主体喷溅） ===
    local fxNode = scene_:CreateChild("SplatFX", LOCAL)
    fxNode.position = Vector3(pos.x, pos.y, -0.3)

    local effect = ParticleEffect:new()
    local mat = makeCircleMat(r, g, b)
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

    effect:SetNumColorFrames(5)
    effect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 1.0, 1.0), 0.0))                       -- 初始白色闪光
    effect:SetColorFrame(1, ColorFrame(Color(r, g, b, 1.0), 0.12))                              -- 高饱和玩家色
    effect:SetColorFrame(2, ColorFrame(Color(r * 0.5, g * 0.5, b * 0.5, 1.0), 0.35))           -- 暗沉
    effect:SetColorFrame(3, ColorFrame(Color(r * 0.85, g * 0.85, b * 0.85, 1.0), 0.65))        -- 回亮
    effect:SetColorFrame(4, ColorFrame(Color(r * 0.2, g * 0.2, b * 0.2, 0.0), 1.0))            -- 消失

    local emitter = fxNode:CreateComponent("ParticleEmitter")
    emitter.effect = effect
    emitter.emitting = true
    emitter.autoRemoveMode = REMOVE_NODE

    -- === 第 2 层：中心闪光爆裂（白→玩家色，大粒子快速膨胀消失） ===
    local flashNode = scene_:CreateChild("SplatFlash", LOCAL)
    flashNode.position = Vector3(pos.x, pos.y, -0.35)

    local flashEffect = ParticleEffect:new()
    local flashMat = makeCircleMat(1, 1, 1)
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
    flashEffect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 0.9, 1.0), 0.0))
    flashEffect:SetColorFrame(1, ColorFrame(Color(r, g, b, 1.0), 0.35))
    flashEffect:SetColorFrame(2, ColorFrame(Color(r * 0.5, g * 0.5, b * 0.5, 0.0), 1.0))

    local flashEmitter = flashNode:CreateComponent("ParticleEmitter")
    flashEmitter.effect = flashEffect
    flashEmitter.emitting = true
    flashEmitter.autoRemoveMode = REMOVE_NODE

    -- === 第 3 层：彩色星星/碎屑飞散（白色小亮点） ===
    local starNode = scene_:CreateChild("SplatStars", LOCAL)
    starNode.position = Vector3(pos.x, pos.y, -0.32)

    local starEffect = ParticleEffect:new()
    local starMat = makeCircleMat(1, 1, 0.9)
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

    starEffect:SetNumColorFrames(4)
    starEffect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 0.9, 1.0), 0.0))       -- 极亮
    starEffect:SetColorFrame(1, ColorFrame(Color(1.0, 0.9, 0.3, 1.0), 0.25))      -- 金黄
    starEffect:SetColorFrame(2, ColorFrame(Color(r, g, b, 1.0), 0.55))             -- 玩家色
    starEffect:SetColorFrame(3, ColorFrame(Color(r * 0.3, g * 0.3, b * 0.3, 0.0), 1.0))  -- 消失

    local starEmitter = starNode:CreateComponent("ParticleEmitter")
    starEmitter.effect = starEffect
    starEmitter.emitting = true
    starEmitter.autoRemoveMode = REMOVE_NODE

    -- === 屏幕震动（仅在视野内） ===
    Camera.Shake(0.3, 0.3, pos)
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
    p.inputSlam = false
    p.slamming = false
    p.stunTimer = 0

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

    -- 回到最后检查点或起点
    local sx, sy
    local cpPos = MapData.GetCheckpointRespawnPos(p.activatedCheckpoints, mapModule_.GetGrid())
    if cpPos then
        sx, sy = cpPos.x, cpPos.y
    else
        sx, sy = MapData.GetSpawnPosition(p.index)
    end
    if p.node then
        p.node.enabled = true
        p.node.position = Vector3(sx, sy, 0)
    end
    if p.body then
        p.body.linearVelocity = Vector3(0, 0, 0)
    end

    print("[Player] Player " .. p.index .. " respawned at (" .. string.format("%.1f, %.1f", sx, sy) .. ")")
end

--- 重置所有玩家（新回合）
function Player.ResetAll()
    for _, p in ipairs(Player.list) do
        Player.RemoveDeathFace(p)
        p.alive = true

        -- 重置计分系统
        p.score = 0
        p.heightScore = 0
        p.killScore = 0
        p.pickupScore = 0
        p.climbBonusScore = 0
        p.lastLandingBaseHeight = 0
        p.maxHeight = 0
        p.deaths = 0
        p.slamHits = 0
        p.gotSlammed = 0
        p.gotKilled = 0
        p.killScoreBonus = 0
        p.activatedCheckpoints = {}
        p.lastCheckpointIndex = 0

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
        p.inputCharging = false
        p.inputExplodeRelease = false
        p.inputSlam = false
        p.wasChargingInput = false
        p.slamming = false
        p.stunTimer = 0

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

        -- 重新应用职业属性和外观（修复切换职业后能力/外观不生效的问题）
        local newClassId = p.classId or 1
        if p.isHuman then
            newClassId = Economy.GetSelectedClassId()
        end
        CharacterClass.ApplyToPlayer(p, newClassId)

        -- 更新颜色
        local bodyColor, outlineColor, emissiveColor
        if newClassId > 1 then
            bodyColor, outlineColor, emissiveColor = CharacterClass.GetColors(newClassId)
        else
            bodyColor = Config.GetPlayerColor(p.index)
            outlineColor = Config.GetPlayerOutlineColor(p.index)
            emissiveColor = Config.GetPlayerEmissive(p.index)
        end
        p.bodyColor = bodyColor
        p.outlineColor = outlineColor
        p.emissiveColor = emissiveColor

        -- 更新身体材质
        if p.material then
            p.material:SetShaderParameter("MatDiffColor", Variant(bodyColor))
            p.material:SetShaderParameter("MatEmissiveColor", Variant(emissiveColor))
        end
        -- 更新描边材质
        if p.outlineMat then
            p.outlineMat:SetShaderParameter("MatDiffColor", Variant(outlineColor))
        end
        -- 更新眼睛颜色（眼睛跟描边同色）
        if p.visualNode then
            local eyeL = p.visualNode:GetChild("EyeL")
            local eyeR = p.visualNode:GetChild("EyeR")
            if eyeL then
                local eyeLModel = eyeL:GetComponent("StaticModel")
                if eyeLModel then
                    local eyeMat = eyeLModel:GetMaterial(0)
                    if eyeMat then eyeMat:SetShaderParameter("MatDiffColor", Variant(outlineColor)) end
                end
            end
            if eyeR then
                local eyeRModel = eyeR:GetComponent("StaticModel")
                if eyeRModel then
                    local eyeMat = eyeRModel:GetMaterial(0)
                    if eyeMat then eyeMat:SetShaderParameter("MatDiffColor", Variant(outlineColor)) end
                end
            end
        end
        -- 更新拖尾粒子颜色
        if p.trailEmitter then
            local maxC = math.max(bodyColor.r, bodyColor.g, bodyColor.b, 0.01)
            local tR = math.min(1.0, bodyColor.r / maxC * 1.2)
            local tG = math.min(1.0, bodyColor.g / maxC * 1.2)
            local tB = math.min(1.0, bodyColor.b / maxC * 1.2)
            p.trailColorR = tR
            p.trailColorG = tG
            p.trailColorB = tB
            local effect = p.trailEmitter.effect
            if effect then
                effect:SetNumColorFrames(3)
                effect:SetColorFrame(0, ColorFrame(Color(tR, tG, tB, 0.85), 0.0))
                effect:SetColorFrame(1, ColorFrame(Color(tR, tG, tB, 0.4), 0.5))
                effect:SetColorFrame(2, ColorFrame(Color(tR, tG, tB, 0.0), 1.0))
            end
        end
    end
end

--- 将 AI 玩家散布到地图检查点上，模拟"正在攀爬"
function Player.ScatterAI()
    local cpList = MapData.CheckpointYList
    if #cpList == 0 then
        print("[Player] ScatterAI: no checkpoints, skip")
        return
    end
    -- 只取下方 AIScatterMaxRatio 的检查点
    local maxIdx = math.max(1, math.floor(#cpList * Config.AIScatterMaxRatio))
    local grid = mapModule_ and mapModule_.GetGrid() or nil

    for _, p in ipairs(Player.list) do
        if not p.isHuman then
            -- 随机选一个检查点
            local cpIdx = math.random(1, maxIdx)
            local cpY = cpList[cpIdx]
            -- 找检查点层的可站立 X
            local wx = (MapData.Width * 0.5) * Config.BlockSize  -- 默认中心
            if grid then
                local gridY = math.floor(cpY / Config.BlockSize) + 1
                local validXs = {}
                for x = 1, MapData.Width do
                    if grid[gridY] and grid[gridY][x] ~= Config.BLOCK_EMPTY then
                        table.insert(validXs, x)
                    end
                end
                if #validXs > 0 then
                    local rx = validXs[math.random(1, #validXs)]
                    wx = (rx - 1) * Config.BlockSize + Config.BlockSize * 0.5
                end
            end
            -- 传送
            if p.node then
                p.node.position = Vector3(wx, cpY + Config.BlockSize, 0)
            end
            if p.body then
                p.body.linearVelocity = Vector3(0, 0, 0)
            end
            -- 标记经过的检查点为已激活
            p.activatedCheckpoints = {}
            for i = 1, cpIdx do
                p.activatedCheckpoints[i] = true
            end
            p.lastCheckpointIndex = cpIdx
            p.maxHeight = cpY
            p.alive = true
            if p.visualNode then
                p.visualNode.enabled = true
            end
            print("[Player] ScatterAI: P" .. p.index .. " → CP#" .. cpIdx .. " Y=" .. cpY)
        end
    end
end

--- 冻结所有玩家（结算时调用，防止物理碰撞导致数据变化）
function Player.FreezeAll()
    for _, p in ipairs(Player.list) do
        if p.body then
            p.body.linearVelocity = Vector3(0, 0, 0)
            p.body.mass = 0  -- 变成静态体，不再受物理影响
        end
        -- 关闭拖尾粒子
        if p.trailEmitter then
            p.trailEmitter.emitting = false
        end
    end
    Player.frozen = true
    print("[Player] FreezeAll: all players frozen")
end

--- 解冻所有玩家（新一局开始时调用）
function Player.UnfreezeAll()
    for _, p in ipairs(Player.list) do
        if p.body then
            p.body.mass = 1.0  -- 恢复动态体
        end
    end
    Player.frozen = false
    print("[Player] UnfreezeAll: all players unfrozen")
end

--- 只重置所有玩家的计分，不影响位置
--- AI 玩家每局随机重新分配职业和对应外观
function Player.ResetScoresOnly()
    for _, p in ipairs(Player.list) do
        p.score = 0
        p.heightScore = 0
        p.killScore = 0
        p.pickupScore = 0
        p.climbBonusScore = 0
        p.lastLandingBaseHeight = 0
        p.maxHeight = p.node and p.node.position.y or 0
        p.deaths = 0
        p.slamHits = 0
        p.gotSlammed = 0
        p.gotKilled = 0
        p.killScoreBonus = 0
        p.kills = 0
        p.killStreak = 0
        p.multiKillCount = 0
        p.multiKillTimer = 0

        -- AI 玩家每局随机分配新职业
        if not p.isHuman then
            local newClassId = math.random(1, CharacterClass.GetCount())
            CharacterClass.ApplyToPlayer(p, newClassId)
            p.dashesUsed = 0

            local bodyColor, outlineColor, emissiveColor
            if newClassId > 1 then
                bodyColor, outlineColor, emissiveColor = CharacterClass.GetColors(newClassId)
            else
                bodyColor = Config.GetPlayerColor(p.index)
                outlineColor = Config.GetPlayerOutlineColor(p.index)
                emissiveColor = Config.GetPlayerEmissive(p.index)
            end
            p.bodyColor = bodyColor
            p.outlineColor = outlineColor
            p.emissiveColor = emissiveColor

            -- 更新身体材质
            if p.material then
                p.material:SetShaderParameter("MatDiffColor", Variant(bodyColor))
                p.material:SetShaderParameter("MatEmissiveColor", Variant(emissiveColor))
            end
            -- 更新描边材质
            if p.outlineMat then
                p.outlineMat:SetShaderParameter("MatDiffColor", Variant(outlineColor))
            end
            -- 更新眼睛颜色
            if p.visualNode then
                for _, eyeName in ipairs({"EyeL", "EyeR"}) do
                    local eye = p.visualNode:GetChild(eyeName)
                    if eye then
                        local mdl = eye:GetComponent("StaticModel")
                        if mdl then
                            local m = mdl:GetMaterial(0)
                            if m then m:SetShaderParameter("MatDiffColor", Variant(outlineColor)) end
                        end
                    end
                end
            end
            -- 更新拖尾粒子颜色
            if p.trailEmitter then
                local maxC = math.max(bodyColor.r, bodyColor.g, bodyColor.b, 0.01)
                local tR = math.min(1.0, bodyColor.r / maxC * 1.2)
                local tG = math.min(1.0, bodyColor.g / maxC * 1.2)
                local tB = math.min(1.0, bodyColor.b / maxC * 1.2)
                p.trailColorR = tR
                p.trailColorG = tG
                p.trailColorB = tB
                local effect = p.trailEmitter.effect
                if effect then
                    effect:SetNumColorFrames(3)
                    effect:SetColorFrame(0, ColorFrame(Color(tR, tG, tB, 0.85), 0.0))
                    effect:SetColorFrame(1, ColorFrame(Color(tR, tG, tB, 0.4), 0.5))
                    effect:SetColorFrame(2, ColorFrame(Color(tR, tG, tB, 0.0), 1.0))
                end
            end
            print("[Player] ResetScoresOnly: AI P" .. p.index .. " → class=" .. (p.className or "默认"))
        end
    end
    print("[Player] ResetScoresOnly: all scores zeroed")
end

--- 只重置人类玩家到出生点（全状态重置），AI 不受影响
function Player.ResetHumanToSpawn()
    for _, p in ipairs(Player.list) do
        if p.isHuman then
            Player.RemoveDeathFace(p)
            p.alive = true
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
            p.inputSlam = false
            p.wasChargingInput = false
            p.slamming = false
            p.stunTimer = 0
            p.activatedCheckpoints = {}
            p.lastCheckpointIndex = 0
            -- 重置视觉
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
            -- 传送到出生点
            local sx, sy = MapData.GetSpawnPosition(p.index)
            if p.node then
                p.node.enabled = true
                p.node.position = Vector3(sx, sy, 0)
            end
            if p.body then
                p.body.linearVelocity = Vector3(0, 0, 0)
            end

            -- 重新应用职业属性和外观（修复切换职业后能力/外观不生效）
            local newClassId = Economy.GetSelectedClassId()
            CharacterClass.ApplyToPlayer(p, newClassId)
            p.dashesUsed = 0

            local bodyColor, outlineColor, emissiveColor
            if newClassId > 1 then
                bodyColor, outlineColor, emissiveColor = CharacterClass.GetColors(newClassId)
            else
                bodyColor = Config.GetPlayerColor(p.index)
                outlineColor = Config.GetPlayerOutlineColor(p.index)
                emissiveColor = Config.GetPlayerEmissive(p.index)
            end
            p.bodyColor = bodyColor
            p.outlineColor = outlineColor
            p.emissiveColor = emissiveColor

            -- 更新身体材质
            if p.material then
                p.material:SetShaderParameter("MatDiffColor", Variant(bodyColor))
                p.material:SetShaderParameter("MatEmissiveColor", Variant(emissiveColor))
            end
            -- 更新描边材质
            if p.outlineMat then
                p.outlineMat:SetShaderParameter("MatDiffColor", Variant(outlineColor))
            end
            -- 更新眼睛颜色
            if p.visualNode then
                for _, eyeName in ipairs({"EyeL", "EyeR"}) do
                    local eye = p.visualNode:GetChild(eyeName)
                    if eye then
                        local mdl = eye:GetComponent("StaticModel")
                        if mdl then
                            local m = mdl:GetMaterial(0)
                            if m then m:SetShaderParameter("MatDiffColor", Variant(outlineColor)) end
                        end
                    end
                end
            end
            -- 更新拖尾粒子颜色
            if p.trailEmitter then
                local maxC = math.max(bodyColor.r, bodyColor.g, bodyColor.b, 0.01)
                local tR = math.min(1.0, bodyColor.r / maxC * 1.2)
                local tG = math.min(1.0, bodyColor.g / maxC * 1.2)
                local tB = math.min(1.0, bodyColor.b / maxC * 1.2)
                p.trailColorR = tR
                p.trailColorG = tG
                p.trailColorB = tB
                local effect = p.trailEmitter.effect
                if effect then
                    effect:SetNumColorFrames(3)
                    effect:SetColorFrame(0, ColorFrame(Color(tR, tG, tB, 0.85), 0.0))
                    effect:SetColorFrame(1, ColorFrame(Color(tR, tG, tB, 0.4), 0.5))
                    effect:SetColorFrame(2, ColorFrame(Color(tR, tG, tB, 0.0), 1.0))
                end
            end

            print("[Player] ResetHumanToSpawn: P" .. p.index .. " → spawn, class=" .. (p.className or "默认"))
            break
        end
    end
end

--- 添加能量
---@param p table
---@param amount number 0~1
function Player.AddEnergy(p, amount)
    p.energy = math.min(1.0, p.energy + amount)
end

--- 添加拾取得分
---@param p table
---@param points number
function Player.AddPickupScore(p, points)
    p.pickupScore = (p.pickupScore or 0) + points
    p.score = p.heightScore + p.killScore + p.pickupScore + (p.climbBonusScore or 0)
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
                -- 死亡时返回检查点或出生点位置
                local cpPos = MapData.GetCheckpointRespawnPos(p.activatedCheckpoints, mapModule_ and mapModule_.GetGrid() or nil)
                if cpPos then
                    return Vector3(cpPos.x, cpPos.y, 0)
                end
                local sx, sy = MapData.GetSpawnPosition(p.index)
                return Vector3(sx, sy, 0)
            end
        end
    end
    return nil
end

--- 终点烟花特效（三层：上升火星 + 中心爆炸 + 七彩火花）
---@param pos Vector3 触发位置（玩家位置）
---@param playerIndex number 玩家编号（决定主色）
function Player.SpawnFireworkFX(pos, playerIndex)
    if scene_ == nil then return end

    local color = getPlayerColor(playerIndex) or { r = 1, g = 0.6, b = 0.2 }
    local r, g, b = boostSaturation(color.r, color.g, color.b)
    local centerY = pos.y + 1.5

    -- === 第 1 层：从地面快速上升的金色拖尾 ===
    local trailNode = scene_:CreateChild("FireworkTrail", LOCAL)
    trailNode.position = Vector3(pos.x, pos.y + 0.3, -0.3)

    local trailEffect = ParticleEffect:new()
    local trailMat = makeCircleMat(1.0, 0.9, 0.4)
    trailEffect:SetMaterial(trailMat)

    trailEffect:SetNumParticles(40)
    trailEffect:SetEmitterType(EMITTER_SPHERE)
    trailEffect:SetEmitterSize(Vector3(0.1, 0.05, 0.05))
    trailEffect:SetMinDirection(Vector3(-0.15, 1.0, -0.05))
    trailEffect:SetMaxDirection(Vector3(0.15, 1.0, 0.05))
    trailEffect:SetMinVelocity(8.0)
    trailEffect:SetMaxVelocity(12.0)
    trailEffect:SetDampingForce(2.0)
    trailEffect:SetMinParticleSize(Vector2(0.05, 0.05))
    trailEffect:SetMaxParticleSize(Vector2(0.12, 0.12))
    trailEffect:SetMinTimeToLive(0.15)
    trailEffect:SetMaxTimeToLive(0.3)
    trailEffect:SetMinEmissionRate(200)
    trailEffect:SetMaxEmissionRate(300)
    trailEffect:SetActiveTime(0.12)
    trailEffect:SetInactiveTime(999)
    trailEffect:SetNumColorFrames(3)
    trailEffect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 0.5, 1.0), 0.0))     -- 极亮金
    trailEffect:SetColorFrame(1, ColorFrame(Color(1.0, 0.6, 0.1, 1.0), 0.45))    -- 深橙
    trailEffect:SetColorFrame(2, ColorFrame(Color(1.0, 0.3, 0.0, 0.0), 1.0))     -- 消散

    local trailEmitter = trailNode:CreateComponent("ParticleEmitter")
    trailEmitter.effect = trailEffect
    trailEmitter.emitting = true
    trailEmitter.autoRemoveMode = REMOVE_NODE

    -- === 第 2 层：中心爆开（七彩火花，球形发射） ===
    local burstNode = scene_:CreateChild("FireworkBurst", LOCAL)
    burstNode.position = Vector3(pos.x, centerY, -0.35)

    local burstEffect = ParticleEffect:new()
    local burstMat = makeCircleMat(r, g, b)
    burstEffect:SetMaterial(burstMat)

    burstEffect:SetNumParticles(150)
    burstEffect:SetEmitterType(EMITTER_SPHERE)
    burstEffect:SetEmitterSize(Vector3(0.05, 0.05, 0.02))
    burstEffect:SetMinDirection(Vector3(-1, -1, -0.05))
    burstEffect:SetMaxDirection(Vector3(1, 1, 0.05))
    burstEffect:SetMinVelocity(7.0)
    burstEffect:SetMaxVelocity(14.0)
    burstEffect:SetDampingForce(1.8)
    burstEffect:SetConstantForce(Vector3(0, -8, 0))
    burstEffect:SetMinParticleSize(Vector2(0.06, 0.06))
    burstEffect:SetMaxParticleSize(Vector2(0.16, 0.16))
    burstEffect:SetMinTimeToLive(0.6)
    burstEffect:SetMaxTimeToLive(1.4)
    burstEffect:SetMinRotationSpeed(-300)
    burstEffect:SetMaxRotationSpeed(300)
    burstEffect:SetMinEmissionRate(800)
    burstEffect:SetMaxEmissionRate(1000)
    burstEffect:SetActiveTime(0.1)
    burstEffect:SetInactiveTime(999)
    burstEffect:SetNumColorFrames(5)
    burstEffect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 1.0, 1.0), 0.0))                      -- 白色闪光
    burstEffect:SetColorFrame(1, ColorFrame(Color(r, g, b, 1.0), 0.15))                            -- 高饱和玩家色
    burstEffect:SetColorFrame(2, ColorFrame(Color(r * 0.5, g * 0.5, b * 0.5, 1.0), 0.4))          -- 暗沉
    burstEffect:SetColorFrame(3, ColorFrame(Color(r * 0.85, g * 0.7, b * 0.4, 1.0), 0.65))       -- 回暖偏移色
    burstEffect:SetColorFrame(4, ColorFrame(Color(0, 0, 0, 0), 1.0))                               -- 消失

    local burstEmitter = burstNode:CreateComponent("ParticleEmitter")
    burstEmitter.effect = burstEffect
    burstEmitter.emitting = true
    burstEmitter.autoRemoveMode = REMOVE_NODE

    -- === 第 3 层：白色闪光（爆炸瞬间的强光） ===
    local flashNode = scene_:CreateChild("FireworkFlash", LOCAL)
    flashNode.position = Vector3(pos.x, centerY, -0.4)

    local flashEffect = ParticleEffect:new()
    local flashMat = makeCircleMat(1, 1, 1)
    flashEffect:SetMaterial(flashMat)

    flashEffect:SetNumParticles(6)
    flashEffect:SetEmitterType(EMITTER_SPHERE)
    flashEffect:SetEmitterSize(Vector3(0.05, 0.05, 0.01))
    flashEffect:SetMinDirection(Vector3(-0.3, -0.3, 0))
    flashEffect:SetMaxDirection(Vector3(0.3, 0.3, 0))
    flashEffect:SetMinVelocity(0.3)
    flashEffect:SetMaxVelocity(1.0)
    flashEffect:SetDampingForce(3.0)
    flashEffect:SetMinParticleSize(Vector2(0.5, 0.5))
    flashEffect:SetMaxParticleSize(Vector2(1.0, 1.0))
    flashEffect:SetSizeAdd(2.0)
    flashEffect:SetMinTimeToLive(0.15)
    flashEffect:SetMaxTimeToLive(0.3)
    flashEffect:SetMinEmissionRate(200)
    flashEffect:SetMaxEmissionRate(200)
    flashEffect:SetActiveTime(0.04)
    flashEffect:SetInactiveTime(999)
    flashEffect:SetNumColorFrames(3)
    flashEffect:SetColorFrame(0, ColorFrame(Color(1.0, 1.0, 0.9, 1.0), 0.0))    -- 极亮
    flashEffect:SetColorFrame(1, ColorFrame(Color(r, g, b, 1.0), 0.4))           -- 玩家色
    flashEffect:SetColorFrame(2, ColorFrame(Color(r * 0.4, g * 0.4, b * 0.4, 0.0), 1.0))  -- 消失

    local flashEmitter = flashNode:CreateComponent("ParticleEmitter")
    flashEmitter.effect = flashEffect
    flashEmitter.emitting = true
    flashEmitter.autoRemoveMode = REMOVE_NODE

    Camera.Shake(0.2, 0.4, pos)
end

return Player

-- ============================================================================
-- Shared.lua - 超级红温！ 网络共享常量与工具
-- ============================================================================
-- Server / Client / Standalone 三端共用
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")

local Shared = {}

-- Re-export for convenience
Shared.Config  = Config
Shared.MapData = MapData

-- ============================================================================
-- Remote Events
-- ============================================================================

Shared.EVENTS = {
    CLIENT_READY      = "E_ClientReady",       -- 客户端场景准备完毕
    ASSIGN_ROLE       = "E_AssignRole",         -- 服务端 → 客户端：分配角色节点
    KILL_EVENT        = "E_KillEvent",          -- 服务端 → 客户端：击杀通知
    SCORE_UPDATE      = "E_ScoreUpdate",        -- 服务端 → 客户端：分数更新
    GAME_STATE        = "E_GameState",          -- 服务端 → 客户端：游戏状态变更
    PICKUP_COLLECTED  = "E_PickupCollected",    -- 服务端 → 客户端：道具被拾取
    START_GAME        = "E_StartGame",          -- 客户端 → 服务端：请求开始游戏
    REQUEST_RESTART   = "E_RequestRestart",     -- 客户端 → 服务端：请求重新开始
    BLOCK_DESTROYED   = "E_BlockDestroyed",     -- 服务端 → 客户端：方块被破坏
    EXPLOSION_EVENT   = "E_ExplosionEvent",     -- 服务端 → 客户端：爆炸效果通知
    PLAYER_DIED       = "E_PlayerDied",         -- 服务端 → 客户端：玩家死亡通知
    PLAYER_RESPAWN    = "E_PlayerRespawn",       -- 服务端 → 客户端：玩家复活通知
}

-- ============================================================================
-- Controls Bit Flags (客户端 → 服务端，通过 connection.controls.buttons)
-- ============================================================================

Shared.CTRL = {
    LEFT            = 1,      -- 向左移动
    RIGHT           = 2,      -- 向右移动
    JUMP            = 4,      -- 跳跃 (PulseButtonMask)
    DASH            = 8,      -- 冲刺 (PulseButtonMask)
    SLAM            = 16,     -- 下砸 (PulseButtonMask)
    CHARGE          = 32,     -- 蓄力中（持续按住）
    EXPLODE_RELEASE = 64,     -- 释放爆炸 (PulseButtonMask)
}

-- 需要 PulseButtonMask 的一次性输入（防止 UDP 丢包）
Shared.PULSE_BUTTONS = Shared.CTRL.JUMP | Shared.CTRL.DASH | Shared.CTRL.SLAM | Shared.CTRL.EXPLODE_RELEASE

-- ============================================================================
-- Node Vars (同步的节点变量名)
-- ============================================================================

Shared.VARS = {
    ENTITY_TYPE   = "EntityType",    -- string: "Player", "Pickup", "Block"
    PLAYER_INDEX  = "PlayerIndex",   -- int: 玩家编号 1~N
    PLAYER_ALIVE  = "PlayerAlive",   -- bool: 是否存活
    PLAYER_FACING = "PlayerFacing",  -- int: 朝向 1=右, -1=左
    PICKUP_TYPE   = "PickupType",    -- int: 0=small, 1=large
    SCORE         = "Score",         -- int: 玩家当前分数
    MAX_HEIGHT    = "MaxHeight",     -- float: 玩家到达的最高高度
    IS_HUMAN      = "IsHuman",      -- bool: 是否为人类玩家
}

-- ============================================================================
-- Entity Types
-- ============================================================================

Shared.ENTITY_PLAYER  = "Player"
Shared.ENTITY_PICKUP  = "Pickup"
Shared.ENTITY_BLOCK   = "Block"

-- ============================================================================
-- Game State Constants (与 GameManager 状态一致)
-- ============================================================================

Shared.STATE_MENU      = 0
Shared.STATE_COUNTDOWN = 1
Shared.STATE_PLAYING   = 2
Shared.STATE_RESULT    = 3

-- ============================================================================
-- Register Remote Events
-- ============================================================================

--- 注册所有远程事件（Server 和 Client 都必须在 Start 时调用）
function Shared.RegisterEvents()
    for _, eventName in pairs(Shared.EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
end

-- ============================================================================
-- Shared Scene Creation
-- ============================================================================

--- 创建基础场景（Server 和 Client 共用）
--- 服务端: 只创建物理/碰撞，不创建渲染组件
--- 客户端: 同时创建渲染组件
---@param isServer boolean
---@return Scene
function Shared.CreateScene(isServer)
    local scene = Scene()

    -- 基础组件（LOCAL — 不同步，每端自己创建）
    scene:CreateComponent("Octree", LOCAL)
    scene:CreateComponent("DebugRenderer", LOCAL)

    local physicsWorld = scene:CreateComponent("PhysicsWorld", LOCAL)
    physicsWorld:SetGravity(Vector3(0, -28.0, 0))

    -- 光照（仅客户端）
    if not isServer then
        local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Daytime.xml")
        if lightGroupFile then
            local lightGroup = scene:CreateChild("LightGroup", LOCAL)
            lightGroup:LoadXML(lightGroupFile:GetRoot())
            -- 设置雾色
            local zoneComp = lightGroup:GetComponent("Zone")
            if not zoneComp then
                for i = 0, lightGroup.numChildren - 1 do
                    local child = lightGroup:GetChild(i)
                    zoneComp = child:GetComponent("Zone")
                    if zoneComp then break end
                end
            end
            if zoneComp then
                zoneComp.fogColor = Color(0.95, 0.82, 0.68)
            end
        else
            Shared.CreateFallbackLighting(scene)
        end
    end

    -- 死亡区域（LOCAL — 纯碰撞检测，每端独立）
    local deathZone = scene:CreateChild("DeathZone", LOCAL)
    deathZone.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
    deathZone.scale = Vector3(MapData.Width + 20, 2, 10)
    local dzBody = deathZone:CreateComponent("RigidBody", LOCAL)
    dzBody.trigger = true
    dzBody.collisionLayer = 4
    dzBody.collisionMask = 2
    local dzShape = deathZone:CreateComponent("CollisionShape", LOCAL)
    dzShape:SetBox(Vector3(1, 1, 1))

    return scene
end

--- 更新死亡区域位置（地图重新生成后调用）
---@param scene Scene
function Shared.UpdateDeathZone(scene)
    local dz = scene:GetChild("DeathZone", false)
    if dz then
        dz.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
        dz.scale = Vector3(MapData.Width + 20, 2, 10)
    end
end

--- 后备光照（无 LightGroup 文件时）
---@param scene Scene
function Shared.CreateFallbackLighting(scene)
    local zoneNode = scene:CreateChild("Zone", LOCAL)
    local zone = zoneNode:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(-200.0, 200.0)
    zone.ambientColor = Color(0.40, 0.35, 0.30)
    zone.fogColor = Color(0.95, 0.82, 0.68)
    zone.fogStart = 80.0
    zone.fogEnd = 150.0

    local lightNode = scene:CreateChild("DirectionalLight", LOCAL)
    lightNode.direction = Vector3(0.5, -1.0, 0.3)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_DIRECTIONAL
    light.color = Color(1.0, 0.95, 0.9)
    light.castShadows = true
    light.shadowBias = BiasParameters(0.00025, 0.5)
    light.shadowCascade = CascadeParameters(10.0, 50.0, 200.0, 0.0, 0.8)
end

-- ============================================================================
-- Background Gradient (仅客户端)
-- ============================================================================

--- 创建背景渐变平面
---@param scene Scene
function Shared.CreateBackgroundPlane(scene)
    local topColor = Config.BgColorTop
    local botColor = Config.BgColorBot
    local size = 200
    local strips = 8
    local bgNode = scene:CreateChild("BackgroundGradient", LOCAL)
    bgNode.position = Vector3(0, 0, 5)

    local pbrTech = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")

    for i = 0, strips - 1 do
        local t0 = i / strips
        local t1 = (i + 1) / strips
        local r0 = topColor[1] + (botColor[1] - topColor[1]) * t0
        local g0 = topColor[2] + (botColor[2] - topColor[2]) * t0
        local b0 = topColor[3] + (botColor[3] - topColor[3]) * t0
        local r1 = topColor[1] + (botColor[1] - topColor[1]) * t1
        local g1 = topColor[2] + (botColor[2] - topColor[2]) * t1
        local b1 = topColor[3] + (botColor[3] - topColor[3]) * t1
        local midR = (r0 + r1) * 0.5
        local midG = (g0 + g1) * 0.5
        local midB = (b0 + b1) * 0.5

        local stripNode = bgNode:CreateChild("Strip" .. i, LOCAL)
        local yTop = size * (1 - t0 * 2)
        local yBot = size * (1 - t1 * 2)
        stripNode.position = Vector3(0, (yTop + yBot) * 0.5, 0)
        stripNode.scale = Vector3(size * 2, yTop - yBot, 0.1)

        local model = stripNode:CreateComponent("StaticModel", LOCAL)
        model.model = cache:GetResource("Model", "Models/Box.mdl")
        model.castShadows = false

        local mat = Material:new()
        mat:SetTechnique(0, pbrTech)
        mat:SetShaderParameter("MatDiffColor", Variant(Color(midR, midG, midB, 1.0)))
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(midR * 0.3, midG * 0.3, midB * 0.3)))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mat:SetShaderParameter("Roughness", Variant(1.0))
        model:SetMaterial(mat)
    end
end

-- ============================================================================
-- Controls → Player Input Mapping (Server 端使用)
-- ============================================================================

--- 从 Controls 读取并写入 player 的 input 字段
---@param p table Player 实例
---@param controls Controls
function Shared.ApplyControlsToPlayer(p, controls)
    local buttons = controls.buttons

    -- 方向：LEFT/RIGHT → inputMoveX
    local moveX = 0
    if buttons & Shared.CTRL.LEFT ~= 0 then
        moveX = -1
    elseif buttons & Shared.CTRL.RIGHT ~= 0 then
        moveX = 1
    end
    p.inputMoveX = moveX

    -- 一次性输入（PulseButtonMask 保证不丢）
    if buttons & Shared.CTRL.JUMP ~= 0 then
        p.inputJump = true
    end
    if buttons & Shared.CTRL.DASH ~= 0 then
        p.inputDash = true
    end
    if buttons & Shared.CTRL.SLAM ~= 0 then
        p.inputSlam = true
    end

    -- 持续输入
    p.inputCharging = (buttons & Shared.CTRL.CHARGE ~= 0)

    -- 释放爆炸
    if buttons & Shared.CTRL.EXPLODE_RELEASE ~= 0 then
        p.inputExplodeRelease = true
    end
end

return Shared

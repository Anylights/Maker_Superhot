-- ============================================================================
-- Standalone.lua - 单机模式（持久世界版）
-- multiplayer.enabled = false 时走此路径
-- 自动初始化世界 → 开始会话 → 结算 → 重新开始
-- ============================================================================

require "LuaScripts/Utilities/Sample"

local Config = require("Config")
local Camera = require("Camera")
local Map = require("Map")
local MapData = require("MapData")
local Player = require("Player")
local Pickup = require("Pickup")
local AIController = require("AIController")
local GameManager = require("GameManager")
local HUD = require("HUD")
local SFX = require("SFX")
local BGM = require("BGM")
local RandomPickup = require("RandomPickup")
local Background = require("Background")

local Standalone = {}

-- 调参面板（仅开发模式加载）
---@type table|nil
local TuningPanel = nil
---@type table|nil
local ExplosionTuningPanel = nil

---@type Scene
local scene_ = nil
local debugDraw_ = false

-- 会话状态
local sessionStarted_ = false
local restartRequested_ = false
local lastCamY_ = 0  -- 缓存相机Y，结算时背景不跳

-- ============================================================================
-- 生命周期
-- ============================================================================

function Standalone.Start()
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " (Standalone - Persistent World) ===")

    -- 暴露给 HUD 使用
    _G.StandaloneModule = Standalone

    -- 调参面板
    local ok, mod = pcall(require, "TuningPanel")
    if ok then TuningPanel = mod else print("[Standalone] TuningPanel load skipped: " .. tostring(mod)) end
    local ok2, mod2 = pcall(require, "ExplosionTuningPanel")
    if ok2 then ExplosionTuningPanel = mod2 else print("[Standalone] ExplosionTuningPanel load skipped: " .. tostring(mod2)) end

    -- 创建场景
    Standalone.CreateScene()

    -- 初始化子系统
    Map.Init(scene_)
    Player.Init(scene_, Map)
    Pickup.Init(scene_, Player)
    AIController.Init(Player, Map)
    SFX.Init(scene_)
    BGM.Init(scene_)
    GameManager.Init(Player, Map, Pickup, AIController, RandomPickup, Camera)
    Camera.Init(scene_)

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
    renderer.defaultZone.fogColor = Color(0.95, 0.82, 0.68)

    -- 初始化 HUD
    HUD.Init(Player, GameManager, Map)

    -- 初始化随机道具（传入 Player 引用）
    RandomPickup.Init(Map, Pickup, Player)

    -- 调参面板初始化
    if TuningPanel then TuningPanel.Init(scene_) end
    if ExplosionTuningPanel then ExplosionTuningPanel.Init(scene_) end

    -- 创建世界并自动开始
    Standalone.CreateGameContent()

    print("[Standalone] All systems initialized")
end

function Standalone.Stop()
    if TuningPanel then TuningPanel.Shutdown() end
    if ExplosionTuningPanel then ExplosionTuningPanel.Shutdown() end
    print("[Standalone] Game stopped")
end

-- ============================================================================
-- 场景创建
-- ============================================================================

function Standalone.CreateScene()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    local physicsWorld = scene_:CreateComponent("PhysicsWorld")
    physicsWorld:SetGravity(Vector3(0, -28.0, 0))

    -- 光照
    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Daytime.xml")
    if lightGroupFile then
        local lightGroup = scene_:CreateChild("LightGroup")
        lightGroup:LoadXML(lightGroupFile:GetRoot())
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
        Standalone.CreateFallbackLighting()
    end

    -- 死亡区域
    Standalone.CreateDeathZone()

    print("[Standalone] Scene created")
end

function Standalone.CreateFallbackLighting()
    local zoneNode = scene_:CreateChild("Zone")
    local zone = zoneNode:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(-200.0, 200.0)
    zone.ambientColor = Color(0.40, 0.35, 0.30)
    zone.fogColor = Color(0.95, 0.82, 0.68)
    zone.fogStart = 80.0
    zone.fogEnd = 150.0

    local lightNode = scene_:CreateChild("DirectionalLight")
    lightNode.direction = Vector3(0.5, -1.0, 0.3)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_DIRECTIONAL
    light.color = Color(1.0, 0.95, 0.9)
    light.castShadows = true
    light.shadowBias = BiasParameters(0.00025, 0.5)
    light.shadowCascade = CascadeParameters(10.0, 50.0, 200.0, 0.0, 0.8)
end

function Standalone.CreateDeathZone()
    local deathZone = scene_:CreateChild("DeathZone")
    deathZone.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
    deathZone.scale = Vector3(MapData.Width + 20, 2, 10)
    local dzBody = deathZone:CreateComponent("RigidBody")
    dzBody.trigger = true
    dzBody.collisionLayer = 4
    dzBody.collisionMask = 2
    local dzShape = deathZone:CreateComponent("CollisionShape")
    dzShape:SetBox(Vector3(1, 1, 1))
end

function Standalone.UpdateDeathZone()
    if scene_ == nil then return end
    local dz = scene_:GetChild("DeathZone", false)
    if dz then
        dz.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
        dz.scale = Vector3(MapData.Width + 20, 2, 10)
    end
end

-- ============================================================================
-- 游戏内容创建 + 自动开始会话
-- ============================================================================

function Standalone.CreateGameContent()
    -- 创建 3D 背景
    Background.Create(scene_, false)

    -- 初始化世界地图（随机种子）
    GameManager.InitWorld(nil)
    Standalone.UpdateDeathZone()

    -- 创建所有玩家：P1 人类 + P2~P4 AI
    Player.CreateAll()

    -- 注册 AI 控制器
    for _, p in ipairs(Player.list) do
        if not p.isHuman then
            AIController.Register(p)
        end
    end

    -- 初始化随机道具
    RandomPickup.Reset()

    -- 跟随相机（跟随人类玩家）
    Camera.ReleaseFixed()

    -- 设置状态为 playing，开始所有玩家的会话
    Standalone.StartAllSessions()

    print("[Standalone] Game content created - sessions active")
end

--- 开始所有玩家的会话
function Standalone.StartAllSessions()
    GameManager.SetState(GameManager.STATE_PLAYING)
    for _, p in ipairs(Player.list) do
        GameManager.StartPlayerSession(p.index)
    end
    sessionStarted_ = true
    BGM.PlayGameplay()
end

-- ============================================================================
-- 重新开始（HUD 结算页面调用）
-- ============================================================================

--- 请求重新开始（由 HUD 结算页面调用）
function Standalone.RequestRestart()
    restartRequested_ = true
    print("[Standalone] Restart requested")
end

--- 执行重新开始
local function DoRestart()
    restartRequested_ = false

    -- 重新开始所有玩家会话（GameManager.StartPlayerSession 内部会 Respawn）
    Standalone.StartAllSessions()

    print("[Standalone] Session restarted")
end

-- ============================================================================
-- 事件处理
-- ============================================================================

---@param dt number
function Standalone.HandleUpdate(dt)
    -- 缓存鼠标输入
    HUD.CacheInput()

    -- 处理重新开始请求
    if restartRequested_ then
        DoRestart()
        return
    end

    -- 结算状态下只更新背景
    if GameManager.state == GameManager.STATE_RESULTS then
        Background.Update(dt, lastCamY_)
        return
    end

    -- 调参面板切换
    if TuningPanel and input:GetKeyPress(KEY_P) then TuningPanel.Toggle() end
    if ExplosionTuningPanel and input:GetKeyPress(KEY_O) then ExplosionTuningPanel.Toggle() end

    local tuningOpen = (TuningPanel and TuningPanel.IsVisible())
        or (ExplosionTuningPanel and ExplosionTuningPanel.IsVisible())

    if not tuningOpen then
        GameManager.Update(dt)
    end

    Map.Update(dt)

    -- 背景跟随相机
    local _, camY = Camera.GetCenter()
    lastCamY_ = camY
    Background.Update(dt, camY)

    -- 处理人类输入
    if GameManager.CanPlayersMove() then
        Standalone.HandlePlayerInput()
    else
        for _, p in ipairs(Player.list) do
            if p.isHuman then
                p.inputMoveX = 0
                p.inputJump = false
                p.inputDash = false
                p.inputCharging = false
                p.inputExplodeRelease = false
            end
        end
    end

    -- AI 更新
    if GameManager.CanPlayersMove() then
        AIController.Update(dt)
    end

    Player.UpdateAll(dt)
    Pickup.Update(dt)
    RandomPickup.Update(dt)

    -- 更新排行榜
    GameManager.CalcLeaderboard()

    -- 检查人类玩家会话是否结束
    local human = GameManager.GetHumanPlayer()
    if human and sessionStarted_ and not human.session.active then
        GameManager.SetState(GameManager.STATE_RESULTS)
        sessionStarted_ = false
        print("[Standalone] Human session ended, showing results")
    end

    -- Debug 切换
    if input:GetKeyPress(KEY_TAB) then
        debugDraw_ = not debugDraw_
    end
end

---@param dt number
function Standalone.HandlePostUpdate(dt)
    local positions = Player.GetAlivePositions()
    local humanPos = Player.GetHumanPosition()
    Camera.Update(dt, positions, humanPos)

    if debugDraw_ then
        local pw = scene_:GetComponent("PhysicsWorld")
        if pw then pw:DrawDebugGeometry(true) end
    end
end

--- 处理人类玩家输入
function Standalone.HandlePlayerInput()
    if (TuningPanel and TuningPanel.IsPointerOver())
        or (ExplosionTuningPanel and ExplosionTuningPanel.IsPointerOver()) then
        return
    end

    for _, p in ipairs(Player.list) do
        if p.isHuman and p.alive and p.session and p.session.active then
            local moveX = 0
            if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
                moveX = -1
            elseif input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
                moveX = 1
            end
            p.inputMoveX = moveX

            if input:GetKeyPress(KEY_SPACE) then p.inputJump = true end
            if input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then p.inputDash = true end

            local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
            if leftDown then p.inputCharging = true end
            if p.wasChargingInput and not leftDown then p.inputExplodeRelease = true end
            p.wasChargingInput = leftDown
        end
    end
end

---@return Scene
function Standalone.GetScene()
    return scene_
end

return Standalone

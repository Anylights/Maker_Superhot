-- ============================================================================
-- main.lua - 超级红温！ 游戏入口
-- 2.5D 多人平台竞速派对游戏
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

-- 调参面板（仅客户端加载，服务端跳过）
---@type table|nil
local TuningPanel = nil
if not IsServerMode or not IsServerMode() then
    local ok, mod = pcall(require, "TuningPanel")
    if ok then
        TuningPanel = mod
    else
        print("[Main] TuningPanel load skipped: " .. tostring(mod))
    end
end

-- ============================================================================
-- 全局变量
-- ============================================================================
---@type Scene
local scene_ = nil

-- 调试
local debugDraw_ = false



-- ============================================================================
-- 生命周期
-- ============================================================================

function Start()
    -- Sample 工具库初始化
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " ===")

    -- 创建场景
    CreateScene()

    -- 初始化地图系统
    Map.Init(scene_)

    -- 初始化玩家系统（依赖 Map）
    Player.Init(scene_, Map)

    -- 初始化拾取物系统（依赖 Player）
    Pickup.Init(scene_, Player)

    -- 初始化 AI 系统（依赖 Player, Map）
    AIController.Init(Player, Map)

    -- 初始化音效系统
    SFX.Init(scene_)

    -- 初始化游戏管理器（依赖 Player, Map, Pickup, AI）
    GameManager.Init(Player, Map, Pickup, AIController)

    -- 初始化相机
    Camera.Init(scene_)

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true

    -- 设置默认背景色（深色）
    renderer.defaultZone.fogColor = Color(0.12, 0.12, 0.18)

    -- 创建游戏内容
    CreateGameContent()

    -- 初始化 HUD（依赖 Player, GameManager, Map）
    HUD.Init(Player, GameManager, Map)

    -- 初始化调参面板（加载存档并应用到 Config）
    if TuningPanel then
        TuningPanel.Init(scene_)
    end

    -- 订阅事件
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")

    print("[Main] All systems initialized")
end

function Stop()
    if TuningPanel then
        TuningPanel.Shutdown()
    end
    print("[Main] Game stopped")
end

-- ============================================================================
-- 场景初始化
-- ============================================================================

function CreateScene()
    scene_ = Scene()

    -- 必需组件
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    -- 3D 物理世界
    local physicsWorld = scene_:CreateComponent("PhysicsWorld")
    physicsWorld:SetGravity(Vector3(0, -28.0, 0))

    -- 光照 - 使用 LightGroup 预设
    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Daytime.xml")
    if lightGroupFile then
        local lightGroup = scene_:CreateChild("LightGroup")
        lightGroup:LoadXML(lightGroupFile:GetRoot())
        print("[Main] LightGroup loaded: Daytime")
        -- 覆盖 LightGroup 中 Zone 的背景色为深色
        local zoneComp = lightGroup:GetComponent("Zone")
        if not zoneComp then
            -- Zone 可能在子节点上
            for i = 0, lightGroup.numChildren - 1 do
                local child = lightGroup:GetChild(i)
                zoneComp = child:GetComponent("Zone")
                if zoneComp then break end
            end
        end
        if zoneComp then
            zoneComp.fogColor = Color(0.12, 0.12, 0.18)
            print("[Main] Zone fogColor overridden to dark")
        end
    else
        CreateFallbackLighting()
    end

    -- 死亡区域（底部）- 不可见触发器
    local deathZone = scene_:CreateChild("DeathZone")
    deathZone.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
    deathZone.scale = Vector3(MapData.Width + 20, 2, 10)

    local dzBody = deathZone:CreateComponent("RigidBody")
    dzBody.trigger = true
    dzBody.collisionLayer = 4
    dzBody.collisionMask = 2

    local dzShape = deathZone:CreateComponent("CollisionShape")
    dzShape:SetBox(Vector3(1, 1, 1))

    print("[Main] Scene created with PhysicsWorld")
end

function CreateFallbackLighting()
    local zoneNode = scene_:CreateChild("Zone")
    local zone = zoneNode:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(-200.0, 200.0)
    zone.ambientColor = Color(0.35, 0.35, 0.4)
    zone.fogColor = Color(0.12, 0.12, 0.18)
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

-- ============================================================================
-- 游戏内容
-- ============================================================================

function CreateGameContent()
    -- 构建地图
    Map.Build()

    -- 创建全部玩家（P1=人类, P2~P4=AI）
    Player.CreateAll()

    -- 注册 AI 玩家
    for _, p in ipairs(Player.list) do
        if not p.isHuman then
            AIController.Register(p)
        end
    end

    -- 生成能量拾取物
    Pickup.SpawnAll()

    -- 初始化相机到起点区域
    local spawnX, spawnY = MapData.GetSpawnPosition(1)
    Camera.SetImmediate(Vector3(spawnX + 10, spawnY + 5, 0), Config.CameraMinOrtho)

    -- 进入主菜单（等待玩家按键开始）
    GameManager.EnterMenu()

    print("[Main] Game content created - waiting at menu")
end

-- ============================================================================
-- 事件处理
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 主菜单：按空格或回车开始游戏
    if GameManager.state == GameManager.STATE_MENU then
        if input:GetKeyPress(KEY_SPACE) or input:GetKeyPress(KEY_RETURN) then
            GameManager.StartMatch()
            print("[Main] Game started from menu")
        end
        return  -- 菜单状态不处理其他逻辑
    end

    -- 调参面板切换（P 键）
    if TuningPanel and input:GetKeyPress(KEY_P) then
        TuningPanel.Toggle()
    end

    -- 调参面板打开时暂停游戏计时（状态机不推进）
    local tuningOpen = TuningPanel and TuningPanel.IsVisible()
    if not tuningOpen then
        GameManager.Update(dt)
    end

    -- 更新地图（方块重生等）
    Map.Update(dt)

    -- 人类玩家输入（仅在允许移动时）
    if GameManager.CanPlayersMove() then
        HandlePlayerInput()
    else
        -- 清除人类玩家输入
        for _, p in ipairs(Player.list) do
            if p.isHuman then
                p.inputMoveX = 0
                p.inputJump = false
                p.inputDash = false
                p.inputExplode = false
            end
        end
    end

    -- AI 更新（仅在允许移动时）
    if GameManager.CanPlayersMove() then
        AIController.Update(dt)
    end

    -- 更新玩家系统
    Player.UpdateAll(dt)

    -- 更新拾取物系统
    Pickup.Update(dt)

    -- 调试开关
    if input:GetKeyPress(KEY_TAB) then
        debugDraw_ = not debugDraw_
    end
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 收集活跃玩家位置
    local positions = Player.GetAlivePositions()

    -- 获取人类玩家位置（即使死亡也返回有效位置，保证相机不丢失视角）
    local humanPos = Player.GetHumanPosition()

    -- 更新相机
    Camera.Update(dt, positions, humanPos)

    -- 调试绘制
    if debugDraw_ then
        local pw = scene_:GetComponent("PhysicsWorld")
        if pw then
            pw:DrawDebugGeometry(true)
        end
    end
end

--- 处理人类玩家输入（P1）
function HandlePlayerInput()
    -- 调参面板打开且鼠标在面板上时，不处理游戏输入
    if TuningPanel and TuningPanel.IsPointerOver() then
        return
    end

    for _, p in ipairs(Player.list) do
        if p.isHuman and p.alive and not p.finished then
            -- 水平移动
            local moveX = 0
            if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
                moveX = -1
            elseif input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
                moveX = 1
            end
            p.inputMoveX = moveX

            -- 跳跃（仅空格键）
            if input:GetKeyPress(KEY_SPACE) then
                p.inputJump = true
            end

            -- 冲刺
            if input:GetKeyPress(KEY_SHIFT) then
                p.inputDash = true
            end

            -- 爆炸
            if input:GetKeyPress(KEY_E) then
                p.inputExplode = true
            end
        end
    end
end

-- ============================================================================
-- 公共接口
-- ============================================================================

---@return Scene
function GetScene()
    return scene_
end



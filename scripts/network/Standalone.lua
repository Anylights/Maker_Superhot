-- ============================================================================
-- Standalone.lua - 单机模式（保留原有全部逻辑）
-- multiplayer.enabled = false 时走此路径
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
local RandomPickup = require("RandomPickup")
local LevelEditor = require("LevelEditor")
local LevelManager = require("LevelManager")

local Standalone = {}

-- 调参面板（仅客户端加载）
---@type table|nil
local TuningPanel = nil
---@type table|nil
local ExplosionTuningPanel = nil

---@type Scene
local scene_ = nil
local debugDraw_ = false

-- 当前关卡文件名（用于每局换图时排除上一张）
local currentLevelFilename_ = nil
-- 是否处于测试游玩模式（测试游玩固定使用同一张图）
local isTestPlayMode_ = false

-- ============================================================================
-- 生命周期
-- ============================================================================

function Standalone.Start()
    -- Sample 工具库初始化
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " (Standalone) ===")

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
    GameManager.Init(Player, Map, Pickup, AIController, RandomPickup, Camera)
    Camera.Init(scene_)

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
    renderer.defaultZone.fogColor = Color(0.95, 0.82, 0.68)

    -- 创建游戏内容
    Standalone.CreateGameContent()

    -- 初始化 HUD
    HUD.Init(Player, GameManager, Map)

    -- 初始化随机道具
    RandomPickup.Init(Map, Pickup)

    -- 初始化关卡管理器
    LevelManager.Init()

    -- 初始化关卡编辑器
    LevelEditor.Init(HUD.GetNVGContext(), GameManager, Map)
    HUD.SetLevelEditor(LevelEditor)

    -- 调参面板初始化
    if TuningPanel then TuningPanel.Init(scene_) end
    if ExplosionTuningPanel then ExplosionTuningPanel.Init(scene_) end

    -- 每局开始前换一张地图（测试游玩除外）
    GameManager.OnBeforeRound(function(roundIdx)
        if isTestPlayMode_ then return end
        local grid, fname = LevelManager.GetRandom(currentLevelFilename_)
        if grid then
            MapData.SetCustomGrid(grid)
            currentLevelFilename_ = fname
            print(string.format("[Standalone] Round %d → switched to level: %s", roundIdx, tostring(fname)))
            -- 关卡换了，重新设置死亡区
            Standalone.UpdateDeathZone()
        end
    end)

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
    local deathZone = scene_:CreateChild("DeathZone")
    deathZone.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
    deathZone.scale = Vector3(MapData.Width + 20, 2, 10)
    local dzBody = deathZone:CreateComponent("RigidBody")
    dzBody.trigger = true
    dzBody.collisionLayer = 4
    dzBody.collisionMask = 2
    local dzShape = deathZone:CreateComponent("CollisionShape")
    dzShape:SetBox(Vector3(1, 1, 1))

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

-- ============================================================================
-- 游戏内容
-- ============================================================================

function Standalone.CreateBackgroundPlane()
    local topColor = Config.BgColorTop
    local botColor = Config.BgColorBot
    local size = 200
    local strips = 8
    local bgNode = scene_:CreateChild("BackgroundGradient")
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

        local stripNode = bgNode:CreateChild("Strip" .. i)
        local yTop = size * (1 - t0 * 2)
        local yBot = size * (1 - t1 * 2)
        stripNode.position = Vector3(0, (yTop + yBot) * 0.5, 0)
        stripNode.scale = Vector3(size * 2, yTop - yBot, 0.1)

        local model = stripNode:CreateComponent("StaticModel")
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

function Standalone.UpdateDeathZone()
    if scene_ == nil then return end
    local dz = scene_:GetChild("DeathZone", false)
    if dz then
        dz.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
        dz.scale = Vector3(MapData.Width + 20, 2, 10)
    end
end

function Standalone.CreateGameContent()
    Standalone.CreateBackgroundPlane()
    Map.Build()
    Player.CreateAll()

    for _, p in ipairs(Player.list) do
        if not p.isHuman then
            AIController.Register(p)
        end
    end

    RandomPickup.Reset()
    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
    GameManager.EnterMenu()
    print("[Standalone] Game content created - waiting at menu")
end

-- ============================================================================
-- 事件处理
-- ============================================================================

---@param dt number
function Standalone.HandleUpdate(dt)
    -- 缓存鼠标输入（必须在 Update 阶段，渲染阶段 GetMouseButtonPress 不可靠）
    HUD.CacheInput()

    -- 主菜单：点击开始 → 立即进入游戏（其他角色由 AI 控制）
    if GameManager.state == GameManager.STATE_MENU then
        local btn = HUD.GetMenuButtonClicked()
        if btn == "startGame" then
            isTestPlayMode_ = false
            local grid, fname = LevelManager.GetRandom()
            if grid then
                MapData.SetCustomGrid(grid)
                currentLevelFilename_ = fname
            else
                MapData.ClearCustomGrid()
                currentLevelFilename_ = nil
            end
            GameManager.StartMatch()
            Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
            Standalone.UpdateDeathZone()
        elseif btn == "editor" then
            HUD.RefreshLevelList()
            GameManager.EnterLevelList()
        end
        return
    end

    -- 关卡列表
    if GameManager.state == GameManager.STATE_LEVEL_LIST then
        if HUD.IsPersistClicked() then
            LevelManager.ExportToLog()
        end
        local action = HUD.GetLevelListAction()
        if action then
            if action.action == "play" then
                local grid = LevelManager.Load(action.filename)
                if grid then
                    isTestPlayMode_ = true
                    currentLevelFilename_ = action.filename
                    MapData.SetCustomGrid(grid)
                    GameManager.StartTestPlay(action.filename)
                    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
                    Standalone.UpdateDeathZone()
                end
            elseif action.action == "edit" then
                Camera.ReleaseFixed()
                GameManager.EnterEditor()
                LevelEditor.LoadFile(action.filename)
                LevelEditor.Enter()
            elseif action.action == "delete" then
                LevelManager.Delete(action.filename)
                HUD.RefreshLevelList()
            elseif action.action == "new" then
                Camera.ReleaseFixed()
                GameManager.EnterEditor()
                LevelEditor.NewLevel()
                LevelEditor.Enter()
            elseif action.action == "back" then
                GameManager.ExitLevelList()
            end
        end
        return
    end

    -- 关卡编辑器
    if GameManager.state == GameManager.STATE_EDITOR then
        LevelEditor.Update(dt)
        return
    end

    -- 试玩退出
    if GameManager.testPlayMode then
        if input:GetKeyPress(KEY_ESCAPE) or HUD.IsTestPlayExitClicked() then
            isTestPlayMode_ = false
            GameManager.ExitTestPlay()
            HUD.RefreshLevelList()
            return
        end
    end

    -- 调参面板切换
    if TuningPanel and input:GetKeyPress(KEY_P) then TuningPanel.Toggle() end
    if ExplosionTuningPanel and input:GetKeyPress(KEY_O) then ExplosionTuningPanel.Toggle() end

    local tuningOpen = (TuningPanel and TuningPanel.IsVisible()) or (ExplosionTuningPanel and ExplosionTuningPanel.IsVisible())
    if not tuningOpen then
        GameManager.Update(dt)
    end

    Map.Update(dt)

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

    if GameManager.CanPlayersMove() then
        AIController.Update(dt)
    end

    Player.UpdateAll(dt)
    Pickup.Update(dt)
    RandomPickup.Update(dt)

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
    if (TuningPanel and TuningPanel.IsPointerOver()) or (ExplosionTuningPanel and ExplosionTuningPanel.IsPointerOver()) then
        return
    end

    for _, p in ipairs(Player.list) do
        if p.isHuman and p.alive and not p.finished then
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

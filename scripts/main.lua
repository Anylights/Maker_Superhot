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
local RandomPickup = require("RandomPickup")
local LevelEditor = require("LevelEditor")
local LevelManager = require("LevelManager")

-- 调参面板（仅客户端加载，服务端跳过）
---@type table|nil
local TuningPanel = nil
---@type table|nil
local ExplosionTuningPanel = nil
if not IsServerMode or not IsServerMode() then
    local ok, mod = pcall(require, "TuningPanel")
    if ok then
        TuningPanel = mod
    else
        print("[Main] TuningPanel load skipped: " .. tostring(mod))
    end
    local ok2, mod2 = pcall(require, "ExplosionTuningPanel")
    if ok2 then
        ExplosionTuningPanel = mod2
    else
        print("[Main] ExplosionTuningPanel load skipped: " .. tostring(mod2))
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

    -- 初始化游戏管理器（依赖 Player, Map, Pickup, AI, RandomPickup）
    GameManager.Init(Player, Map, Pickup, AIController, RandomPickup)

    -- 初始化相机
    Camera.Init(scene_)

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true

    -- 设置默认背景色（暖桃色，3D 清屏色）
    renderer.defaultZone.fogColor = Color(0.95, 0.82, 0.68)

    -- 创建游戏内容
    CreateGameContent()

    -- 初始化 HUD（依赖 Player, GameManager, Map）
    HUD.Init(Player, GameManager, Map)

    -- 初始化随机道具系统（依赖 Map, Pickup）
    RandomPickup.Init(Map, Pickup)

    -- 初始化关卡管理器
    LevelManager.Init()

    -- 初始化关卡编辑器（依赖 HUD 的 NanoVG 上下文）
    LevelEditor.Init(HUD.GetNVGContext(), GameManager, Map)
    HUD.SetLevelEditor(LevelEditor)

    -- 初始化调参面板（加载存档并应用到 Config）
    if TuningPanel then
        TuningPanel.Init(scene_)
    end
    if ExplosionTuningPanel then
        ExplosionTuningPanel.Init(scene_)
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
    if ExplosionTuningPanel then
        ExplosionTuningPanel.Shutdown()
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
            zoneComp.fogColor = Color(0.95, 0.82, 0.68)
            print("[Main] Zone fogColor overridden to warm peach")
        end
    else
        CreateFallbackLighting()
    end

    -- 死亡区域（底部）- 不可见触发器（初始创建，后续由 UpdateDeathZone 更新）
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

--- 创建 3D 渐变背景平面（位于所有游戏元素后方）
function CreateBackgroundPlane()
    local topColor = Config.BgColorTop
    local botColor = Config.BgColorBot
    local size = 200  -- 足够大覆盖正交相机视野

    -- 用多条水平带模拟渐变（8 条）
    local strips = 8
    local bgNode = scene_:CreateChild("BackgroundGradient")
    bgNode.position = Vector3(0, 0, 5)  -- Z=+5，在游戏元素（Z=0）后面

    local pbrTech = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")

    for i = 0, strips - 1 do
        local t0 = i / strips
        local t1 = (i + 1) / strips

        -- 插值颜色（从顶到底）
        local r0 = topColor[1] + (botColor[1] - topColor[1]) * t0
        local g0 = topColor[2] + (botColor[2] - topColor[2]) * t0
        local b0 = topColor[3] + (botColor[3] - topColor[3]) * t0
        local r1 = topColor[1] + (botColor[1] - topColor[1]) * t1
        local g1 = topColor[2] + (botColor[2] - topColor[2]) * t1
        local b1 = topColor[3] + (botColor[3] - topColor[3]) * t1

        -- 每条带取中间色作为材质颜色
        local midR = (r0 + r1) * 0.5
        local midG = (g0 + g1) * 0.5
        local midB = (b0 + b1) * 0.5

        local stripNode = bgNode:CreateChild("Strip" .. i)
        local yTop = size * (1 - t0 * 2)   -- +size → -size（从上到下）
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

    print("[Main] Background gradient plane created (" .. strips .. " strips)")
end

--- 更新死亡区域位置和大小（适配当前 MapData 尺寸）
function UpdateDeathZone()
    if scene_ == nil then return end
    local dz = scene_:GetChild("DeathZone", false)
    if dz then
        dz.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
        dz.scale = Vector3(MapData.Width + 20, 2, 10)
    end
end

function CreateGameContent()
    -- 创建渐变背景平面
    CreateBackgroundPlane()

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

    -- 随机生成能量拾取物（由 RandomPickup 管理生成位置）
    RandomPickup.Reset()

    -- 固定摄像机显示全局地图
    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)

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
            -- 正常游戏：随机选取自定义关卡
            local grid, fn = LevelManager.GetRandom()
            if grid then
                MapData.SetCustomGrid(grid)
                print("[Main] Random level selected: " .. tostring(fn))
            else
                MapData.ClearCustomGrid()
                print("[Main] No custom levels, using procedural map")
            end
            GameManager.StartMatch()
            -- 每次开赛后重新设置固定摄像机和死亡区域（地图可能已变）
            Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
            UpdateDeathZone()
            print("[Main] Game started from menu")
        elseif input:GetKeyPress(KEY_L) or HUD.IsLevelListButtonClicked() then
            HUD.RefreshLevelList()
            GameManager.EnterLevelList()
            print("[Main] Entering level list")
        elseif input:GetKeyPress(KEY_E) or HUD.IsEditorButtonClicked() then
            Camera.ReleaseFixed()
            GameManager.EnterEditor()
            LevelEditor.NewLevel()
            LevelEditor.Enter()
            print("[Main] Entering level editor (new level)")
        end
        return
    end

    -- 关卡列表状态
    if GameManager.state == GameManager.STATE_LEVEL_LIST then
        -- 保存到工程（导出关卡数据到日志）
        if HUD.IsPersistClicked() then
            local count = LevelManager.ExportToLog()
            if count > 0 then
                print("[Main] Persist requested: " .. count .. " levels exported to log")
            else
                print("[Main] Persist requested but no levels to export")
            end
        end

        local action = HUD.GetLevelListAction()
        if action then
            if action.action == "play" then
                -- 试玩：加载关卡并开始试玩
                local grid = LevelManager.Load(action.filename)
                if grid then
                    MapData.SetCustomGrid(grid)
                    GameManager.StartTestPlay(action.filename)
                    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
                    UpdateDeathZone()
                    print("[Main] Test play: " .. action.filename)
                end
            elseif action.action == "edit" then
                -- 修改：加载到编辑器
                Camera.ReleaseFixed()
                GameManager.EnterEditor()
                LevelEditor.LoadFile(action.filename)
                LevelEditor.Enter()
                print("[Main] Editing level: " .. action.filename)
            elseif action.action == "delete" then
                -- 删除关卡
                LevelManager.Delete(action.filename)
                HUD.RefreshLevelList()
                print("[Main] Deleted level: " .. action.filename)
            elseif action.action == "new" then
                -- 新建关卡
                Camera.ReleaseFixed()
                GameManager.EnterEditor()
                LevelEditor.NewLevel()
                LevelEditor.Enter()
                print("[Main] New level from list")
            elseif action.action == "back" then
                -- 返回菜单
                GameManager.ExitLevelList()
                print("[Main] Back to menu from level list")
            end
        end
        return
    end

    -- 关卡编辑器状态：仅更新编辑器，跳过所有游戏逻辑
    if GameManager.state == GameManager.STATE_EDITOR then
        LevelEditor.Update(dt)
        return
    end

    -- 试玩模式下：ESC 或点击退出按钮 → 退出试玩
    if GameManager.testPlayMode then
        if input:GetKeyPress(KEY_ESCAPE) or HUD.IsTestPlayExitClicked() then
            GameManager.ExitTestPlay()
            HUD.RefreshLevelList()
            print("[Main] Exited test play")
            return
        end
    end

    -- 调参面板切换（P 键 = 手感调参，O 键 = 爆炸调参）
    if TuningPanel and input:GetKeyPress(KEY_P) then
        TuningPanel.Toggle()
    end
    if ExplosionTuningPanel and input:GetKeyPress(KEY_O) then
        ExplosionTuningPanel.Toggle()
    end

    -- 调参面板打开时暂停游戏计时（状态机不推进）
    local tuningOpen = (TuningPanel and TuningPanel.IsVisible()) or (ExplosionTuningPanel and ExplosionTuningPanel.IsVisible())
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
                p.inputCharging = false
                p.inputExplodeRelease = false
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

    -- 更新随机道具生成（补充被捡走的道具）
    RandomPickup.Update(dt)

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
    if (TuningPanel and TuningPanel.IsPointerOver()) or (ExplosionTuningPanel and ExplosionTuningPanel.IsPointerOver()) then
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

            -- 爆炸蓄力（鼠标左键按住蓄力，松开触发）
            local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
            if leftDown then
                p.inputCharging = true
            end
            if p.wasChargingInput and not leftDown then
                -- 上帧按住 + 本帧松开 = 释放爆炸
                p.inputExplodeRelease = true
            end
            p.wasChargingInput = leftDown
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



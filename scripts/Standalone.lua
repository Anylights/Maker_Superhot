-- ============================================================================
-- Standalone.lua - 单机模式（大地图攀登模式）
-- ============================================================================

require "LuaScripts/Utilities/Sample"
require "urhox-libs.UI.VirtualControls"

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
local RandomEvent = require("RandomEvent")
local PlatformUtils = require("urhox-libs.Platform.PlatformUtils")

local Standalone = {}

-- 调参面板
---@type table|nil
local TuningPanel = nil
---@type table|nil
local ExplosionTuningPanel = nil

---@type Scene
local scene_ = nil
local debugDraw_ = false

-- 移动端虚拟控件
local joystick_ = nil
local jumpButton_ = nil
local dashButton_ = nil
local slamButton_ = nil
local chargeButton_ = nil
local isMobile_ = false
local jumpPressed_ = false   -- 跳跃按钮本帧被按下
local dashPressed_ = false   -- 冲刺按钮本帧被按下
local slamPressed_ = false   -- 下砸按钮本帧被按下

-- ============================================================================
-- 生命周期
-- ============================================================================

function Standalone.Start()
    -- Sample 工具库初始化
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " (Standalone - Climb) ===")

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
    Camera.SetPlayerModule(Player)

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
    renderer.defaultZone.fogColor = Color(0.12, 0.08, 0.28)

    -- 创建游戏内容
    Standalone.CreateGameContent()

    -- 初始化 HUD
    HUD.Init(Player, GameManager, Map)

    -- 初始化随机道具
    RandomPickup.Init(Map, Pickup, Player)

    -- 调参面板初始化
    if TuningPanel then TuningPanel.Init(scene_) end
    if ExplosionTuningPanel then ExplosionTuningPanel.Init(scene_) end

    -- 开始播放菜单 BGM，禁用游戏音效
    SFX.PlayMenuBGM()
    SFX.DisableSFX()

    -- 移动端虚拟控件初始化
    Standalone.InitMobileControls()

    print("[Standalone] All systems initialized")
end

function Standalone.Stop()
    if TuningPanel then TuningPanel.Shutdown() end
    if ExplosionTuningPanel then ExplosionTuningPanel.Shutdown() end
    print("[Standalone] Game stopped")
end

-- ============================================================================
-- 移动端虚拟控件
-- ============================================================================

function Standalone.InitMobileControls()
    -- 使用屏幕尺寸检测（与 HUD 的 isMobileHUD_ 一致）
    -- IsTouchSupported() 在 WASM 平台返回 false，不可靠
    local dpr = graphics:GetDPR()
    local logH = graphics:GetHeight() / dpr
    isMobile_ = (logH < 500)
    print("[Standalone] isMobile=" .. tostring(isMobile_) .. " (logH=" .. math.floor(logH) .. ")")

    -- 初始化虚拟控件系统（横屏 1920x1080 设计分辨率）
    VirtualControls.Initialize(1920, 1080)

    -- ========== 左侧：摇杆 ==========
    -- 缩小到之前的 0.7 倍直径
    joystick_ = VirtualControls.CreateJoystick({
        position = Vector2(420, -280),
        alignment = {HA_LEFT, VA_BOTTOM},
        baseRadius = 154,    -- 220 * 0.7
        knobRadius = 56,     -- 80 * 0.7
        moveRadius = 84,     -- 120 * 0.7
        deadZone = 0.15,
        keyBinding = "WASD",
        opacity = 0.35,
        activeOpacity = 0.75,
    })

    -- ========== 右侧：按钮组（围绕跳跃按钮圆心排布）==========
    -- 按钮尺寸放大到 1.2 倍
    local jumpR = 98    -- 82 * 1.2 ≈ 98
    local smallR = 74   -- 62 * 1.2 ≈ 74
    -- 轨道距离（中心间距）：390 的一半 = 195
    local orbitDist = 195

    -- 跳跃按钮中心位置：在之前基础上往上移动 0.2 个跳按钮直径（98*2*0.2≈39）
    local jumpRight = 340   -- 距右边距不变
    local jumpBottom = 172 + 39  -- 往上移（bottom 值增大 = 离底边更远 = 更靠上）

    -- 跳跃（中心，主按钮，最大）
    jumpButton_ = VirtualControls.CreateButton({
        position = Vector2(-jumpRight, -jumpBottom),
        alignment = {HA_RIGHT, VA_BOTTOM},
        radius = jumpR,
        label = "跳",
        keyBinding = KEY_SPACE,
        keyLabel = "Space",
        color = {100, 200, 255},
        pressedColor = {150, 230, 255},
        opacity = 0.4,
        activeOpacity = 0.85,
        on_press = function()
            jumpPressed_ = true
        end,
    })

    -- 冲刺（跳跃按钮的左边）
    dashButton_ = VirtualControls.CreateButton({
        position = Vector2(-jumpRight - orbitDist, -jumpBottom),
        alignment = {HA_RIGHT, VA_BOTTOM},
        radius = smallR,
        label = "冲",
        keyBinding = KEY_SHIFT,
        keyLabel = "Shift",
        color = {255, 180, 80},
        pressedColor = {255, 220, 120},
        opacity = 0.35,
        activeOpacity = 0.8,
        on_press = function()
            dashPressed_ = true
        end,
    })

    -- 下砸（跳跃按钮的左上方，45° 方向）
    local diagDist = math.floor(orbitDist * 0.707)  -- cos(45°) ≈ 276
    slamButton_ = VirtualControls.CreateButton({
        position = Vector2(-jumpRight - diagDist, -jumpBottom - diagDist),
        alignment = {HA_RIGHT, VA_BOTTOM},
        radius = smallR,
        label = "砸",
        keyBinding = KEY_S,
        keyLabel = "S",
        color = {255, 100, 100},
        pressedColor = {255, 150, 150},
        opacity = 0.35,
        activeOpacity = 0.8,
        on_press = function()
            slamPressed_ = true
        end,
    })

    -- 蓄力/爆炸（跳跃按钮的上方）
    -- 注意：不设 mouseBinding，触摸只在按钮半径内生效；PC 鼠标左键在 HandlePlayerInput 中单独处理
    chargeButton_ = VirtualControls.CreateButton({
        position = Vector2(-jumpRight, -jumpBottom - orbitDist),
        alignment = {HA_RIGHT, VA_BOTTOM},
        radius = smallR,
        label = "爆",
        color = {255, 200, 50},
        pressedColor = {255, 240, 100},
        opacity = 0.35,
        activeOpacity = 0.8,
    })

    print("[Standalone] Mobile controls initialized (landscape), isMobile=" .. tostring(isMobile_))

    -- 初始状态：菜单中不显示虚拟控件
    Standalone.SetVirtualControlsVisible(false)
end

--- 显示/隐藏虚拟控件（菜单和结算时隐藏，游戏中显示）
function Standalone.SetVirtualControlsVisible(show)
    -- PC 端不显示虚拟控件的视觉部分（键盘绑定仍通过 fallback 生效）
    local visualShow = show and isMobile_

    -- 摇杆的 _updateShouldShow 正确检查 visible 属性
    if joystick_ then joystick_.visible = visualShow; joystick_:_updateShouldShow() end
    -- 按钮的 _updateShouldShow 在移动端不检查 visible 属性（引擎库缺陷），
    -- 隐藏时需要手动设置 _shouldShow = false
    local buttons = {jumpButton_, dashButton_, slamButton_, chargeButton_}
    for _, btn in ipairs(buttons) do
        if btn then
            btn.visible = visualShow
            if visualShow then
                btn:_updateShouldShow()
            else
                btn._shouldShow = false
            end
        end
    end
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
    zone.ambientColor = Color(0.35, 0.30, 0.45)
    zone.fogColor = Color(0.12, 0.08, 0.28)
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
        -- 保存材质引用，用于随机事件背景渐变
        if not Standalone.bgStripMaterials_ then
            Standalone.bgStripMaterials_ = {}
        end
        Standalone.bgStripMaterials_[i + 1] = mat
    end
end

function Standalone.UpdateBackgroundColors()
    local mats = Standalone.bgStripMaterials_
    if not mats then return end
    local topColor, botColor = RandomEvent.GetBgColors()
    if not topColor then
        topColor = Config.BgColorTop
        botColor = Config.BgColorBot
    end
    local strips = #mats
    for i = 1, strips do
        local t0 = (i - 1) / strips
        local t1 = i / strips
        local r0 = topColor[1] + (botColor[1] - topColor[1]) * t0
        local g0 = topColor[2] + (botColor[2] - topColor[2]) * t0
        local b0 = topColor[3] + (botColor[3] - topColor[3]) * t0
        local r1 = topColor[1] + (botColor[1] - topColor[1]) * t1
        local g1 = topColor[2] + (botColor[2] - topColor[2]) * t1
        local b1 = topColor[3] + (botColor[3] - topColor[3]) * t1
        local midR = (r0 + r1) * 0.5
        local midG = (g0 + g1) * 0.5
        local midB = (b0 + b1) * 0.5
        mats[i]:SetShaderParameter("MatDiffColor", Variant(Color(midR, midG, midB, 1.0)))
        mats[i]:SetShaderParameter("MatEmissiveColor", Variant(Color(midR * 0.3, midG * 0.3, midB * 0.3)))
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
    GameManager.InitWorld()
    GameManager.EnterMenu()
    Camera.spectateMode = true
    print("[Standalone] Game content created - world initialized, spectating")
end

-- ============================================================================
-- 事件处理
-- ============================================================================

---@param dt number
function Standalone.HandleUpdate(dt)
    -- 缓存鼠标输入（必须在 Update 阶段，渲染阶段 GetMouseButtonPress 不可靠）
    HUD.CacheInput()

    -- 主菜单：点击开始 → 加入游戏（不阻塞后续逻辑，AI 继续运行）
    if GameManager.state == GameManager.STATE_MENU then
        Camera.spectateMode = true
        Standalone.SetVirtualControlsVisible(false)
        local btn = HUD.GetMenuButtonClicked()
        if btn == "startGame" then
            Camera.spectateMode = false
            Standalone.SetVirtualControlsVisible(true)
            SFX.PlayGameBGM()
            SFX.EnableSFX()
            GameManager.StartGame()
            Standalone.UpdateDeathZone()
        end
    end

    -- 结算画面（不阻塞后续逻辑，AI 继续运行）
    if GameManager.state == GameManager.STATE_RESULT then
        Camera.spectateMode = true
        Standalone.SetVirtualControlsVisible(false)
        local btn = HUD.GetResultButtonClicked()
        if btn == "restart" then
            Camera.spectateMode = false
            Standalone.SetVirtualControlsVisible(true)
            SFX.PlayGameBGM()
            SFX.EnableSFX()
            GameManager.Restart()
            Standalone.UpdateDeathZone()
        elseif btn == "menu" then
            SFX.PlayMenuBGM()
            SFX.DisableSFX()
            GameManager.EnterMenu()
        end
    end

    -- 调参面板切换
    if TuningPanel and input:GetKeyPress(KEY_P) then TuningPanel.Toggle() end
    if ExplosionTuningPanel and input:GetKeyPress(KEY_O) then ExplosionTuningPanel.Toggle() end

    local tuningOpen = (TuningPanel and TuningPanel.IsVisible()) or (ExplosionTuningPanel and ExplosionTuningPanel.IsVisible())
    if not tuningOpen then
        GameManager.Update(dt)
    end

    -- 随机事件更新（仅 Playing 状态）
    if GameManager.state == GameManager.STATE_PLAYING then
        RandomEvent.Update(dt)
        -- 更新背景颜色
        Standalone.UpdateBackgroundColors()
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

    -- AI 在菜单/游戏中/结算时都可以运动（持久世界）
    if GameManager.CanAIMove() then
        AIController.Update(dt)
    end

    Player.UpdateAll(dt)
    Pickup.Update(dt)
    RandomPickup.Update(dt)
    SFX.UpdateBGM()

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
        if p.isHuman and p.alive then
            -- 移动：摇杆 X 分量（手机触屏）+ 直接键盘检测（PC 兜底）
            local moveX = 0
            if joystick_ then
                local jx, _ = joystick_:getMovement(false)
                if math.abs(jx) > 0.1 then
                    moveX = jx > 0 and 1 or -1
                end
            end
            -- PC 直接键盘检测（WASD + 箭头键，确保 PC 输入永远可用）
            if moveX == 0 then
                if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
                    moveX = -1
                elseif input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
                    moveX = 1
                end
            end
            p.inputMoveX = moveX

            -- 跳跃：VirtualControls 回调（手机）+ 直接键盘检测（PC 兜底）
            if jumpPressed_ or input:GetKeyPress(KEY_SPACE) then
                p.inputJump = true
                jumpPressed_ = false
            end

            -- 冲刺：VirtualControls 回调（手机）+ 直接键盘/鼠标检测（PC 兜底）
            if dashPressed_ or input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
                p.inputDash = true
                dashPressed_ = false
            end

            -- 下砸：VirtualControls 回调（手机）+ 直接键盘检测（PC 兜底）
            if slamPressed_ or input:GetKeyPress(KEY_S) or input:GetKeyPress(KEY_DOWN) then
                p.inputSlam = true
                slamPressed_ = false
            end

            -- 蓄力/爆炸：按钮按住 = 蓄力，松开 = 爆炸
            -- 触摸：仅爆炸按钮区域内触摸生效（VirtualControls 自带半径检测）
            -- PC：鼠标左键全局检测（非移动端才启用）
            local charging = false
            if chargeButton_ then
                charging = chargeButton_.isPressed
            end
            if not isMobile_ and input.numTouches == 0 and input:GetMouseButtonDown(MOUSEB_LEFT) then
                charging = true
            end
            if charging then p.inputCharging = true end
            if p.wasChargingInput and not charging then p.inputExplodeRelease = true end
            p.wasChargingInput = charging
        end
    end
end

---@return Scene
function Standalone.GetScene()
    return scene_
end

return Standalone

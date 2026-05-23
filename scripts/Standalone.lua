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
local Economy = require("Economy")
local ControlLayout = require("ControlLayout")
local PowerUp = require("PowerUp")
local FaceSkin = require("FaceSkin")
local PlatformUtils = require("urhox-libs.Platform.PlatformUtils")
local Tutorial = require("Tutorial")

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
local coinRewarded_ = false  -- 本局金币已发放

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

    -- 移动端检测（必须在 CreateScene 之前，因为场景光照依赖此判断）
    local dpr = graphics:GetDPR()
    local logH = graphics:GetHeight() / dpr
    isMobileDevice_ = (logH < 500)

    -- 移动端关闭 HDR（用手动光照，不需要 tone mapping）；PC 端开启 HDR（LightGroup 物理单位）
    if isMobileDevice_ then
        renderer.hdrRendering = false
    else
        renderer.hdrRendering = true
    end
    print("[Standalone] isMobile=" .. tostring(isMobileDevice_) .. " logH=" .. math.floor(logH) .. " HDR=" .. tostring(renderer.hdrRendering))

    -- 创建场景
    Standalone.CreateScene()

    -- 初始化子系统
    Map.Init(scene_)
    Player.Init(scene_, Map)
    Pickup.Init(scene_, Player)
    PowerUp.Init(Player)
    AIController.Init(Player, Map)
    SFX.Init(scene_)
    GameManager.Init(Player, Map, Pickup, AIController, RandomPickup, Camera)
    Camera.Init(scene_)
    Camera.SetPlayerModule(Player)

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)

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

    -- 初始化教程模块
    Tutorial.Init(Player, GameManager, Map)

    -- 加载经济数据（云存档）— 加载完成后检测是否需要自动进入教程
    Economy.Load(function()
        if not Economy.IsTutorialDone() then
            print("[Standalone] First-time player detected → entering tutorial")
            coinRewarded_ = false
            Camera.spectateMode = false
            Standalone.SetVirtualControlsVisible(true)
            SFX.PlayGameBGM()
            SFX.EnableSFX()
            GameManager.EnterTutorial()
            Tutorial.Start()
        end
    end)

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
        position = Vector2(266, -203),
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

    -- 跳跃按钮中心位置：整体右移一个跳按钮直径(196px)
    local jumpRight = 340 - 196   -- 144，更靠右
    local jumpBottom = 172 + 39   -- 往上移（bottom 值增大 = 离底边更远 = 更靠上）

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

    -- 冲刺（跳跃按钮的左偏下方）
    -- X: 更负=更左, Y: 更正=更靠底边=更低
    dashButton_ = VirtualControls.CreateButton({
        position = Vector2(-jumpRight - 183, -jumpBottom + 67),
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

    -- 下砸（跳跃按钮的左上方）
    slamButton_ = VirtualControls.CreateButton({
        position = Vector2(-jumpRight - 160, -jumpBottom - 112),
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

    -- 蓄力/爆炸（跳跃按钮的正上方）
    -- 注意：不设 mouseBinding，触摸只在按钮半径内生效；PC 鼠标左键在 HandlePlayerInput 中单独处理
    chargeButton_ = VirtualControls.CreateButton({
        position = Vector2(-jumpRight + 34, -jumpBottom - 192),
        alignment = {HA_RIGHT, VA_BOTTOM},
        radius = smallR,
        label = "爆",
        color = {255, 200, 50},
        pressedColor = {255, 240, 100},
        opacity = 0.35,
        activeOpacity = 0.8,
    })

    print("[Standalone] Mobile controls initialized (landscape), isMobile=" .. tostring(isMobile_))

    -- 告知 Tutorial 哪些区域是虚拟控制区（避免"点击继续"被触控误触）
    -- 所有控件均为 VA_BOTTOM，计算逻辑坐标下的包围盒，整体下扩一些确保覆盖
    do
        local dpr2 = graphics:GetDPR()
        local lw = graphics:GetWidth() / dpr2
        local lh = graphics:GetHeight() / dpr2
        -- VirtualControls 内部用物理像素，mx/my 是逻辑像素，必须除以 DPR 统一坐标系
        local physScaleFactor = VirtualControls.GetScaleFactor and VirtualControls.GetScaleFactor() or 1
        local s = physScaleFactor / dpr2  -- 逻辑像素缩放因子
        -- 左侧摇杆区域（逻辑坐标）
        local jsRadius = 154 * s
        local jsCX    = 266 * s
        local jsCY    = lh - 203 * s
        -- 右侧按钮群（以跳跃按钮为中心，整体覆盖）
        local btnGroupR  = 200  -- 设计像素半径
        local btnCX = lw - jumpRight * s
        local btnCY = lh - jumpBottom * s
        Tutorial.SetMobileExcludeRects({
            -- 摇杆区：中心 ± radius，并向下扩展到屏幕底边
            { jsCX - jsRadius, jsCY - jsRadius, jsCX + jsRadius, lh },
            -- 右侧按钮群：以跳跃按钮为中心扩大覆盖
            { btnCX - btnGroupR * s, btnCY - btnGroupR * s, lw, lh },
        })
    end

    -- 从云端加载自定义布局并应用
    ControlLayout.LoadFromCloud(function(layout)
        Standalone.ApplyLayout(layout)
        print("[Standalone] Custom layout applied")
    end)

    -- 覆盖按钮渲染：使用自定义图片替代程序化圆形
    OverrideButtonRendering()

    -- 初始状态：菜单中不显示虚拟控件
    Standalone.SetVirtualControlsVisible(false)
end

-- ============================================================================
-- 自定义按钮图片渲染
-- ============================================================================

-- 按钮图片 NanoVG 句柄缓存（按 ctx 地址分开缓存，避免重建）
local btnImageHandles_ = {}

--- 计算按钮在设计坐标系中的位置（复刻 VirtualControls 内部的 calculateScreenPosition）
local function calcDesignPos(position, alignment)
    local hAlign = alignment[1] or HA_LEFT
    local vAlign = alignment[2] or VA_TOP
    local x, y = position.x, position.y

    local screenW, screenH = VirtualControls.GetScreenSize()
    local designW, designH = VirtualControls.GetDesignSize()
    local scaleFactor = VirtualControls.GetScaleFactor()

    local offsetX = (screenW - designW * scaleFactor) / 2
    local offsetY = (screenH - designH * scaleFactor) / 2

    -- 安全区边距
    local safeLeft, safeTop, safeRight, safeBottom = 0, 0, 0, 0
    if GetSafeAreaInsets then
        local rect = GetSafeAreaInsets(false)
        if rect then
            safeLeft = rect.min.x
            safeTop = rect.min.y
            safeRight = rect.max.x
            safeBottom = rect.max.y
        end
    end

    -- 屏幕边缘在设计坐标系中的位置
    local screenLeftInDesign = -offsetX / scaleFactor
    local screenRightInDesign = (screenW - offsetX) / scaleFactor
    local screenTopInDesign = -offsetY / scaleFactor
    local screenBottomInDesign = (screenH - offsetY) / scaleFactor

    -- 安全区转设计坐标
    local sL = safeLeft / scaleFactor
    local sR = safeRight / scaleFactor
    local sT = safeTop / scaleFactor
    local sB = safeBottom / scaleFactor

    if hAlign == HA_LEFT then
        x = screenLeftInDesign + sL + x
    elseif hAlign == HA_CENTER then
        x = designW / 2 + x
    elseif hAlign == HA_RIGHT then
        x = screenRightInDesign - sR + x
    end

    if vAlign == VA_TOP then
        y = screenTopInDesign + sT + y
    elseif vAlign == VA_CENTER then
        y = designH / 2 + y
    elseif vAlign == VA_BOTTOM then
        y = screenBottomInDesign - sB + y
    end

    return x, y
end

--- 获取或创建按钮图片的 NanoVG 句柄
local function getButtonImage(ctx, imagePath)
    if not btnImageHandles_[imagePath] then
        local handle = nvgCreateImage(ctx, imagePath, 0)
        if handle and handle >= 0 then
            btnImageHandles_[imagePath] = handle
        else
            print("[Standalone] WARNING: Failed to load button image: " .. imagePath)
            return nil
        end
    end
    return btnImageHandles_[imagePath]
end

--- 创建自定义图片渲染函数
local function makeImageRender(originalBtn, imagePath)
    -- 保存原始 render 的引用（备用）
    local origRender = originalBtn.render

    return function(self, ctx)
        if not self._shouldShow then return end

        local centerX, centerY = calcDesignPos(self.position, self.alignment)
        local alpha = math.floor(self.currentOpacity * 255)
        local radius = self.radius * self.currentScale

        -- 获取图片句柄（懒加载）
        local imgHandle = getButtonImage(ctx, imagePath)

        if imgHandle then
            -- 按下时略微缩小以示反馈
            local drawRadius = radius
            if self.isPressed then
                drawRadius = radius * 0.92
            end

            -- 绘制按钮图片（50% 透明度 × 当前 opacity）
            local imgAlpha = self.currentOpacity * 0.65
            local drawSize = drawRadius * 2
            local drawX = centerX - drawRadius
            local drawY = centerY - drawRadius

            local paint = nvgImagePattern(ctx, drawX, drawY, drawSize, drawSize, 0, imgHandle, imgAlpha)
            nvgBeginPath(ctx)
            nvgCircle(ctx, centerX, centerY, drawRadius)
            nvgFillPaint(ctx, paint)
            nvgFill(ctx)
        else
            -- 图片加载失败时回退到原始渲染
            origRender(self, ctx)
            return
        end

        -- 冷却遮罩（保留原始逻辑）
        if self.cooldownRemaining > 0 and self.cooldown > 0 then
            local progress = self.cooldownRemaining / self.cooldown
            local startAngle = -math.pi / 2
            local endAngle = startAngle + progress * math.pi * 2

            nvgBeginPath(ctx)
            nvgMoveTo(ctx, centerX, centerY)
            nvgArc(ctx, centerX, centerY, radius, startAngle, endAngle, NVG_CW)
            nvgClosePath(ctx)
            nvgFillColor(ctx, nvgRGBA(0, 0, 0, 150))
            nvgFill(ctx)
        end
    end
end

--- 覆盖所有按钮的渲染方法
function OverrideButtonRendering()
    local btnImageMap = {
        { btn = jumpButton_,   image = "image/btn_jump.png" },
        { btn = dashButton_,   image = "image/btn_dash.png" },
        { btn = slamButton_,   image = "image/btn_slam.png" },
        { btn = chargeButton_, image = "image/btn_charge.png" },
    }

    for _, entry in ipairs(btnImageMap) do
        if entry.btn then
            entry.btn.render = makeImageRender(entry.btn, entry.image)
        end
    end

    print("[Standalone] Button rendering overridden with custom images")
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

--- 获取虚拟控件引用（供键位编辑器保存后应用布局）
function Standalone.GetVirtualControls()
    return joystick_, jumpButton_, dashButton_, slamButton_, chargeButton_
end

--- 将布局应用到当前虚拟控件
function Standalone.ApplyLayout(layout)
    ControlLayout.ApplyToControls(layout,
        joystick_, jumpButton_, dashButton_, slamButton_, chargeButton_)
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

    if isMobileDevice_ then
        -- 移动端：不加载 LightGroup，直接创建手动光照（方向与 Daytime.xml 一致）
        -- 这样避免运行时修改 Light 组件（WASM 上会崩溃）
        Standalone.CreateMobileLighting()
    else
        -- PC端：使用 LightGroup/Daytime.xml + HDR
        local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Daytime.xml")
        if lightGroupFile then
            local lightGroup = scene_:CreateChild("LightGroup")
            lightGroup:LoadXML(lightGroupFile:GetRoot())
            local zoneComp = lightGroup:GetComponent("Zone")
            if not zoneComp then
                local nz = lightGroup:GetNumChildren(false)
                for i = 0, nz - 1 do
                    local child = lightGroup:GetChild(i)
                    if child then
                        zoneComp = child:GetComponent("Zone")
                        if zoneComp then break end
                    end
                end
            end
            if zoneComp then
                zoneComp.fogColor = Color(0.95, 0.82, 0.68)
            end
            -- shadowIntensity 0.0 = 完全黑色阴影（原值 0.5 = 半透明）
            pcall(function()
                local allLights = lightGroup:GetChildrenWithComponent("Light", true)
                if allLights then
                    for _, child in ipairs(allLights) do
                        pcall(function()
                            local light = child:GetComponent("Light")
                            if light then
                                light:SetShadowIntensity(0.0)
                            end
                        end)
                    end
                end
            end)
            print("[Standalone] PC: LightGroup loaded, shadowIntensity=0.0")
        else
            Standalone.CreateFallbackLighting()
        end
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

--- 移动端专用光照：标准单位（无需 HDR），方向匹配 PC 阴影
function Standalone.CreateMobileLighting()
    local zoneNode = scene_:CreateChild("Zone")
    local zone = zoneNode:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(-200.0, 200.0)
    zone.ambientColor = Color(0.08, 0.08, 0.12)
    zone.fogColor = Color(0.95, 0.82, 0.68)
    zone.fogStart = 80.0
    zone.fogEnd = 150.0

    local lightNode = scene_:CreateChild("DirectionalLight")
    lightNode.direction = Vector3(-0.6, -1.0, 0.8)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_DIRECTIONAL
    light.color = Color(0.8, 0.7, 0.6)
    light.brightness = 1.0
    light.castShadows = true
    light.shadowIntensity = 0.0
    light.shadowBias = BiasParameters(0.00025, 0.5)
    light.shadowCascade = CascadeParameters(10.0, 50.0, 200.0, 0.0, 0.8)
    print("[Standalone] MobileLighting created (deeper shadows: ambient=0.08, brightness=1.0)")
end

--- 兜底光照（仅在 LightGroup 加载失败时使用）
function Standalone.CreateFallbackLighting()
    local zoneNode = scene_:CreateChild("Zone")
    local zone = zoneNode:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(-200.0, 200.0)
    zone.ambientColor = Color(0.35, 0.30, 0.45)
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
    print("[Standalone] FallbackLighting created")
end

-- ============================================================================
-- 游戏内容
-- ============================================================================

function Standalone.CreateBackgroundPlane()
    local topColor = Config.BgColorTop
    local botColor = Config.BgColorBot
    -- 覆盖整个地图高度 + 上下余量（背景中心在地图纵向中点）
    local mapH = MapData.Height * Config.BlockSize
    local size = math.max(200, math.ceil(mapH * 0.5 + 50))
    local strips = 8
    local bgNode = scene_:CreateChild("BackgroundGradient")
    bgNode.position = Vector3(0, mapH * 0.5, 5)

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
            coinRewarded_ = false
            Camera.spectateMode = false
            Standalone.SetVirtualControlsVisible(true)
            SFX.PlayGameBGM()
            SFX.EnableSFX()
            GameManager.gameMode = Config.GAMEMODE_ONELIFE
            GameManager.StartGame()
            Standalone.UpdateDeathZone()
        elseif btn == "onelife" then
            coinRewarded_ = false
            Camera.spectateMode = false
            Standalone.SetVirtualControlsVisible(true)
            SFX.PlayGameBGM()
            SFX.EnableSFX()
            GameManager.gameMode = Config.GAMEMODE_NORMAL
            GameManager.StartGame()
            Standalone.UpdateDeathZone()
        elseif btn == "shop" then
            HUD.SetShopOpen(true)
        elseif btn == "layoutEditor" then
            HUD.OpenLayoutEditor()
        elseif btn == "tutorial" then
            coinRewarded_ = false
            Camera.spectateMode = false
            Standalone.SetVirtualControlsVisible(true)
            SFX.PlayGameBGM()
            SFX.EnableSFX()
            GameManager.EnterTutorial()
            Tutorial.Start()
        end
    end

    -- 教程状态（Update 延迟到 HandlePlayerInput 之后，见下方）
    if GameManager.state == GameManager.STATE_TUTORIAL then
        Camera.spectateMode = false
        Standalone.SetVirtualControlsVisible(true)
        -- 清除所有 AI 输入，防止残留移动
        for _, p in ipairs(Player.list) do
            if not p.isHuman then
                p.inputMoveX = 0
                p.inputJump = false
                p.inputDash = false
                p.inputSlam = false
                p.inputCharging = false
                p.inputExplodeRelease = false
            end
        end
    end

    -- 结算画面（不阻塞后续逻辑，AI 继续运行）
    -- 复活选择画面（一命通天模式）
    if GameManager.state == GameManager.STATE_REVIVE then
        Camera.spectateMode = true
        Standalone.SetVirtualControlsVisible(false)

        local btn = HUD.GetReviveButtonClicked()
        if btn == "coin" then
            local cost = GameManager.reviveCoinUsed == 0 and 100 or 200
            if Economy.GetCoins() >= cost then
                Economy.AddCoins(-cost)
                Economy.Save()
                GameManager.reviveCoinUsed = GameManager.reviveCoinUsed + 1
                GameManager.RevivePlayer()
                Camera.spectateMode = false
                Standalone.SetVirtualControlsVisible(true)
                SFX.Play("pickup_large", 0.8)
                print("[Standalone] 金币复活成功，花费 " .. cost .. " 金币 (第 " .. GameManager.reviveCoinUsed .. " 次)")
            end
        elseif btn == "ad" then
            if GameManager.reviveAdUsed < 1 and not GameManager.reviveWaitingAd then
                GameManager.reviveWaitingAd = true
                print("[Standalone] 请求播放激励视频广告...")
                ---@diagnostic disable-next-line: undefined-global
                sdk:ShowRewardVideoAd(function(result)
                    GameManager.reviveWaitingAd = false
                    if result.success then
                        GameManager.reviveAdUsed = GameManager.reviveAdUsed + 1
                        GameManager.RevivePlayer()
                        Camera.spectateMode = false
                        Standalone.SetVirtualControlsVisible(true)
                        SFX.Play("pickup_large", 0.8)
                        print("[Standalone] 广告复活成功")
                    else
                        print("[Standalone] 广告播放失败: " .. tostring(result.msg))
                    end
                end)
            end
        elseif btn == "giveup" then
            GameManager.GiveUpRevive()
        end
    end

    if GameManager.state == GameManager.STATE_RESULT then
        Camera.spectateMode = true
        Standalone.SetVirtualControlsVisible(false)
        -- 发放本局金币奖励（仅一次）
        if not coinRewarded_ then
            coinRewarded_ = true
            local score = 0
            for _, p in ipairs(Player.list) do
                if p.isHuman then score = p.score or 0; break end
            end
            local reward = Economy.RewardFromScore(score)
            if reward > 0 then
                print("[Standalone] 本局奖励金币: " .. reward .. " (分数=" .. score .. ")")
            end
        end
        local btn = HUD.GetResultButtonClicked()
        if btn == "restart" then
            coinRewarded_ = false
            Camera.spectateMode = false
            Standalone.SetVirtualControlsVisible(true)
            SFX.PlayGameBGM()
            SFX.EnableSFX()
            -- gameMode 保持不变，再来一局沿用当前模式
            GameManager.Restart()
            Standalone.UpdateDeathZone()
        elseif btn == "menu" then
            SFX.PlayMenuBGM()
            SFX.DisableSFX()
            GameManager.gameMode = Config.GAMEMODE_ONELIFE  -- 返回菜单重置为一命通天（主模式）
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

    -- 教程状态：在 HandlePlayerInput 之后更新（确保能检测到本帧输入）
    if GameManager.state == GameManager.STATE_TUTORIAL then
        if Tutorial.IsActive() then
            -- 非能量步骤禁止蓄力/爆炸（防止点击触发爆炸）
            local step = Tutorial.GetCurrentStepId()
            if step ~= "energy" then
                for _, p in ipairs(Player.list) do
                    if p.isHuman then
                        p.inputCharging = false
                        p.inputExplodeRelease = false
                        p.wasChargingInput = false
                    end
                end
            end
            Tutorial.Update(dt)
        end
        -- 教程结束（通关或跳过）→ 返回菜单
        -- 注意：Tutorial.Finish() 可能在 NanoVGRender 帧（Draw）中被调用，
        -- 此时 IsActive() 已为 false，须在外层 STATE_TUTORIAL 块中检测
        if not Tutorial.IsActive() then
            print("[Standalone] Tutorial finished → returning to menu")
            Camera.spectateMode = true
            Standalone.SetVirtualControlsVisible(false)
            SFX.PlayMenuBGM()
            SFX.DisableSFX()
            GameManager.EnterMenu()
        end
    end

    -- AI 在菜单/游戏中/结算时都可以运动（持久世界）
    if GameManager.CanAIMove() then
        AIController.Update(dt)
    end

    Player.UpdateAll(dt)
    Pickup.Update(dt)
    RandomPickup.Update(dt)
    PowerUp.Update(dt)
    SFX.UpdateBGM()

    if input:GetKeyPress(KEY_TAB) then
        debugDraw_ = not debugDraw_
    end
end

---@param dt number
function Standalone.HandlePostUpdate(dt)
    -- 物理步后纠正：清除冲刺期间重力污染的 Y 速度
    Player.PostUpdate()

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

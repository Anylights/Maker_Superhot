-- ============================================================================
-- tuning_main.lua - 手感调试关卡
-- 独立单人关卡，内嵌调参面板，调整后自动保存并应用到正式游戏
-- ============================================================================

local UI = require("urhox-libs/UI")
local Config = require("Config")

---@diagnostic disable: undefined-global
-- cjson / fileSystem 是引擎内置全局变量

-- ============================================================================
-- 全局变量
-- ============================================================================
---@type Scene
local scene_ = nil
---@type Node
local cameraNode_ = nil
---@type Node
local playerNode_ = nil
---@type RigidBody
local playerBody_ = nil

-- 玩家状态
local onGround_ = false
local jumpCount_ = 0
local dashTimer_ = 0
local dashCooldown_ = 0
local dashDir_ = 1
local lastFaceDir_ = 1

-- 保存文件
local SAVE_FILE = "tuning.json"

-- 可调参数（运行时值）
local params_ = {
    MoveSpeed       = Config.MoveSpeed,
    JumpSpeed       = Config.JumpSpeed,
    MaxJumps        = Config.MaxJumps,
    AirControlRatio = Config.AirControlRatio,
    DashSpeed       = Config.DashSpeed,
    DashDuration    = Config.DashDuration,
    DashCooldown    = Config.DashCooldown,
    GravityY        = -9.81,
    Friction        = 0.6,
    LinearDamping   = 0.05,
    Mass            = 1.0,
}

-- 参数定义（UI 滑块）
local PARAM_DEFS = {
    { key = "MoveSpeed",       label = "移动速度",     min = 2,    max = 25,   step = 0.5,  fmt = "%.1f" },
    { key = "JumpSpeed",       label = "跳跃力度",     min = 3,    max = 25,   step = 0.5,  fmt = "%.1f" },
    { key = "MaxJumps",        label = "最大跳跃次数", min = 1,    max = 5,    step = 1,    fmt = "%d"   },
    { key = "AirControlRatio", label = "空中控制系数", min = 0.1,  max = 1.0,  step = 0.05, fmt = "%.2f" },
    { key = "DashSpeed",       label = "冲刺速度",     min = 5,    max = 35,   step = 1,    fmt = "%.1f" },
    { key = "DashDuration",    label = "冲刺时长(s)",  min = 0.05, max = 0.5,  step = 0.01, fmt = "%.2f" },
    { key = "DashCooldown",    label = "冲刺冷却(s)",  min = 0.5,  max = 5.0,  step = 0.1,  fmt = "%.1f" },
    { key = "GravityY",        label = "重力加速度",   min = -30,  max = -3,   step = 0.5,  fmt = "%.1f" },
    { key = "Friction",        label = "摩擦力",       min = 0,    max = 2.0,  step = 0.05, fmt = "%.2f" },
    { key = "LinearDamping",   label = "线性阻尼",     min = 0,    max = 1.0,  step = 0.01, fmt = "%.2f" },
    { key = "Mass",            label = "玩家质量",     min = 0.2,  max = 5.0,  step = 0.1,  fmt = "%.1f" },
}

-- PBR 缓存
local pbrTech_ = nil

-- ============================================================================
-- 生命周期
-- ============================================================================

function Start()
    graphics.windowTitle = "手感调试关卡"

    pbrTech_ = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")

    -- 加载存档
    LoadParams()

    -- 初始化 UI
    UI.Init({
        fonts = {
            { family = "sans", weights = { normal = "Fonts/MiSans-Regular.ttf" } }
        },
        scale = UI.Scale.DEFAULT,
    })

    -- 创建场景
    CreateScene()

    -- 创建测试关卡
    CreateTestLevel()

    -- 创建玩家
    CreatePlayer()

    -- 设置相机
    SetupCamera()

    -- 创建调参面板 UI
    CreateTuningUI()

    -- 应用参数
    ApplyAllParams()

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")

    print("=== 手感调试关卡已启动 ===")
    print("WASD 移动 | 空格跳跃 | Shift 冲刺 | 左侧面板调参")
end

function Stop()
    UI.Shutdown()
end

-- ============================================================================
-- 场景
-- ============================================================================

function CreateScene()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    local pw = scene_:CreateComponent("PhysicsWorld")
    pw:SetGravity(Vector3(0, params_.GravityY, 0))

    -- 光照
    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Daytime.xml")
    if lightGroupFile then
        local lg = scene_:CreateChild("LightGroup")
        lg:LoadXML(lightGroupFile:GetRoot())
    end
end

--- 创建 PBR 材质
local function MakeMat(color, metallic, roughness)
    local mat = Material:new()
    mat:SetTechnique(0, pbrTech_)
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.7))
    return mat
end

--- 创建静态方块
local function MakeBox(name, pos, scale, color, metallic, roughness)
    local node = scene_:CreateChild(name)
    node.position = pos
    node.scale = scale
    local model = node:CreateComponent("StaticModel")
    model.model = cache:GetResource("Model", "Models/Box.mdl")
    model:SetMaterial(MakeMat(color, metallic, roughness))
    model.castShadows = true

    local body = node:CreateComponent("RigidBody")
    body.mass = 0  -- 静态
    body.friction = 0.8
    body.collisionLayer = 1
    body.collisionMask = 0xFFFF

    local shape = node:CreateComponent("CollisionShape")
    shape:SetBox(Vector3(1, 1, 1))

    return node
end

function CreateTestLevel()
    -- 地面
    MakeBox("Ground", Vector3(0, -0.5, 0), Vector3(60, 1, 10),
        Color(0.25, 0.25, 0.30), 0.0, 0.9)

    -- 阶梯平台（测试跳跃高度）
    MakeBox("Step1", Vector3(8, 1, 0), Vector3(4, 0.5, 4),
        Color(0.4, 0.7, 0.4), 0.0, 0.6)
    MakeBox("Step2", Vector3(13, 2.5, 0), Vector3(4, 0.5, 4),
        Color(0.4, 0.65, 0.45), 0.0, 0.6)
    MakeBox("Step3", Vector3(18, 4, 0), Vector3(4, 0.5, 4),
        Color(0.4, 0.6, 0.5), 0.0, 0.6)
    MakeBox("Step4", Vector3(23, 6, 0), Vector3(4, 0.5, 4),
        Color(0.4, 0.55, 0.55), 0.0, 0.6)

    -- 跳跃间隙平台（测试移动速度 + 跳跃距离）
    MakeBox("Gap1", Vector3(-8, 0, 0), Vector3(3, 0.5, 4),
        Color(0.7, 0.5, 0.3), 0.0, 0.6)
    MakeBox("Gap2", Vector3(-14, 0, 0), Vector3(3, 0.5, 4),
        Color(0.7, 0.45, 0.35), 0.0, 0.6)
    MakeBox("Gap3", Vector3(-21, 0, 0), Vector3(3, 0.5, 4),
        Color(0.7, 0.4, 0.4), 0.0, 0.6)

    -- 高台（测试二段跳）
    MakeBox("HighPlat", Vector3(0, 8, 0), Vector3(6, 0.5, 4),
        Color(0.8, 0.6, 0.2), 0.1, 0.4)

    -- 标记柱子（高度参考）
    for h = 2, 10, 2 do
        local pillar = scene_:CreateChild("Pillar_" .. h)
        pillar.position = Vector3(-3, h / 2, -3)
        pillar.scale = Vector3(0.2, h, 0.2)
        local pm = pillar:CreateComponent("StaticModel")
        pm.model = cache:GetResource("Model", "Models/Box.mdl")
        pm:SetMaterial(MakeMat(Color(0.9, 0.9, 0.2, 0.5), 0.0, 0.5))
    end

    print("[TuningLevel] Test level created")
end

-- ============================================================================
-- 玩家
-- ============================================================================

function CreatePlayer()
    playerNode_ = scene_:CreateChild("Player")
    playerNode_.position = Vector3(0, 1, 0)
    playerNode_.scale = Vector3(0.9, 0.9, 0.9)

    local model = playerNode_:CreateComponent("StaticModel")
    model.model = cache:GetResource("Model", "Models/Box.mdl")
    model:SetMaterial(MakeMat(Color(0.9, 0.25, 0.2), 0.1, 0.5))
    model.castShadows = true

    playerBody_ = playerNode_:CreateComponent("RigidBody")
    playerBody_.mass = params_.Mass
    playerBody_.friction = params_.Friction
    playerBody_.linearDamping = params_.LinearDamping
    playerBody_.collisionLayer = 2
    playerBody_.collisionMask = 0xFFFF
    playerBody_.collisionEventMode = COLLISION_ALWAYS
    playerBody_.linearFactor = Vector3(1, 1, 0)
    playerBody_.angularFactor = Vector3(0, 0, 0)

    local shape = playerNode_:CreateComponent("CollisionShape")
    shape:SetBox(Vector3(1, 1, 1))

    -- 碰撞检测（地面判定）
    SubscribeToEvent(playerNode_, "NodeCollision", "HandlePlayerCollision")

    print("[TuningLevel] Player created")
end

function HandlePlayerCollision(eventType, eventData)
    if eventData["Trigger"]:GetBool() then return end
    local contacts = eventData["Contacts"]:GetBuffer()
    while not contacts.eof do
        local pos = contacts:ReadVector3()
        local normal = contacts:ReadVector3()
        local dist = contacts:ReadFloat()
        local impulse = contacts:ReadFloat()
        if normal.y > 0.75 then
            onGround_ = true
            jumpCount_ = 0
        end
    end
end

-- ============================================================================
-- 相机（侧视正交）
-- ============================================================================

function SetupCamera()
    cameraNode_ = scene_:CreateChild("Camera")
    cameraNode_.position = Vector3(0, 5, -30)

    local camera = cameraNode_:CreateComponent("Camera")
    camera.orthographic = true
    camera.orthoSize = 20
    camera.nearClip = 0.1
    camera.farClip = 100.0

    local viewport = Viewport:new(scene_, camera)
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
end

-- ============================================================================
-- 更新
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 输入不被 UI 拦截时才处理
    if not UI.IsPointerOverUI() then
        HandlePlayerInput(dt)
    end

    -- 死亡重置
    if playerNode_.position.y < -15 then
        playerNode_.position = Vector3(0, 2, 0)
        playerBody_.linearVelocity = Vector3(0, 0, 0)
        jumpCount_ = 0
    end

    -- 每帧重置地面状态
    onGround_ = false
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType, eventData)
    -- 相机跟随玩家
    if playerNode_ then
        local pos = playerNode_.position
        local camPos = cameraNode_.position
        local targetX = pos.x
        local targetY = math.max(pos.y + 2, 5)
        cameraNode_.position = Vector3(
            camPos.x + (targetX - camPos.x) * 0.05,
            camPos.y + (targetY - camPos.y) * 0.05,
            camPos.z
        )
    end
end

function HandlePlayerInput(dt)
    if playerBody_ == nil then return end
    local vel = playerBody_.linearVelocity

    -- 冲刺冷却
    if dashCooldown_ > 0 then dashCooldown_ = dashCooldown_ - dt end

    -- 冲刺中
    if dashTimer_ > 0 then
        dashTimer_ = dashTimer_ - dt
        playerBody_.linearVelocity = Vector3(dashDir_ * params_.DashSpeed, vel.y, 0)
        return
    end

    -- 水平移动
    local moveX = 0
    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then moveX = -1 end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then moveX = 1 end

    if moveX ~= 0 then lastFaceDir_ = moveX > 0 and 1 or -1 end

    local speed = params_.MoveSpeed
    if not onGround_ then
        speed = speed * params_.AirControlRatio
        local targetVx = moveX * speed
        local blendedVx = vel.x + (targetVx - vel.x) * params_.AirControlRatio * 5 * dt
        playerBody_.linearVelocity = Vector3(blendedVx, vel.y, 0)
    else
        playerBody_.linearVelocity = Vector3(moveX * speed, vel.y, 0)
    end

    -- 跳跃
    if input:GetKeyPress(KEY_SPACE) or input:GetKeyPress(KEY_W) or input:GetKeyPress(KEY_UP) then
        if jumpCount_ < math.floor(params_.MaxJumps) then
            local jv = playerBody_.linearVelocity
            playerBody_.linearVelocity = Vector3(jv.x, 0, 0)
            playerBody_:ApplyImpulse(Vector3(0, params_.JumpSpeed, 0))
            jumpCount_ = jumpCount_ + 1
        end
    end

    -- 冲刺
    if input:GetKeyPress(KEY_SHIFT) and dashCooldown_ <= 0 then
        dashTimer_ = params_.DashDuration
        dashDir_ = lastFaceDir_
        dashCooldown_ = params_.DashCooldown
    end
end

-- ============================================================================
-- 参数应用
-- ============================================================================

function ApplyAllParams()
    -- 重力
    local pw = scene_:GetComponent("PhysicsWorld")
    if pw then pw:SetGravity(Vector3(0, params_.GravityY, 0)) end

    -- 玩家物理体
    if playerBody_ then
        playerBody_.friction = params_.Friction
        playerBody_.linearDamping = params_.LinearDamping
        playerBody_.mass = params_.Mass
    end
end

-- ============================================================================
-- 存档
-- ============================================================================

function SaveParams()
    local json = cjson.encode(params_)
    local f = File(SAVE_FILE, FILE_WRITE)
    if f then
        f:WriteString(json)
        f:Close()
        print("[TuningLevel] Saved params")
    end
end

function LoadParams()
    if not fileSystem:FileExists(SAVE_FILE) then
        print("[TuningLevel] No save file, using defaults")
        return
    end
    local ok, _ = pcall(function()
        local f = File(SAVE_FILE, FILE_READ)
        if f and f:IsOpen() then
            local str = f:ReadString()
            f:Close()
            if str and #str > 0 then
                local data = cjson.decode(str)
                for k, v in pairs(data) do
                    if params_[k] ~= nil then
                        params_[k] = v
                    end
                end
                print("[TuningLevel] Loaded saved params")
            end
        end
    end)
end

-- ============================================================================
-- 调参面板 UI
-- ============================================================================

function CreateTuningUI()
    local rows = {}

    for _, def in ipairs(PARAM_DEFS) do
        local val = params_[def.key]

        local valLabel = UI.Label {
            text = string.format(def.fmt, val),
            fontSize = 13,
            color = "#FFD54F",
            width = 55,
            textAlign = "right",
        }

        local row = UI.Panel {
            flexDirection = "row",
            alignItems = "center",
            width = "100%",
            paddingVertical = 4,
            children = {
                UI.Label {
                    text = def.label,
                    fontSize = 13,
                    color = "#E0E0E0",
                    width = 110,
                },
                UI.Slider {
                    value = val,
                    min = def.min,
                    max = def.max,
                    step = def.step,
                    flexGrow = 1,
                    height = 24,
                    onChange = function(self, v)
                        params_[def.key] = v
                        valLabel.text = string.format(def.fmt, v)
                        ApplyAllParams()
                    end,
                    onChangeEnd = function(self, v)
                        SaveParams()
                    end,
                },
                valLabel,
            }
        }
        table.insert(rows, row)
    end

    -- 重置按钮
    table.insert(rows, UI.Panel {
        flexDirection = "row",
        justifyContent = "center",
        width = "100%",
        paddingTop = 10,
        children = {
            UI.Button {
                text = "重置默认值",
                variant = "outlined",
                size = "small",
                onClick = function(self)
                    params_ = {
                        MoveSpeed = 8.0, JumpSpeed = 10.0, MaxJumps = 2,
                        AirControlRatio = 0.7, DashSpeed = 15.0, DashDuration = 0.15,
                        DashCooldown = 2.0, GravityY = -9.81, Friction = 0.6,
                        LinearDamping = 0.05, Mass = 1.0,
                    }
                    ApplyAllParams()
                    SaveParams()
                    CreateTuningUI()  -- 重建 UI 刷新滑块
                end,
            },
        }
    })

    local root = UI.Panel {
        width = "100%",
        height = "100%",
        flexDirection = "row",
        children = {
            -- 左侧调参面板
            UI.Panel {
                width = 340,
                height = "100%",
                backgroundColor = "rgba(15, 15, 25, 0.93)",
                padding = 12,
                children = {
                    UI.Label {
                        text = "手感调参面板",
                        fontSize = 18,
                        fontWeight = "bold",
                        color = "#FFFFFF",
                        marginBottom = 6,
                        textAlign = "center",
                        width = "100%",
                    },
                    UI.Label {
                        text = "调整后自动保存，应用到正式游戏",
                        fontSize = 11,
                        color = "#888888",
                        marginBottom = 10,
                        textAlign = "center",
                        width = "100%",
                    },
                    UI.Panel {
                        width = "100%", height = 1,
                        backgroundColor = "rgba(255,255,255,0.12)",
                        marginBottom = 10,
                    },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexShrink = 1,
                        children = {
                            UI.Panel {
                                width = "100%",
                                children = rows,
                            }
                        }
                    },
                }
            },
            -- 右侧：操作提示（叠加在游戏画面上）
            UI.Panel {
                flexGrow = 1,
                height = "100%",
                pointerEvents = "box-none",
                children = {
                    UI.Label {
                        text = "WASD/方向键: 移动 | 空格/W/上: 跳跃 | Shift: 冲刺",
                        fontSize = 13,
                        color = "rgba(255,255,220,0.7)",
                        position = "absolute",
                        bottom = 16,
                        left = 0,
                        right = 0,
                        textAlign = "center",
                    },
                }
            },
        }
    }

    UI.SetRoot(root, true)
end

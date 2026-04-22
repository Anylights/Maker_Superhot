-- ============================================================================
-- Client.lua - 超级红温！ 联机客户端
-- 职责：输入采集 → controls.buttons、远程事件处理、视觉/HUD
-- ============================================================================

require "LuaScripts/Utilities/Sample"

local Config = require("Config")
local Shared = require("network.Shared")
local Camera = require("Camera")
local Map    = require("Map")
local MapData = require("MapData")
local Player = require("Player")
local Pickup = require("Pickup")
local AIController = require("AIController")
local GameManager = require("GameManager")
local HUD    = require("HUD")
local SFX    = require("SFX")
local RandomPickup = require("RandomPickup")
local LevelManager = require("LevelManager")
local LevelEditor  = require("LevelEditor")

local EVENTS = Shared.EVENTS
local CTRL   = Shared.CTRL

local Client = {}

-- ============================================================================
-- Client-side State
-- ============================================================================

-- 客户端自身阶段（与 GameManager 独立，用于 UI 路由）
local clientState_ = "menu"
-- "menu"          主菜单（快速开始 / 与朋友玩）
-- "quickMatching" 快速匹配中
-- "friendMenu"    朋友玩子菜单（开房间 / 加入房间）
-- "roomWaiting"   房间等待页（房主/普通成员共用）
-- "roomJoining"   输入房间码页
-- "playing"       游戏进行中（由 GameManager 驱动 HUD）

-- 玩家本机被分配的 slot
local mySlot_ = 0

-- 快速匹配队列信息
local quickPlayerCount_ = 0
local quickHumanCount_  = 0

-- 房间信息
local roomCode_     = ""
local roomPlayerCount_ = 0
local roomAICount_     = 0
local roomTotal_       = 0
local roomIsHost_      = false

-- 房间码输入缓冲（加入房间）
local roomCodeInput_ = ""

-- 失败/提示消息
local toastMessage_  = ""
local toastTimer_    = 0

-- 服务端连接
---@type Connection
local serverConnection_ = nil

---@type Scene
local scene_ = nil

local debugDraw_ = false

-- ============================================================================
-- Connection Helper (must be defined before Start so Start can call it)
-- ============================================================================

--- 是否需要发送 CLIENT_READY（延迟到下一帧 Update 中发送）
local needSendReady_ = false

--- 公共：获取到服务器连接后的初始化
local function OnServerConnectionReady()
    if serverConnection_ ~= nil then
        -- 已经初始化过了，不重复执行
        return
    end

    local conn = network:GetServerConnection()
    if conn == nil then
        print("[Client] WARNING: server connection is nil")
        return
    end

    serverConnection_ = conn
    -- 客户端先设置自己的 scene，让引擎知道接收哪个场景的同步数据
    serverConnection_.scene = scene_
    -- 标记需要发送 CLIENT_READY（在下一帧 Update 中发送，确保场景分配完成）
    needSendReady_ = true

    print("[Client] Server connection established, scene assigned, will send CLIENT_READY next frame")
end

-- ============================================================================
-- Entry
-- ============================================================================

function Client.Start()
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " (Client) ===")

    -- 创建场景
    Client.CreateScene()

    -- 初始化子系统
    Map.Init(scene_)
    Player.SetNetworkMode("client")
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

    -- 创建背景
    Client.CreateBackgroundPlane()

    -- 初始化 HUD
    HUD.Init(Player, GameManager, Map)

    -- 初始化随机道具、关卡管理器、关卡编辑器
    RandomPickup.Init(Map, Pickup)
    LevelManager.Init()
    LevelEditor.Init(HUD.GetNVGContext(), GameManager, Map)
    HUD.SetLevelEditor(LevelEditor)

    -- 设置初始相机
    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
    GameManager.EnterMenu()

    -- 监听连接事件
    SubscribeToEvent("ServerConnected", "HandleServerConnected")
    SubscribeToEvent("ServerDisconnected", "HandleServerDisconnected")
    SubscribeToEvent("ConnectFailed", "HandleConnectFailed")
    -- 后台匹配模式：脚本加载时服务器可能未就绪，需等待 ServerReady
    SubscribeToEvent("ServerReady", "HandleServerReady")

    -- 监听服务端远程事件
    SubscribeToEvent(EVENTS.ASSIGN_ROLE, "HandleAssignRole")
    SubscribeToEvent(EVENTS.ROOM_CREATED, "HandleRoomCreated")
    SubscribeToEvent(EVENTS.ROOM_JOINED, "HandleRoomJoined")
    SubscribeToEvent(EVENTS.ROOM_UPDATE, "HandleRoomUpdate")
    SubscribeToEvent(EVENTS.ROOM_DISMISSED, "HandleRoomDismissed")
    SubscribeToEvent(EVENTS.GAME_STARTING, "HandleGameStarting")
    SubscribeToEvent(EVENTS.GAME_STATE, "HandleGameState")
    SubscribeToEvent(EVENTS.JOIN_FAILED, "HandleJoinFailed")
    SubscribeToEvent(EVENTS.MATCH_FOUND, "HandleMatchFound")
    SubscribeToEvent(EVENTS.QUICK_UPDATE, "HandleQuickUpdate")
    SubscribeToEvent(EVENTS.KILL_EVENT, "HandleKillEvent")

    -- 击杀回调 → HUD 消费
    GameManager.OnKill(function(killerIdx, victimIdx, multiKill, killStreak)
        -- 客户端的击杀事件由服务端远程事件驱动，此回调留空
    end)

    -- 主动尝试获取已有连接
    -- persistent_world / background_match 模式下，Lobby 可能在脚本加载前就已完成连接
    -- 此时 ServerConnected/ServerReady 事件可能已经触发过了，需要主动检测
    local existingConn = network:GetServerConnection()
    if existingConn then
        OnServerConnectionReady()
        print("[Client] Connection already available at start")
    else
        print("[Client] Started, waiting for server connection...")
    end
end

function Client.Stop()
    print("[Client] Stopped")
end

-- ============================================================================
-- Scene Creation
-- ============================================================================

function Client.CreateScene()
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
        Client.CreateFallbackLighting()
    end

    -- 死亡区域（客户端也创建，用于本地物理预测）
    local deathZone = scene_:CreateChild("DeathZone")
    deathZone.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
    deathZone.scale = Vector3(MapData.Width + 20, 2, 10)
    local dzBody = deathZone:CreateComponent("RigidBody")
    dzBody.trigger = true
    dzBody.collisionLayer = 4
    dzBody.collisionMask = 2
    local dzShape = deathZone:CreateComponent("CollisionShape")
    dzShape:SetBox(Vector3(1, 1, 1))

    print("[Client] Scene created")
end

function Client.CreateFallbackLighting()
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

function Client.CreateBackgroundPlane()
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

-- ============================================================================
-- Connection Events
-- ============================================================================

function HandleServerConnected(eventType, eventData)
    OnServerConnectionReady()
    print("[Client] Connected to server (ServerConnected)")
end

--- 后台匹配模式：匹配成功、服务器脚本已加载后触发
function HandleServerReady(eventType, eventData)
    OnServerConnectionReady()
    print("[Client] Server ready (background match completed)")
end

function HandleServerDisconnected(eventType, eventData)
    serverConnection_ = nil
    mySlot_ = 0
    clientState_ = "menu"
    Client.ShowToast("与服务器断开连接")
    print("[Client] Disconnected from server")
end

function HandleConnectFailed(eventType, eventData)
    serverConnection_ = nil
    clientState_ = "menu"
    Client.ShowToast("连接服务器失败")
    print("[Client] Connection failed")
end

-- ============================================================================
-- Remote Event Handlers (Server → Client)
-- ============================================================================

function HandleAssignRole(eventType, eventData)
    mySlot_ = eventData["Slot"]:GetInt()
    local mapW = eventData["MapWidth"]:GetInt()
    local mapH = eventData["MapHeight"]:GetInt()

    print("[Client] Assigned slot: " .. mySlot_ .. " map: " .. mapW .. "x" .. mapH)

    -- 更新 MapData 尺寸
    MapData.Width = mapW
    MapData.Height = mapH

    -- 建图（客户端需要视觉）
    Map.Build()

    -- 从场景中查找已复制的玩家节点并创建 Player 数据
    Player.list = {}
    for i = 1, Config.NumPlayers do
        local nodeName = "Player_" .. i
        local existingNode = scene_:GetChild(nodeName, true)
        if existingNode then
            local p = Player.Create(i, (i == mySlot_), { existingNode = existingNode })
            -- 挂载视觉组件
            Player.AttachVisuals(p)
            -- 非本机玩家注册为 AI（客户端不控制它们，位置由服务端复制同步）
            if i ~= mySlot_ then
                p.isHuman = false
            end
        else
            -- 节点尚未复制到位，创建本地占位（后续可在 NodeAdded 中补）
            local p = Player.Create(i, (i == mySlot_))
            Player.AttachVisuals(p)
            if i ~= mySlot_ then
                p.isHuman = false
            end
            print("[Client] Warning: node " .. nodeName .. " not found, created locally")
        end
    end

    -- 初始化道具
    Pickup.Reset()
    RandomPickup.Reset()

    -- 设置相机
    Camera.SetFixedForMap(mapW, mapH, 2)

    -- 更新死亡区域
    local dz = scene_:GetChild("DeathZone", false)
    if dz then
        dz.position = Vector3(mapW * 0.5, Config.DeathY, 0)
        dz.scale = Vector3(mapW + 20, 2, 10)
    end

    -- 进入游戏状态
    clientState_ = "playing"
    GameManager.StartMatch()

    print("[Client] Game started, I am player " .. mySlot_)
end

function HandleRoomCreated(eventType, eventData)
    roomCode_ = eventData["RoomCode"]:GetString()
    roomIsHost_ = true
    clientState_ = "roomWaiting"
    print("[Client] Room created: " .. roomCode_)
end

function HandleRoomJoined(eventType, eventData)
    roomCode_ = eventData["RoomCode"]:GetString()
    roomIsHost_ = false
    clientState_ = "roomWaiting"
    print("[Client] Joined room: " .. roomCode_)
end

function HandleRoomUpdate(eventType, eventData)
    roomCode_ = eventData["RoomCode"]:GetString()
    roomPlayerCount_ = eventData["PlayerCount"]:GetInt()
    roomAICount_ = eventData["AICount"]:GetInt()
    roomTotal_ = eventData["Total"]:GetInt()
    roomIsHost_ = eventData["IsHost"]:GetBool()
    print("[Client] Room update: " .. roomPlayerCount_ .. " players + " .. roomAICount_ .. " AI = " .. roomTotal_)
end

function HandleRoomDismissed(eventType, eventData)
    clientState_ = "menu"
    roomCode_ = ""
    Client.ShowToast("房间已解散")
    print("[Client] Room dismissed")
end

function HandleGameStarting(eventType, eventData)
    mySlot_ = eventData["Slot"]:GetInt()
    Client.ShowToast("游戏即将开始...")
    print("[Client] Game starting, my slot: " .. mySlot_)
end

function HandleGameState(eventType, eventData)
    if clientState_ ~= "playing" then return end

    local serverState = eventData["State"]:GetString()
    local round = eventData["Round"]:GetInt()

    -- 同步分数
    for i = 1, Config.NumPlayers do
        GameManager.scores[i] = eventData["Score" .. i]:GetInt()
        GameManager.killScores[i] = eventData["KillScore" .. i]:GetInt()
    end

    -- 同步回合结果
    local resultCount = eventData["ResultCount"]:GetInt()
    GameManager.roundResults = {}
    for i = 1, resultCount do
        table.insert(GameManager.roundResults, eventData["Result" .. i]:GetInt())
    end

    GameManager.round = round

    -- 同步状态（如果变化了）
    if serverState ~= GameManager.state then
        GameManager.SetState(serverState)
    end

    -- 同步计时器
    GameManager.stateTimer = eventData["CountdownTimer"]:GetFloat()
    GameManager.roundTimer = eventData["RoundTimer"]:GetFloat()

    -- 比赛结束 → 回到菜单
    if serverState == GameManager.STATE_MENU then
        clientState_ = "menu"
        mySlot_ = 0
        Player.list = {}
        Map.Clear()
    end
end

function HandleJoinFailed(eventType, eventData)
    local reason = eventData["Reason"]:GetString()
    Client.ShowToast(reason)
    print("[Client] Join failed: " .. reason)
end

function HandleMatchFound(eventType, eventData)
    mySlot_ = eventData["Slot"]:GetInt()
    Client.ShowToast("匹配成功！")
    print("[Client] Match found, slot: " .. mySlot_)
end

function HandleQuickUpdate(eventType, eventData)
    quickPlayerCount_ = eventData["PlayerCount"]:GetInt()
    quickHumanCount_ = eventData["HumanCount"]:GetInt()
    print("[Client] Quick update: " .. quickPlayerCount_ .. " total (" .. quickHumanCount_ .. " human)")
end

function HandleKillEvent(eventType, eventData)
    local killerIdx = eventData["Killer"]:GetInt()
    local victimIdx = eventData["Victim"]:GetInt()
    local multiKill = eventData["MultiKill"]:GetInt()
    local killStreak = eventData["KillStreak"]:GetInt()

    -- 推入 GameManager 击杀事件队列（供 HUD 消费）
    -- 字段名必须与 GameManager.OnPlayerKill 一致：killerIndex, victimIndex, multiKillCount, killStreak
    table.insert(GameManager.killEvents, {
        killerIndex = killerIdx,
        victimIndex = victimIdx,
        multiKillCount = multiKill,
        killStreak = killStreak,
    })
end

-- ============================================================================
-- Input Collection
-- ============================================================================

function Client.CollectInput()
    if serverConnection_ == nil then return end
    if mySlot_ == 0 then return end
    if clientState_ ~= "playing" then return end

    local buttons = 0

    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        buttons = buttons | CTRL.LEFT
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        buttons = buttons | CTRL.RIGHT
    end
    if input:GetKeyPress(KEY_SPACE) then
        buttons = buttons | CTRL.JUMP
    end
    if input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
        buttons = buttons | CTRL.DASH
    end
    if input:GetMouseButtonDown(MOUSEB_LEFT) then
        buttons = buttons | CTRL.CHARGE
    end
    -- 蓄力松开检测：上帧按着，本帧松开
    if not input:GetMouseButtonDown(MOUSEB_LEFT) and input:GetMouseButtonDown(MOUSEB_LEFT) == false then
        -- 通过 pulse button 机制，服务端会自动处理
        -- 这里只在松开瞬间设置
    end
    -- 使用简化方式：如果左键刚释放（上一帧按着 → 本帧没按），设 EXPLODE_RELEASE
    -- 由于我们没有跟踪上一帧左键状态，利用 GetMouseButtonPress 的反向逻辑
    -- 实际上 SetPulseButtonMask 已设置了 EXPLODE_RELEASE，只需在松开时 set bit
    -- 但 controls.buttons 是持续状态……我们需要追踪上帧
    -- → 改用本地变量跟踪

    serverConnection_.controls.buttons = buttons
end

-- 左键追踪（用于检测松开事件）
local wasLeftDown_ = false

function Client.CollectInputAdvanced()
    if serverConnection_ == nil then return end
    if mySlot_ == 0 then return end
    if clientState_ ~= "playing" then return end
    if not GameManager.CanPlayersMove() then
        serverConnection_.controls.buttons = 0
        return
    end

    local buttons = 0

    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        buttons = buttons | CTRL.LEFT
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        buttons = buttons | CTRL.RIGHT
    end
    if input:GetKeyPress(KEY_SPACE) then
        buttons = buttons | CTRL.JUMP
    end
    if input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
        buttons = buttons | CTRL.DASH
    end

    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    if leftDown then
        buttons = buttons | CTRL.CHARGE
    end
    if wasLeftDown_ and not leftDown then
        buttons = buttons | CTRL.EXPLODE_RELEASE
    end
    wasLeftDown_ = leftDown

    serverConnection_.controls.buttons = buttons
end

-- ============================================================================
-- Toast Messages
-- ============================================================================

function Client.ShowToast(msg)
    toastMessage_ = msg
    toastTimer_ = 3.0
end

-- ============================================================================
-- Client State Accessors (for HUD)
-- ============================================================================

--- 获取客户端当前阶段
function Client.GetState()
    return clientState_
end

--- 获取快速匹配信息
function Client.GetQuickMatchInfo()
    return quickPlayerCount_, quickHumanCount_
end

--- 获取房间信息
function Client.GetRoomInfo()
    return roomCode_, roomPlayerCount_, roomAICount_, roomTotal_, roomIsHost_
end

--- 获取本机分配的 slot
function Client.GetMySlot()
    return mySlot_
end

--- 获取 toast 信息
function Client.GetToast()
    return toastMessage_, toastTimer_
end

--- 获取房间码输入
function Client.GetRoomCodeInput()
    return roomCodeInput_
end

--- 判断是否已连接到服务器
function Client.IsConnected()
    return serverConnection_ ~= nil
end

-- ============================================================================
-- Menu Actions (由 HUD 按钮调用)
-- ============================================================================

--- 快速开始
function Client.RequestQuickMatch()
    if serverConnection_ == nil then
        Client.ShowToast("尚未连接到服务器")
        return
    end
    clientState_ = "quickMatching"
    quickPlayerCount_ = 1
    quickHumanCount_ = 1
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_QUICK, true)
    print("[Client] Requesting quick match")
end

--- 取消快速匹配
function Client.CancelQuickMatch()
    if serverConnection_ then
        serverConnection_:SendRemoteEvent(EVENTS.CANCEL_QUICK, true)
    end
    clientState_ = "menu"
    print("[Client] Cancelled quick match")
end

--- 进入朋友玩子菜单
function Client.EnterFriendMenu()
    clientState_ = "friendMenu"
end

--- 从朋友菜单返回主菜单
function Client.BackToMenu()
    clientState_ = "menu"
    roomCodeInput_ = ""
end

--- 创建房间
function Client.RequestCreateRoom()
    if serverConnection_ == nil then
        Client.ShowToast("尚未连接到服务器")
        return
    end
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_CREATE, true)
    print("[Client] Requesting create room")
end

--- 进入加入房间页
function Client.EnterJoinRoom()
    clientState_ = "roomJoining"
    roomCodeInput_ = ""
end

--- 加入房间（提交房间码）
function Client.RequestJoinRoom()
    if serverConnection_ == nil then
        Client.ShowToast("尚未连接到服务器")
        return
    end
    if #roomCodeInput_ ~= Config.RoomCodeLength then
        Client.ShowToast("请输入" .. Config.RoomCodeLength .. "位房间码")
        return
    end
    local data = VariantMap()
    data["RoomCode"] = Variant(roomCodeInput_)
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_JOIN, true, data)
    print("[Client] Requesting join room: " .. roomCodeInput_)
end

--- 离开房间
function Client.RequestLeaveRoom()
    if serverConnection_ then
        serverConnection_:SendRemoteEvent(EVENTS.REQUEST_LEAVE, true)
    end
    clientState_ = "menu"
    roomCode_ = ""
    print("[Client] Requesting leave room")
end

--- 解散房间（房主）
function Client.RequestDismissRoom()
    if serverConnection_ then
        serverConnection_:SendRemoteEvent(EVENTS.REQUEST_DISMISS, true)
    end
    clientState_ = "menu"
    roomCode_ = ""
    print("[Client] Requesting dismiss room")
end

--- 添加 AI（房主）
function Client.RequestAddAI()
    if serverConnection_ then
        serverConnection_:SendRemoteEvent(EVENTS.REQUEST_ADD_AI, true)
    end
    print("[Client] Requesting add AI")
end

--- 开始游戏（房主）
function Client.RequestStartGame()
    if serverConnection_ then
        serverConnection_:SendRemoteEvent(EVENTS.REQUEST_START, true)
    end
    print("[Client] Requesting start game")
end

--- 输入房间码字符
function Client.AppendRoomCodeChar(ch)
    if #roomCodeInput_ < Config.RoomCodeLength then
        roomCodeInput_ = roomCodeInput_ .. ch
    end
end

--- 删除房间码最后一个字符
function Client.DeleteRoomCodeChar()
    if #roomCodeInput_ > 0 then
        roomCodeInput_ = string.sub(roomCodeInput_, 1, -2)
    end
end

-- ============================================================================
-- Update Loop
-- ============================================================================

---@param dt number
function Client.HandleUpdate(dt)
    -- 缓存鼠标输入（必须在 Update 阶段，渲染阶段 GetMouseButtonPress 不可靠）
    HUD.CacheInput()

    -- 发送 CLIENT_READY（连接建立后的下一帧）
    if needSendReady_ and serverConnection_ then
        needSendReady_ = false
        serverConnection_:SendRemoteEvent(EVENTS.CLIENT_READY, true)
        print("[Client] CLIENT_READY sent to server")
    end

    -- 延迟回调
    Shared.UpdateDelayed()

    -- Toast 计时
    if toastTimer_ > 0 then
        toastTimer_ = toastTimer_ - dt
        if toastTimer_ <= 0 then
            toastMessage_ = ""
        end
    end

    -- 关卡列表状态（优先于 clientState 分发）
    if GameManager.state == GameManager.STATE_LEVEL_LIST then
        if HUD.IsPersistClicked() then
            LevelManager.ExportToLog()
        end
        local action = HUD.GetLevelListAction()
        if action then
            if action.action == "play" then
                local grid = LevelManager.Load(action.filename)
                if grid then
                    MapData.SetCustomGrid(grid)
                    GameManager.StartTestPlay(action.filename)
                    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
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

    -- 关卡编辑器状态
    if GameManager.state == GameManager.STATE_EDITOR then
        LevelEditor.Update(dt)
        return
    end

    -- 试玩退出
    if GameManager.testPlayMode then
        if input:GetKeyPress(KEY_ESCAPE) or HUD.IsTestPlayExitClicked() then
            GameManager.ExitTestPlay()
            HUD.RefreshLevelList()
            return
        end
    end

    -- 根据客户端状态分发
    if clientState_ == "menu" then
        Client.HandleMenuUpdate(dt)
    elseif clientState_ == "quickMatching" then
        Client.HandleQuickMatchingUpdate(dt)
    elseif clientState_ == "friendMenu" then
        Client.HandleFriendMenuUpdate(dt)
    elseif clientState_ == "roomWaiting" then
        Client.HandleRoomWaitingUpdate(dt)
    elseif clientState_ == "roomJoining" then
        Client.HandleRoomJoiningUpdate(dt)
    elseif clientState_ == "playing" then
        Client.HandlePlayingUpdate(dt)
    end
end

function Client.HandleMenuUpdate(dt)
    -- 由 HUD 绘制菜单按钮，检测点击在 HUD 中完成
    -- 这里处理 HUD 返回的菜单按钮结果
    local btn = HUD.GetMenuButtonClicked()
    if btn == "quickStart" then
        Client.RequestQuickMatch()
    elseif btn == "friendPlay" then
        Client.EnterFriendMenu()
    elseif btn == "editor" then
        HUD.RefreshLevelList()
        GameManager.EnterLevelList()
    end
end

function Client.HandleQuickMatchingUpdate(dt)
    if input:GetKeyPress(KEY_ESCAPE) then
        Client.CancelQuickMatch()
    end
end

function Client.HandleFriendMenuUpdate(dt)
    if input:GetKeyPress(KEY_ESCAPE) then
        Client.BackToMenu()
    end
    -- HUD 按钮由 HUD 处理
end

function Client.HandleRoomWaitingUpdate(dt)
    if input:GetKeyPress(KEY_ESCAPE) then
        if roomIsHost_ then
            Client.RequestDismissRoom()
        else
            Client.RequestLeaveRoom()
        end
    end
end

function Client.HandleRoomJoiningUpdate(dt)
    if input:GetKeyPress(KEY_ESCAPE) then
        Client.EnterFriendMenu()
        return
    end

    -- 数字键输入房间码
    for digit = 0, 9 do
        if input:GetKeyPress(KEY_0 + digit) then
            Client.AppendRoomCodeChar(tostring(digit))
        end
        -- 小键盘
        if input:GetKeyPress(KEY_KP_0 + digit) then
            Client.AppendRoomCodeChar(tostring(digit))
        end
    end
    if input:GetKeyPress(KEY_BACKSPACE) then
        Client.DeleteRoomCodeChar()
    end
    if input:GetKeyPress(KEY_RETURN) or input:GetKeyPress(KEY_KP_ENTER) then
        Client.RequestJoinRoom()
    end
end

function Client.HandlePlayingUpdate(dt)
    -- 收集输入并发给服务端
    Client.CollectInputAdvanced()

    -- 客户端不驱动物理/AI/GameManager 的核心逻辑
    -- 但仍需更新视觉效果（squash & stretch 等由服务端位置同步驱动）
    -- GameManager.Update 由服务端状态同步驱动

    -- 更新地图（视觉效果）
    Map.Update(dt)

    -- 更新玩家视觉（基于复制的物理状态）
    Player.UpdateAll(dt)

    -- 更新道具视觉
    Pickup.Update(dt)
    RandomPickup.Update(dt)
end

---@param dt number
function Client.HandlePostUpdate(dt)
    if clientState_ == "playing" then
        local positions = Player.GetAlivePositions()
        local humanPos = Player.GetHumanPosition()
        Camera.Update(dt, positions, humanPos)
    end

    if debugDraw_ then
        local pw = scene_:GetComponent("PhysicsWorld")
        if pw then pw:DrawDebugGeometry(true) end
    end
end

-- ============================================================================
-- Expose Client module for HUD to access (global)
-- ============================================================================

-- 注册为全局变量，让 HUD 可以访问客户端状态和操作
_G.ClientModule = Client

return Client

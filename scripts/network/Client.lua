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
local BGM    = require("BGM")
local RandomPickup = require("RandomPickup")
local LevelManager = require("LevelManager")
local LevelEditor  = require("LevelEditor")

local EVENTS = Shared.EVENTS
local CTRL   = Shared.CTRL

local Client = {}

-- ============================================================================
-- Network Event Log (可视化调试，在 HUD Debug Overlay 中显示)
-- ============================================================================

local NET_LOG_MAX = 20  -- 最多保留最近 20 条日志
local netLog_ = {}      -- { { time=os.clock(), msg="...", color={r,g,b} }, ... }

--- 记录网络事件日志
local function NetLog(msg, r, g, b)
    table.insert(netLog_, { time = os.clock(), msg = msg, r = r or 200, g = g or 200, b = b or 200 })
    if #netLog_ > NET_LOG_MAX then
        table.remove(netLog_, 1)
    end
    print("[NetLog] " .. msg)
end

--- 外部访问：获取网络日志（供 HUD 显示）
function Client.GetNetLog()
    return netLog_
end

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

    NetLog("CONN: ServerConnection ready, scene assigned", 100, 255, 100)
    print("[Client] Server connection established, scene assigned, will send CLIENT_READY next frame")
end

-- ============================================================================
-- Entry
-- ============================================================================

function Client.Start()
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " (Client) ===")

    -- 将网络帧率提升到 60Hz，与渲染帧率对齐，消除输入延迟与卡顿
    network:SetUpdateFps(60)

    -- 创建场景
    Client.CreateScene()

    -- 初始化子系统（客户端跳过地图物理——无动态刚体，节省内存避免 WASM OOM）
    Map.SetSkipPhysics(true)
    Map.Init(scene_)
    Player.SetNetworkMode("client")
    Player.Init(scene_, Map)
    Pickup.SetNetworkMode("client")
    Pickup.Init(scene_, Player)
    AIController.Init(Player, Map)
    SFX.Init(scene_)
    BGM.Init(scene_)
    BGM.PlayMenu()  -- 启动后即在主菜单，播放菜单 BGM
    -- 客户端不传 RandomPickup：道具节点由服务端创建并复制到客户端
    -- 传 nil 可防止 StartRound() 中 RandomPickup.Reset() 在客户端创建重复的本地道具节点
    GameManager.Init(Player, Map, Pickup, AIController, nil, Camera)
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
    SubscribeToEvent(EVENTS.EXPLODE_SYNC, "HandleExplodeSync")
    SubscribeToEvent(EVENTS.PLAYER_DEATH, "HandlePlayerDeath")
    SubscribeToEvent(EVENTS.PICKUP_COLLECTED, "HandlePickupCollected")

    -- 监听场景节点新增（用于给服务端复制过来的 Pickup_xxx / Player_N 节点补挂 LOCAL 视觉子节点）
    SubscribeToEvent(scene_, "NodeAdded", "HandleSceneNodeAdded")

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
        NetLog("INIT: Connection already available at start", 100, 255, 100)
        print("[Client] Connection already available at start")
    else
        NetLog("INIT: No connection yet, waiting...", 255, 200, 100)
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
    scene_:CreateComponent("DebugRenderer", LOCAL)

    local physicsWorld = scene_:CreateComponent("PhysicsWorld")
    physicsWorld:SetGravity(Vector3(0, -28.0, 0))

    -- 光照：加载 LightGroup/Daytime.xml（含 IBL 环境贴图）
    -- 关键：客户端所有节点必须 LOCAL！REPLICATED 节点会被服务端场景复制删除
    -- 使用 InstantiateXML + LOCAL 模式，确保所有子节点和组件都是 LOCAL
    local lightGroupLoaded = false
    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Daytime.xml")
    if lightGroupFile then
        local lightGroup = scene_:InstantiateXML(lightGroupFile:GetRoot(),
            Vector3.ZERO, Quaternion.IDENTITY, LOCAL)
        if lightGroup then
            lightGroup.name = "LightGroup"
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
                lightGroupLoaded = true
                print("[Client] LightGroup/Daytime.xml loaded with LOCAL mode (IBL active)")
            end
        end
    end

    if not lightGroupLoaded then
        Client.CreateFallbackLighting()
        print("[Client] LightGroup not available, using fallback lighting")
    end

    print("[Client] Scene created")
end

function Client.CreateFallbackLighting()
    -- 客户端所有节点/组件必须 LOCAL，否则会被服务端场景复制删除
    local zoneNode = scene_:CreateChild("Zone", LOCAL)
    local zone = zoneNode:CreateComponent("Zone", LOCAL)
    zone.boundingBox = BoundingBox(-200.0, 200.0)
    zone.ambientColor = Color(0.40, 0.35, 0.30)
    zone.fogColor = Color(0.95, 0.82, 0.68)
    zone.fogStart = 80.0
    zone.fogEnd = 150.0

    local lightNode = scene_:CreateChild("DirectionalLight", LOCAL)
    lightNode.direction = Vector3(0.5, -1.0, 0.3)
    local light = lightNode:CreateComponent("Light", LOCAL)
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
    -- 客户端所有节点必须 LOCAL，否则会被服务端场景复制删除
    local bgNode = scene_:CreateChild("BackgroundGradient", LOCAL)
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
-- Connection Events
-- ============================================================================

function HandleServerConnected(eventType, eventData)
    NetLog("EVENT: ServerConnected fired", 100, 255, 100)
    OnServerConnectionReady()
    print("[Client] Connected to server (ServerConnected)")
end

--- 后台匹配模式：匹配成功、服务器脚本已加载后触发
function HandleServerReady(eventType, eventData)
    NetLog("EVENT: ServerReady fired", 100, 255, 100)
    OnServerConnectionReady()
    print("[Client] Server ready (background match completed)")
end

function HandleServerDisconnected(eventType, eventData)
    NetLog("EVENT: ServerDisconnected!", 255, 100, 100)
    serverConnection_ = nil
    mySlot_ = 0
    clientState_ = "menu"
    Client.ShowToast("与服务器断开连接")
    print("[Client] Disconnected from server")
end

function HandleConnectFailed(eventType, eventData)
    NetLog("EVENT: ConnectFailed!", 255, 100, 100)
    serverConnection_ = nil
    clientState_ = "menu"
    Client.ShowToast("连接服务器失败")
    print("[Client] Connection failed")
end

-- ============================================================================
-- Remote Event Handlers (Server → Client)
-- ============================================================================

function HandleAssignRole(eventType, eventData)
    NetLog("RECV: ASSIGN_ROLE", 100, 200, 255)
    mySlot_ = eventData["Slot"]:GetInt()
    local mapW = eventData["MapWidth"]:GetInt()
    local mapH = eventData["MapHeight"]:GetInt()
    local levelFile = eventData["LevelFile"]:GetString()

    NetLog("  slot=" .. mySlot_ .. " map=" .. mapW .. "x" .. mapH .. " level=" .. levelFile, 100, 200, 255)
    print("[Client] Assigned slot: " .. mySlot_ .. " map: " .. mapW .. "x" .. mapH .. " level: " .. levelFile)

    -- 更新 MapData 尺寸
    MapData.Width = mapW
    MapData.Height = mapH

    -- 加载与服务端相同的关卡数据（关键！确保双方地图一致）
    if levelFile ~= "" then
        local grid = LevelManager.Load(levelFile)
        if grid then
            MapData.SetCustomGrid(grid)
            print("[Client] Loaded level: " .. levelFile)
        else
            print("[Client] WARNING: Failed to load level " .. levelFile .. ", using default")
            MapData.ClearCustomGrid()
        end
    else
        MapData.ClearCustomGrid()
    end

    -- 注意：不要在这里调用 Map.Build()！
    -- GameManager.StartMatch() → StartRound() → Map.Reset() 会调用 Map.Build()

    -- 从场景中查找已复制的玩家节点并创建 Player 数据
    -- 关键：客户端必须传 skipVisuals=true，让 AttachVisuals 单独以 LOCAL 模式创建视觉子节点
    -- 否则 visual 子节点直接创建在 REPLICATED 父节点下，会与服务端同步冲突导致丢失
    Player.list = {}
    for i = 1, Config.NumPlayers do
        local nodeName = "Player_" .. i
        local existingNode = scene_:GetChild(nodeName, true)
        if existingNode then
            local p = Player.Create(i, (i == mySlot_), {
                existingNode = existingNode,
                skipVisuals = true,
            })
            Player.AttachVisuals(p)
            if i ~= mySlot_ then
                p.isHuman = false
            end
        else
            -- 节点尚未复制到位（快速匹配中常见：ASSIGN_ROLE 早于 REPLICATED 节点同步到达）
            -- 关键：不要创建本地占位节点，也不要挂 visuals
            -- 否则 visualNode 被设置后 HandleSceneNodeAdded 永远不会替换 node，
            -- 导致 REPLICATED 节点无视觉 + LOCAL 占位节点位置不同步
            local p = Player.Create(i, (i == mySlot_), { nodeless = true })
            if i ~= mySlot_ then
                p.isHuman = false
            end
            print("[Client] Player " .. nodeName .. " node not yet replicated, created nodeless placeholder (waiting for NodeAdded)")
        end
    end

    -- 注意：不要在这里调用 Pickup.Reset() / RandomPickup.Reset()！
    -- StartRound() 内部已包含这些调用

    -- 设置相机
    Camera.SetFixedForMap(mapW, mapH, 2)

    -- 进入游戏状态
    clientState_ = "playing"
    -- StartMatch 内部会调用 StartRound → Map.Build + Pickup.Reset + RandomPickup.Reset
    GameManager.StartMatch()

    print("[Client] Game started, I am player " .. mySlot_)
end

--- 场景节点新增事件：为服务端复制过来的 Pickup/Player 节点补挂 LOCAL 视觉子节点
--- 防御：仅处理 scene 直接子节点；避免在 AttachVisuals 创建子节点时递归触发
local nodeAddedReentry_ = false
function HandleSceneNodeAdded(eventType, eventData)
    if nodeAddedReentry_ then return end
    local node = eventData["Node"]:GetPtr("Node")
    if not node then return end
    -- 关键防御 1：仅处理 scene 直接子节点（顶层 Player_N / Pickup_xxx）
    -- 否则任何 LOCAL 子节点（Visual/Outline/Eye 等）都会触发本回调
    if node.parent ~= scene_ then return end
    local name = node.name
    if not name then return end
    if name == "Pickup_small" or name == "Pickup_large" then
        nodeAddedReentry_ = true
        Pickup.AttachClientVisualsForNode(node)
        nodeAddedReentry_ = false
    elseif name:sub(1, 7) == "Player_" then
        local idx = tonumber(name:sub(8))
        if idx and Player.list[idx] and not Player.list[idx].visualNode then
            nodeAddedReentry_ = true
            Player.list[idx].node = node
            Player.AttachVisuals(Player.list[idx])
            nodeAddedReentry_ = false
        end
    end
end

--- 兜底扫描：每帧扫描 scene 中的 REPLICATED Pickup/Player 节点（防 NodeAdded 未触发）
local lastScanTime_ = 0
function ScanReplicatedNodes()
    if not scene_ then return end
    local children = scene_:GetChildren(false)  -- 仅直接子节点
    for i = 1, #children do
        local node = children[i]
        local name = node.name
        if name == "Pickup_small" or name == "Pickup_large" then
            if not node:GetChild("Visual", false) then
                Pickup.AttachClientVisualsForNode(node)
            end
        elseif name and name:sub(1, 7) == "Player_" then
            local idx = tonumber(name:sub(8))
            if idx and Player.list[idx] and not Player.list[idx].visualNode then
                Player.list[idx].node = node
                Player.AttachVisuals(Player.list[idx])
            end
        end
    end
end

function HandleRoomCreated(eventType, eventData)
    NetLog("RECV: ROOM_CREATED", 100, 255, 100)
    roomCode_ = eventData["RoomCode"]:GetString()
    roomIsHost_ = true
    clientState_ = "roomWaiting"
    NetLog("  roomCode=" .. roomCode_ .. " -> roomWaiting", 100, 255, 100)
    print("[Client] Room created: " .. roomCode_)
end

function HandleRoomJoined(eventType, eventData)
    NetLog("RECV: ROOM_JOINED", 100, 255, 100)
    roomCode_ = eventData["RoomCode"]:GetString()
    roomIsHost_ = false
    clientState_ = "roomWaiting"
    print("[Client] Joined room: " .. roomCode_)
end

function HandleRoomUpdate(eventType, eventData)
    NetLog("RECV: ROOM_UPDATE", 100, 200, 255)
    roomCode_ = eventData["RoomCode"]:GetString()
    roomPlayerCount_ = eventData["PlayerCount"]:GetInt()
    roomAICount_ = eventData["AICount"]:GetInt()
    roomTotal_ = eventData["Total"]:GetInt()
    roomIsHost_ = eventData["IsHost"]:GetBool()
    NetLog("  room=" .. roomCode_ .. " p=" .. roomPlayerCount_ .. " ai=" .. roomAICount_, 100, 200, 255)
    print("[Client] Room update: " .. roomPlayerCount_ .. " players + " .. roomAICount_ .. " AI = " .. roomTotal_)
end

function HandleRoomDismissed(eventType, eventData)
    NetLog("RECV: ROOM_DISMISSED", 255, 200, 100)
    clientState_ = "menu"
    roomCode_ = ""
    Client.ShowToast("房间已解散")
    print("[Client] Room dismissed")
end

function HandleGameStarting(eventType, eventData)
    NetLog("RECV: GAME_STARTING", 100, 255, 100)
    mySlot_ = eventData["Slot"]:GetInt()
    Client.ShowToast("游戏即将开始...")
    NetLog("  slot=" .. mySlot_, 100, 255, 100)
    print("[Client] Game starting, my slot: " .. mySlot_)
end

function HandleGameState(eventType, eventData)
    if clientState_ ~= "playing" then return end

    local serverState = eventData["State"]:GetString()
    local round = eventData["Round"]:GetInt()
    print("[Client] GAME_STATE: server=" .. serverState .. " local=" .. GameManager.state .. " round=" .. round)

    -- 同步分数 + 玩家状态（能量/生命/完赛）
    for i = 1, Config.NumPlayers do
        GameManager.scores[i] = eventData["Score" .. i]:GetInt()
        GameManager.killScores[i] = eventData["KillScore" .. i]:GetInt()
        local p = Player.list[i]
        if p then
            local eVar = eventData["Energy" .. i]
            if eVar then p.energy = eVar:GetFloat() end
            local aVar = eventData["Alive" .. i]
            if aVar then p.alive = (aVar:GetInt() == 1) end
            local fVar = eventData["Finished" .. i]
            if fVar then p.finished = (fVar:GetInt() == 1) end
            local cVar = eventData["Charging" .. i]
            if cVar then p.charging = (cVar:GetInt() == 1) end
            local cpVar = eventData["ChargeProg" .. i]
            if cpVar then p.chargeProgress = cpVar:GetFloat() end
        end
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
        -- 新回合开始：服务端进入 INTRO，客户端也需要重置地图/玩家/道具
        if serverState == GameManager.STATE_INTRO then
            -- 调用 StartRound 重置所有子系统 + 初始化 intro 动画状态
            -- （introPhase_、introTextAlpha_ 等局部变量必须通过 StartRound 重置）
            -- StartRound 内部会 SetState(INTRO)，round 会被 +1（随后被服务端值覆盖）
            GameManager.StartRound()
            -- StartRound 已经设置了 Camera.SetFixedForMap，不需要额外处理
        else
            GameManager.SetState(serverState)
        end
    end

    -- 用服务端权威值覆盖本地计时器（修正累积误差）
    GameManager.stateTimer = eventData["CountdownTimer"]:GetFloat()
    GameManager.roundTimer = eventData["RoundTimer"]:GetFloat()
    -- 用服务端权威值覆盖 round（StartRound 可能多加了 1）
    GameManager.round = round

    -- 比赛结束 → 回到菜单
    if serverState == GameManager.STATE_MENU then
        clientState_ = "menu"
        mySlot_ = 0
        Player.list = {}
        Map.Clear()
    end
end

function HandleJoinFailed(eventType, eventData)
    NetLog("RECV: JOIN_FAILED", 255, 100, 100)
    local reason = eventData["Reason"]:GetString()
    NetLog("  reason=" .. reason, 255, 100, 100)
    Client.ShowToast(reason)
    print("[Client] Join failed: " .. reason)
end

function HandleMatchFound(eventType, eventData)
    NetLog("RECV: MATCH_FOUND", 100, 255, 100)
    mySlot_ = eventData["Slot"]:GetInt()
    NetLog("  slot=" .. mySlot_, 100, 255, 100)
    Client.ShowToast("匹配成功！")
    print("[Client] Match found, slot: " .. mySlot_)
end

function HandleQuickUpdate(eventType, eventData)
    NetLog("RECV: QUICK_UPDATE", 100, 200, 255)
    quickPlayerCount_ = eventData["PlayerCount"]:GetInt()
    quickHumanCount_ = eventData["HumanCount"]:GetInt()
    NetLog("  total=" .. quickPlayerCount_ .. " human=" .. quickHumanCount_, 100, 200, 255)
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

function HandleExplodeSync(eventType, eventData)
    if clientState_ ~= "playing" then return end
    local playerIndex = eventData["PlayerIndex"]:GetInt()
    local centerGX = eventData["CenterGX"]:GetFloat()
    local centerGY = eventData["CenterGY"]:GetFloat()
    local radius = eventData["Radius"]:GetFloat()

    Player.HandleRemoteExplode(playerIndex, centerGX, centerGY, radius)
end

function HandlePlayerDeath(eventType, eventData)
    if clientState_ ~= "playing" then return end
    local playerIndex = eventData["PlayerIndex"]:GetInt()
    local reason = eventData["Reason"]:GetString()
    local killerIndex = eventData["KillerIndex"]:GetInt()

    Player.ClientDeath(playerIndex, reason, killerIndex)
end

function HandlePickupCollected(eventType, eventData)
    local nodeId = eventData["NodeID"]:GetInt()
    if nodeId == 0 then return end
    Pickup.RemoveByNodeID(nodeId)
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
-- 脉冲按钮 latch：按下后保持若干帧，确保通过网络节流后仍被服务端读取
-- SetPulseButtonMask 会保证服务端侧只消费一次，所以多帧重复发送是安全的
local jumpLatchFrames_ = 0
local dashLatchFrames_ = 0
local explodeLatchFrames_ = 0
-- 网络帧率已对齐 60Hz，仅需 2 帧冗余以应对偶发抖动
local PULSE_LATCH_FRAMES = 2

-- 网络发送频率统计（每秒采样一次）
local netSendCount_ = 0
local netSendLastSample_ = -1

function Client.CollectInputAdvanced()
    if serverConnection_ == nil then return end
    if mySlot_ == 0 then return end
    if clientState_ ~= "playing" then return end
    if not GameManager.CanPlayersMove() then
        serverConnection_.controls.buttons = 0
        jumpLatchFrames_ = 0
        dashLatchFrames_ = 0
        explodeLatchFrames_ = 0
        return
    end

    local buttons = 0

    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        buttons = buttons | CTRL.LEFT
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        buttons = buttons | CTRL.RIGHT
    end

    -- 跳跃：按下时启动 latch，持续若干帧
    if input:GetKeyPress(KEY_SPACE) then
        jumpLatchFrames_ = PULSE_LATCH_FRAMES
    end
    if jumpLatchFrames_ > 0 then
        buttons = buttons | CTRL.JUMP
        jumpLatchFrames_ = jumpLatchFrames_ - 1
    end

    -- 闪避
    if input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
        dashLatchFrames_ = PULSE_LATCH_FRAMES
    end
    if dashLatchFrames_ > 0 then
        buttons = buttons | CTRL.DASH
        dashLatchFrames_ = dashLatchFrames_ - 1
    end

    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    if leftDown then
        buttons = buttons | CTRL.CHARGE
    end
    if wasLeftDown_ and not leftDown then
        explodeLatchFrames_ = PULSE_LATCH_FRAMES
    end
    if explodeLatchFrames_ > 0 then
        buttons = buttons | CTRL.EXPLODE_RELEASE
        explodeLatchFrames_ = explodeLatchFrames_ - 1
    end
    wasLeftDown_ = leftDown

    serverConnection_.controls.buttons = buttons

    -- 网络发送频率统计：每次 controls 写入都计为一次"潜在网络帧"
    -- 使用引擎 wall-clock 时间（os.clock 在 WASM 下不可靠）
    netSendCount_ = netSendCount_ + 1
    local now = time:GetElapsedTime()
    if netSendLastSample_ < 0 then
        netSendLastSample_ = now
    end
    local elapsed = now - netSendLastSample_
    if elapsed >= 1.0 then
        _G.NetSendFps = netSendCount_ / elapsed
        netSendCount_ = 0
        netSendLastSample_ = now
    end
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
        NetLog("SEND FAIL: REQUEST_QUICK - no connection!", 255, 100, 100)
        Client.ShowToast("尚未连接到服务器")
        return
    end
    clientState_ = "quickMatching"
    quickPlayerCount_ = 1
    quickHumanCount_ = 1
    NetLog("SEND: REQUEST_QUICK", 255, 255, 100)
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_QUICK, true)
    print("[Client] Requesting quick match")
end

--- 取消快速匹配
function Client.CancelQuickMatch()
    if serverConnection_ then
        NetLog("SEND: CANCEL_QUICK", 255, 255, 100)
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
        NetLog("SEND FAIL: REQUEST_CREATE - no connection!", 255, 100, 100)
        Client.ShowToast("尚未连接到服务器")
        return
    end
    -- 防止重复发送（按钮在渲染帧每帧触发）
    if clientState_ == "creatingRoom" or clientState_ == "roomWaiting" then
        return
    end
    clientState_ = "creatingRoom"
    NetLog("SEND: REQUEST_CREATE", 255, 255, 100)
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
        NetLog("SEND FAIL: REQUEST_JOIN - no connection!", 255, 100, 100)
        Client.ShowToast("尚未连接到服务器")
        return
    end
    if #roomCodeInput_ ~= Config.RoomCodeLength then
        Client.ShowToast("请输入" .. Config.RoomCodeLength .. "位房间码")
        return
    end
    local data = VariantMap()
    data["RoomCode"] = Variant(roomCodeInput_)
    NetLog("SEND: REQUEST_JOIN code=" .. roomCodeInput_, 255, 255, 100)
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_JOIN, true, data)
    print("[Client] Requesting join room: " .. roomCodeInput_)
end

--- 离开房间
function Client.RequestLeaveRoom()
    if serverConnection_ then
        NetLog("SEND: REQUEST_LEAVE", 255, 255, 100)
        serverConnection_:SendRemoteEvent(EVENTS.REQUEST_LEAVE, true)
    end
    clientState_ = "menu"
    roomCode_ = ""
    print("[Client] Requesting leave room")
end

--- 解散房间（房主）
function Client.RequestDismissRoom()
    if serverConnection_ then
        NetLog("SEND: REQUEST_DISMISS", 255, 255, 100)
        serverConnection_:SendRemoteEvent(EVENTS.REQUEST_DISMISS, true)
    end
    clientState_ = "menu"
    roomCode_ = ""
    print("[Client] Requesting dismiss room")
end

--- 添加 AI（房主）
function Client.RequestAddAI()
    if serverConnection_ then
        NetLog("SEND: REQUEST_ADD_AI", 255, 255, 100)
        serverConnection_:SendRemoteEvent(EVENTS.REQUEST_ADD_AI, true)
    end
    print("[Client] Requesting add AI")
end

--- 开始游戏（房主）
function Client.RequestStartGame()
    if serverConnection_ then
        NetLog("SEND: REQUEST_START", 255, 255, 100)
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

-- BGM 状态联动：监听 clientState_ 与 GameManager.state 变化
local prevClientState_ = nil
local prevGameState_ = nil

---@param dt number
function Client.HandleUpdate(dt)
    -- 缓存鼠标输入（必须在 Update 阶段，渲染阶段 GetMouseButtonPress 不可靠）
    HUD.CacheInput()

    -- BGM 状态分发（仅在状态变化时触发）
    if clientState_ ~= prevClientState_ or GameManager.state ~= prevGameState_ then
        if GameManager.state == GameManager.STATE_EDITOR
            or GameManager.state == GameManager.STATE_LEVEL_LIST then
            BGM.Stop()
        elseif clientState_ == "playing" then
            -- 对局曲由 GameManager.SetState(STATE_INTRO) 内部联动触发，此处不重复
        else
            -- 所有非 playing/editor 客户端状态都使用菜单 BGM
            BGM.PlayMenu()
        end
        prevClientState_ = clientState_
        prevGameState_ = GameManager.state
    end

    -- 兜底扫描：补挂 REPLICATED 节点视觉（防 NodeAdded 事件未触发）
    -- 降频到 1 秒一次，减少 GetChildren 开销
    lastScanTime_ = lastScanTime_ + dt
    if lastScanTime_ >= 1.0 then
        lastScanTime_ = 0
        ScanReplicatedNodes()
    end

    -- 发送 CLIENT_READY（连接建立后的下一帧）
    if needSendReady_ and serverConnection_ then
        needSendReady_ = false
        NetLog("SEND: CLIENT_READY", 255, 255, 100)
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

    -- ====================================================================
    -- 客户端本地驱动 GameManager 状态动画/计时器
    -- 核心逻辑（得分、终点检测、回合结束判定）由服务端权威运行
    -- 客户端只驱动：Intro 相机动画、Countdown 倒计时音效、Racing 计时器递减
    -- ====================================================================
    local gmState = GameManager.state
    if gmState == GameManager.STATE_INTRO then
        -- 开场镜头动画（4个子阶段的相机平移+缩放）必须在客户端每帧驱动
        GameManager.UpdateIntro(dt)
    elseif gmState == GameManager.STATE_COUNTDOWN then
        -- 倒计时（3-2-1-GO 音效 + 计时器递减）在客户端本地驱动
        GameManager.UpdateCountdown(dt)
    elseif gmState == GameManager.STATE_RACING then
        -- 比赛中：本地递减回合计时器（服务端每秒同步一次，中间帧本地倒数保持平滑）
        GameManager.roundTimer = math.max(0, GameManager.roundTimer - dt)
    elseif gmState == GameManager.STATE_ROUND_END
        or gmState == GameManager.STATE_SCORE
        or gmState == GameManager.STATE_MATCH_END then
        -- 回合结束/积分/比赛结束：本地递减状态计时器（HUD 显示用）
        -- 状态转换由服务端 GAME_STATE 事件驱动，客户端不自行转换
        GameManager.stateTimer = GameManager.stateTimer - dt
    end

    -- 更新地图（方块动画、LOCAL MapRoot 视觉效果）
    Map.Update(dt)

    -- 更新玩家视觉（仅动画、特效，不做物理/移动/死亡检测）
    Player.UpdateAllClient(dt)

    -- 更新道具视觉（仅旋转+浮动动画，不做碰撞/收集）
    Pickup.UpdateVisuals(dt)

    -- 注意：不调用 RandomPickup.Update(dt)
    -- 道具生成由服务端控制，客户端通过场景复制接收道具节点
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

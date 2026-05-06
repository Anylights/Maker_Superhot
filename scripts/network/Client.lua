-- ============================================================================
-- Client.lua - 超级红温！ 联机客户端（持久世界模式）
-- 职责：输入采集 → controls.buttons、会话事件处理、视觉/HUD
-- 流程：连接 → CLIENT_READY → SESSION_START → Playing → SESSION_END → Results → REQUEST_RESTART → ...
-- ============================================================================

require "LuaScripts/Utilities/Sample"

local Config = require("Config")
local Shared = require("network.Shared")
local Camera = require("Camera")
local Map    = require("Map")
local MapData = require("MapData")
local Background = require("Background")
local Player = require("Player")
local Pickup = require("Pickup")
local AIController = require("AIController")
local GameManager = require("GameManager")
local HUD    = require("HUD")
local SFX    = require("SFX")
local BGM    = require("BGM")
local RandomPickup = require("RandomPickup")
local FXDiag = require("FXDiag")

local EVENTS = Shared.EVENTS
local CTRL   = Shared.CTRL

local Client = {}

-- ============================================================================
-- Network Event Log
-- ============================================================================

local NET_LOG_MAX = 20
local netLog_ = {}

local function NetLog(msg, r, g, b)
    table.insert(netLog_, { time = os.clock(), msg = msg, r = r or 200, g = g or 200, b = b or 200 })
    if #netLog_ > NET_LOG_MAX then
        table.remove(netLog_, 1)
    end
    print("[NetLog] " .. msg)
end

function Client.GetNetLog()
    return netLog_
end

-- ============================================================================
-- Client-side State
-- ============================================================================

-- 客户端阶段（简化为 3 个：连接中 / 游戏中 / 结算）
local clientState_ = "connecting"
-- "connecting"  等待连接/等待 SESSION_START
-- "playing"     会话进行中
-- "results"     会话结束，展示结算

-- 玩家本机被分配的 slot
local mySlot_ = 0

-- 地图是否已初始化
local mapReady_ = false
local mapSeed_ = 0

-- 会话分数（从服务端同步）
local sessionScores_ = {
    heightScore = 0,
    killScore = 0,
    pickupScore = 0,
    totalScore = 0,
    timer = 0,
}

-- 结算分数（SESSION_END 时保存）
local finalScores_ = {
    heightScore = 0,
    killScore = 0,
    pickupScore = 0,
    totalScore = 0,
}

-- 排行榜数据（从服务端同步）
local leaderboard_ = {}

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
-- Connection Helper
-- ============================================================================

local needSendReady_ = false

local function OnServerConnectionReady()
    if serverConnection_ ~= nil then return end

    local conn = network:GetServerConnection()
    if conn == nil then
        print("[Client] WARNING: server connection is nil")
        return
    end

    serverConnection_ = conn
    serverConnection_.scene = scene_
    needSendReady_ = true

    NetLog("CONN: ServerConnection ready, scene assigned", 100, 255, 100)
    print("[Client] Server connection established, will send CLIENT_READY next frame")
end

-- ============================================================================
-- Entry
-- ============================================================================

function Client.Start()
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " (Client - Persistent World) ===")

    -- 客户端网络发送频率：60Hz 确保输入信号及时送达
    network:SetUpdateFps(60)

    -- 创建场景
    Client.CreateScene()

    -- 初始化子系统
    Map.SetSkipPhysics(true)
    Map.Init(scene_)
    Player.SetNetworkMode("client")
    Player.Init(scene_, Map)
    Pickup.SetNetworkMode("client")
    Pickup.Init(scene_, Player)
    AIController.Init(Player, Map)
    SFX.Init(scene_)
    BGM.Init(scene_)
    BGM.PlayMenu()
    GameManager.Init(Player, Map, Pickup, AIController, nil, Camera)
    Camera.Init(scene_)

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
    renderer.defaultZone.fogColor = Color(0.95, 0.82, 0.68)

    -- 创建背景
    Background.Create(scene_, true)

    -- 初始化 HUD
    HUD.Init(Player, GameManager, Map)

    -- 初始化随机道具
    RandomPickup.Init(Map, Pickup, Player)

    -- 设置初始相机（大世界默认视角）
    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)

    -- 监听连接事件
    SubscribeToEvent("ServerConnected", "HandleServerConnected")
    SubscribeToEvent("ServerDisconnected", "HandleServerDisconnected")
    SubscribeToEvent("ConnectFailed", "HandleConnectFailed")
    SubscribeToEvent("ServerReady", "HandleServerReady")

    -- 监听服务端远程事件（仅会话相关）
    SubscribeToEvent(EVENTS.SESSION_START, "HandleSessionStart")
    SubscribeToEvent(EVENTS.SESSION_END, "HandleSessionEnd")
    SubscribeToEvent(EVENTS.SCORE_UPDATE, "HandleScoreUpdate")
    SubscribeToEvent(EVENTS.CHECKPOINT_ACTIVATED, "HandleCheckpointActivated")
    SubscribeToEvent(EVENTS.LEADERBOARD_UPDATE, "HandleLeaderboardUpdate")
    SubscribeToEvent(EVENTS.KILL_EVENT, "HandleKillEvent")
    SubscribeToEvent(EVENTS.EXPLODE_SYNC, "HandleExplodeSync")
    SubscribeToEvent(EVENTS.PLAYER_DEATH, "HandlePlayerDeath")
    SubscribeToEvent(EVENTS.PICKUP_COLLECTED, "HandlePickupCollected")

    -- 监听场景节点新增（补挂 LOCAL 视觉子节点）
    SubscribeToEvent(scene_, "NodeAdded", "HandleSceneNodeAdded")

    -- 击杀回调（客户端由服务端远程事件驱动，此回调留空）
    GameManager.OnKill(function() end)

    -- 主动检测已有连接（persistent_world 模式下可能脚本加载前已连接）
    local existingConn = network:GetServerConnection()
    if existingConn then
        OnServerConnectionReady()
        NetLog("INIT: Connection already available at start", 100, 255, 100)
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
    scene_.smoothingConstant = 25.0
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer", LOCAL)

    local physicsWorld = scene_:CreateComponent("PhysicsWorld")
    physicsWorld:SetGravity(Vector3(0, -28.0, 0))

    -- 光照
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
            end
        end
    end

    if not lightGroupLoaded then
        Client.CreateFallbackLighting()
    end

    print("[Client] Scene created")
end

function Client.CreateFallbackLighting()
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

-- ============================================================================
-- Connection Events
-- ============================================================================

function HandleServerConnected(eventType, eventData)
    NetLog("EVENT: ServerConnected fired", 100, 255, 100)
    OnServerConnectionReady()
end

function HandleServerReady(eventType, eventData)
    NetLog("EVENT: ServerReady fired", 100, 255, 100)
    OnServerConnectionReady()
end

function HandleServerDisconnected(eventType, eventData)
    NetLog("EVENT: ServerDisconnected!", 255, 100, 100)
    serverConnection_ = nil
    mySlot_ = 0
    clientState_ = "connecting"
    mapReady_ = false
    Client.ShowToast("与服务器断开连接")
    print("[Client] Disconnected from server")
end

function HandleConnectFailed(eventType, eventData)
    NetLog("EVENT: ConnectFailed!", 255, 100, 100)
    serverConnection_ = nil
    clientState_ = "connecting"
    Client.ShowToast("连接服务器失败")
    print("[Client] Connection failed")
end

-- ============================================================================
-- Remote Event Handlers (Server → Client)
-- ============================================================================

--- 会话开始：服务端分配 slot + 地图信息
function HandleSessionStart(eventType, eventData)
    NetLog("RECV: SESSION_START", 100, 255, 100)
    mySlot_ = eventData["Slot"]:GetInt()
    mapSeed_ = eventData["MapSeed"]:GetInt()
    local mapW = eventData["MapWidth"]:GetInt()
    local mapH = eventData["MapHeight"]:GetInt()
    local sessionDuration = eventData["SessionDuration"]:GetFloat()

    NetLog("  slot=" .. mySlot_ .. " seed=" .. mapSeed_ .. " map=" .. mapW .. "x" .. mapH, 100, 255, 100)
    print("[Client] SESSION_START: slot=" .. mySlot_ .. " seed=" .. mapSeed_
        .. " map=" .. mapW .. "x" .. mapH .. " duration=" .. sessionDuration)

    -- 更新 MapData
    MapData.Width = mapW
    MapData.Height = mapH

    -- 初始化地图（仅首次或种子变化时）
    if not mapReady_ or mapSeed_ ~= GameManager.mapSeed then
        MapData.Generate(mapSeed_)
        GameManager.mapSeed = mapSeed_
        Map.Reset(mapSeed_)
        mapReady_ = true
        print("[Client] Map generated with seed=" .. mapSeed_)
    end

    -- 清理旧玩家 LOCAL 视觉子节点
    for _, p in ipairs(Player.list) do
        if p.visualNode then
            p.visualNode:Remove()
            p.visualNode = nil
        end
    end

    -- 扫描场景中已复制的玩家节点
    local sceneChildren = scene_:GetChildren(false)

    -- 构建名称→最新节点映射
    local latestPlayerNodes = {}
    for i = 1, #sceneChildren do
        local child = sceneChildren[i]
        local cname = child.name
        if cname and cname:sub(1, 7) == "Player_" then
            -- 移除残留 Visual 子节点
            local vis = child:GetChild("Visual", false)
            if vis then vis:Remove() end

            local idx = tonumber(cname:sub(8))
            if idx then
                local prev = latestPlayerNodes[idx]
                if not prev or child:GetID() > prev:GetID() then
                    latestPlayerNodes[idx] = child
                end
            end
        end
    end

    -- 重建 Player.list：本机 slot 为 human，其他为 non-human
    Player.list = {}

    -- 先处理已有的 REPLICATED 节点
    for idx, node in pairs(latestPlayerNodes) do
        local p = Player.Create(idx, (idx == mySlot_), {
            existingNode = node,
            skipVisuals = true,
        })
        Player.AttachVisuals(p)
        if idx ~= mySlot_ then
            p.isHuman = false
        end
    end

    -- 如果本机 slot 没有对应节点（尚未复制），创建 nodeless 占位
    if mySlot_ > 0 and not latestPlayerNodes[mySlot_] then
        local p = Player.Create(mySlot_, true, { nodeless = true })
        print("[Client] My slot " .. mySlot_ .. " node not yet replicated, waiting...")
    end

    -- 重置会话分数
    sessionScores_.heightScore = 0
    sessionScores_.killScore = 0
    sessionScores_.pickupScore = 0
    sessionScores_.totalScore = 0
    sessionScores_.timer = sessionDuration

    -- 设置相机
    Camera.SetFixedForMap(mapW, mapH, 2)
    Camera.ReleaseFixed()  -- 跟随玩家

    -- 设置背景
    Background.SetPaletteForRound(1)

    -- 进入游戏状态
    clientState_ = "playing"
    GameManager.SetState(GameManager.STATE_PLAYING)

    print("[Client] Session started, I am player " .. mySlot_)
end

--- 会话结束：展示结算
function HandleSessionEnd(eventType, eventData)
    NetLog("RECV: SESSION_END", 255, 200, 100)
    local slot = eventData["Slot"]:GetInt()
    local totalScore = eventData["TotalScore"]:GetInt()

    -- 保存最终分数
    finalScores_.totalScore = totalScore
    local hsVar = eventData["HeightScore"]
    if hsVar then finalScores_.heightScore = hsVar:GetInt() end
    local ksVar = eventData["KillScore"]
    if ksVar then finalScores_.killScore = ksVar:GetInt() end
    local psVar = eventData["PickupScore"]
    if psVar then finalScores_.pickupScore = psVar:GetInt() end

    -- 进入结算状态
    clientState_ = "results"
    GameManager.SetState(GameManager.STATE_RESULTS)

    print("[Client] SESSION_END: score=" .. totalScore)
end

--- 分数更新（定期从服务端同步）
function HandleScoreUpdate(eventType, eventData)
    if clientState_ ~= "playing" then return end

    sessionScores_.heightScore = eventData["HeightScore"]:GetInt()
    sessionScores_.killScore = eventData["KillScore"]:GetInt()
    sessionScores_.pickupScore = eventData["PickupScore"]:GetInt()
    sessionScores_.totalScore = eventData["TotalScore"]:GetInt()
    sessionScores_.timer = eventData["Timer"]:GetFloat()

    -- 同步本机玩家状态
    local p = Player.list[mySlot_]
    if not p then
        -- mySlot_ 可能不在 Player.list 的索引位，遍历查找
        for _, pl in ipairs(Player.list) do
            if pl.index == mySlot_ then p = pl; break end
        end
    end
    if p then
        local aVar = eventData["Alive"]
        if aVar then p.alive = (aVar:GetInt() == 1) end
        local eVar = eventData["Energy"]
        if eVar then p.energy = eVar:GetFloat() end
        local cVar = eventData["Charging"]
        if cVar then p.charging = (cVar:GetInt() == 1) end
        local cpVar = eventData["ChargeProg"]
        if cpVar then p.chargeProgress = cpVar:GetFloat() end
    end
end

--- 检查点激活确认
function HandleCheckpointActivated(eventType, eventData)
    local checkpointY = eventData["CheckpointY"]:GetInt()
    NetLog("RECV: CHECKPOINT Y=" .. checkpointY, 100, 255, 200)
    -- 播放检查点激活音效
    SFX.PlayCheckpoint()
    print("[Client] Checkpoint activated at Y=" .. checkpointY)
end

--- 排行榜更新
function HandleLeaderboardUpdate(eventType, eventData)
    local count = eventData["Count"]:GetInt()
    leaderboard_ = {}
    for i = 1, count do
        table.insert(leaderboard_, {
            index = eventData["Index" .. i]:GetInt(),
            score = eventData["Score" .. i]:GetInt(),
            isHuman = (eventData["IsHuman" .. i]:GetInt() == 1),
        })
    end
    GameManager.SetLeaderboard(leaderboard_)
end

--- 击杀事件
function HandleKillEvent(eventType, eventData)
    local killerIdx = eventData["Killer"]:GetInt()
    local victimIdx = eventData["Victim"]:GetInt()
    local multiKill = eventData["MultiKill"]:GetInt()
    local killStreak = eventData["KillStreak"]:GetInt()

    table.insert(GameManager.killEvents, {
        killerIndex = killerIdx,
        victimIndex = victimIdx,
        multiKillCount = multiKill,
        killStreak = killStreak,
    })
end

--- 爆炸同步
function HandleExplodeSync(eventType, eventData)
    if clientState_ ~= "playing" then return end
    local playerIndex = eventData["PlayerIndex"]:GetInt()
    local centerGX = eventData["CenterGX"]:GetFloat()
    local centerGY = eventData["CenterGY"]:GetFloat()
    local radius = eventData["Radius"]:GetFloat()
    Player.HandleRemoteExplode(playerIndex, centerGX, centerGY, radius)
end

--- 玩家死亡同步
function HandlePlayerDeath(eventType, eventData)
    if clientState_ ~= "playing" then return end
    local playerIndex = eventData["PlayerIndex"]:GetInt()
    local reason = eventData["Reason"]:GetString()
    local killerIndex = eventData["KillerIndex"]:GetInt()
    Player.ClientDeath(playerIndex, reason, killerIndex)
end

--- 道具拾取同步
function HandlePickupCollected(eventType, eventData)
    local nodeId = eventData["NodeID"]:GetInt()
    if nodeId == 0 then return end
    Pickup.RemoveByNodeID(nodeId)
end

-- ============================================================================
-- Scene Node Handling (补挂 REPLICATED 节点的 LOCAL 视觉)
-- ============================================================================

local nodeAddedReentry_ = false
function HandleSceneNodeAdded(eventType, eventData)
    if nodeAddedReentry_ then return end
    local node = eventData["Node"]:GetPtr("Node")
    if not node then return end
    if node.parent ~= scene_ then return end
    local name = node.name
    if not name then return end

    if name == "Pickup_small" or name == "Pickup_large" then
        nodeAddedReentry_ = true
        Pickup.AttachClientVisualsForNode(node)
        nodeAddedReentry_ = false
    elseif name:sub(1, 7) == "Player_" then
        local idx = tonumber(name:sub(8))
        if idx then
            -- 查找对应的 Player 数据
            for _, p in ipairs(Player.list) do
                if p.index == idx and not p.visualNode then
                    nodeAddedReentry_ = true
                    p.node = node
                    Player.AttachVisuals(p)
                    nodeAddedReentry_ = false
                    break
                end
            end
        end
    end
end

--- 兜底扫描：补挂 REPLICATED 节点视觉
local lastScanTime_ = 0
function ScanReplicatedNodes()
    if not scene_ then return end
    local children = scene_:GetChildren(false)
    for i = 1, #children do
        local node = children[i]
        local name = node.name
        if name == "Pickup_small" or name == "Pickup_large" then
            if not node:GetChild("Visual", false) then
                Pickup.AttachClientVisualsForNode(node)
            end
        elseif name and name:sub(1, 7) == "Player_" then
            local idx = tonumber(name:sub(8))
            if idx then
                for _, p in ipairs(Player.list) do
                    if p.index == idx and not p.visualNode then
                        p.node = node
                        Player.AttachVisuals(p)
                        break
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- Input Collection
-- ============================================================================

local wasLeftDown_ = false
local PULSE_HOLD_FRAMES = 2
---@type table<integer, integer>
local pulseHold_ = {}

local netSendCount_ = 0
local netSendLastSample_ = -1

function Client.CollectInputAdvanced()
    if serverConnection_ == nil then return end
    if mySlot_ == 0 then return end
    if clientState_ ~= "playing" then return end

    -- 会话未激活时不发送输入
    if not GameManager.CanPlayersMove() then
        serverConnection_.controls.buttons = 0
        for bit, frames in pairs(pulseHold_) do
            if frames > 0 then pulseHold_[bit] = frames - 1
            else pulseHold_[bit] = nil end
        end
        return
    end

    -- 持续按钮
    local continuous = 0
    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        continuous = continuous | CTRL.LEFT
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        continuous = continuous | CTRL.RIGHT
    end
    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    if leftDown then
        continuous = continuous | CTRL.CHARGE
    end

    -- 脉冲按钮
    if input:GetKeyPress(KEY_SPACE) then
        pulseHold_[CTRL.JUMP] = PULSE_HOLD_FRAMES
    end
    if input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
        pulseHold_[CTRL.DASH] = PULSE_HOLD_FRAMES
    end
    if wasLeftDown_ and not leftDown then
        pulseHold_[CTRL.EXPLODE_RELEASE] = PULSE_HOLD_FRAMES
    end
    wasLeftDown_ = leftDown

    local pulse = 0
    for bit, frames in pairs(pulseHold_) do
        if frames > 0 then
            pulse = pulse | bit
            pulseHold_[bit] = frames - 1
        else
            pulseHold_[bit] = nil
        end
    end

    serverConnection_.controls.buttons = continuous | pulse

    -- 网络发送频率统计
    netSendCount_ = netSendCount_ + 1
    local now = time:GetElapsedTime()
    if netSendLastSample_ < 0 then netSendLastSample_ = now end
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

function Client.GetState()
    return clientState_
end

function Client.GetMySlot()
    return mySlot_
end

function Client.GetToast()
    return toastMessage_, toastTimer_
end

function Client.IsConnected()
    return serverConnection_ ~= nil
end

function Client.GetSessionScores()
    return sessionScores_
end

function Client.GetFinalScores()
    return finalScores_
end

function Client.GetLeaderboard()
    return leaderboard_
end

function Client.GetNetLog()
    return netLog_
end

-- ============================================================================
-- Actions (由 HUD 按钮调用)
-- ============================================================================

--- 请求重新开始（结算页面点击"再来一局"）
function Client.RequestRestart()
    if serverConnection_ == nil then
        Client.ShowToast("尚未连接到服务器")
        return
    end
    NetLog("SEND: REQUEST_RESTART", 255, 255, 100)
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_RESTART, true)
    clientState_ = "connecting"  -- 等待新的 SESSION_START
    print("[Client] Requesting restart")
end

-- ============================================================================
-- Update Loop
-- ============================================================================

---@param dt number
function Client.HandleUpdate(dt)
    -- 缓存鼠标输入
    HUD.CacheInput()

    -- 兜底扫描
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
        if toastTimer_ <= 0 then toastMessage_ = "" end
    end

    -- 根据客户端状态分发
    if clientState_ == "connecting" then
        -- 等待中，不需要特别处理
    elseif clientState_ == "playing" then
        Client.HandlePlayingUpdate(dt)
    elseif clientState_ == "results" then
        Client.HandleResultsUpdate(dt)
    end
end

function Client.HandlePlayingUpdate(dt)
    -- 收集输入并发给服务端
    Client.CollectInputAdvanced()

    -- 本地递减会话计时器（服务端定期同步修正）
    sessionScores_.timer = math.max(0, sessionScores_.timer - dt)

    -- 更新地图可见区块
    local humanPos = Player.GetHumanPosition()
    if humanPos and Map.UpdateVisibleChunk then
        Map.UpdateVisibleChunk(humanPos.y)
    end

    -- 更新地图（方块动画等）
    Map.Update(dt)

    -- 更新玩家视觉
    Player.UpdateAllClient(dt)

    -- 更新道具视觉
    Pickup.UpdateVisuals(dt)

    -- 更新背景动画（传入相机Y跟随）
    local _, camY = Camera.GetCenter()
    Background.Update(dt, camY)
end

function Client.HandleResultsUpdate(dt)
    -- 结算页面：HUD 绘制分数和按钮
    -- 按钮点击由 HUD 通过 Client.RequestRestart() 处理

    -- 继续更新背景动画
    local _, camY2 = Camera.GetCenter()
    Background.Update(dt, camY2)
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
-- Expose Client module for HUD
-- ============================================================================

_G.ClientModule = Client

return Client

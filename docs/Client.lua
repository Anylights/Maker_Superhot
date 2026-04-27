-- ============================================================================
-- Client.lua - 超级红温！ 联机客户端（精简版：仅快速匹配）
-- 状态机：MENU → MATCHING → PLAYING → MENU
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
-- State
-- ============================================================================

-- 客户端状态机（3 个）
local clientState_ = "MENU"
-- "MENU"      主菜单
-- "MATCHING"  匹配中
-- "PLAYING"   对局中

local mySlot_ = 0

-- 匹配进度
local matchPlayerCount_ = 0
local matchTimeLeft_    = 0
local matchRequired_    = Config.NumPlayers

-- Toast 提示
local toastMessage_ = ""
local toastTimer_   = 0

---@type Connection
local serverConnection_ = nil

---@type Scene
local scene_ = nil

local needSendReady_ = false
local debugDraw_ = false

-- ============================================================================
-- Connection helpers
-- ============================================================================

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
    print("[Client] Server connection ready, will send CLIENT_READY next frame")
end

-- ============================================================================
-- Entry
-- ============================================================================

function Client.Start()
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " (Client, quick-match only) ===")

    Client.CreateScene()

    Map.Init(scene_)
    Player.SetNetworkMode("client")
    Player.Init(scene_, Map)
    Pickup.Init(scene_, Player)
    AIController.Init(Player, Map)
    SFX.Init(scene_)
    GameManager.Init(Player, Map, Pickup, AIController, RandomPickup, Camera)
    Camera.Init(scene_)

    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
    renderer.defaultZone.fogColor = Color(0.95, 0.82, 0.68)

    Client.CreateBackgroundPlane()

    HUD.Init(Player, GameManager, Map)

    RandomPickup.Init(Map, Pickup)
    LevelManager.Init()
    LevelEditor.Init(HUD.GetNVGContext(), GameManager, Map)
    HUD.SetLevelEditor(LevelEditor)

    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
    GameManager.EnterMenu()

    SubscribeToEvent("ServerConnected", "HandleServerConnected")
    SubscribeToEvent("ServerDisconnected", "HandleServerDisconnected")
    SubscribeToEvent("ConnectFailed", "HandleConnectFailed")
    SubscribeToEvent("ServerReady", "HandleServerReady")

    SubscribeToEvent(EVENTS.QUICK_UPDATE, "HandleQuickUpdate")
    SubscribeToEvent(EVENTS.MATCH_FOUND, "HandleMatchFound")
    SubscribeToEvent(EVENTS.ASSIGN_ROLE, "HandleAssignRole")
    SubscribeToEvent(EVENTS.GAME_STATE, "HandleGameState")
    SubscribeToEvent(EVENTS.KILL_EVENT, "HandleKillEvent")

    GameManager.OnKill(function() end)

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
    print("[Client] ServerConnected")
end

function HandleServerReady(eventType, eventData)
    OnServerConnectionReady()
    print("[Client] ServerReady (background match)")
end

function HandleServerDisconnected(eventType, eventData)
    serverConnection_ = nil
    mySlot_ = 0
    clientState_ = "MENU"
    Player.list = {}
    Map.Clear()
    Client.ShowToast("与服务器断开连接")
    print("[Client] Disconnected")
end

function HandleConnectFailed(eventType, eventData)
    serverConnection_ = nil
    clientState_ = "MENU"
    Client.ShowToast("连接服务器失败")
    print("[Client] Connect failed")
end

-- ============================================================================
-- Remote Event Handlers
-- ============================================================================

function HandleQuickUpdate(eventType, eventData)
    matchPlayerCount_ = eventData["PlayerCount"]:GetInt()
    matchTimeLeft_    = eventData["TimeLeft"]:GetFloat()
    matchRequired_    = eventData["Required"]:GetInt()
end

function HandleMatchFound(eventType, eventData)
    mySlot_ = eventData["Slot"]:GetInt()
    Client.ShowToast("匹配成功！")
    print("[Client] Match found, slot=" .. mySlot_)
end

function HandleAssignRole(eventType, eventData)
    mySlot_ = eventData["Slot"]:GetInt()
    local mapW = eventData["MapWidth"]:GetInt()
    local mapH = eventData["MapHeight"]:GetInt()

    print("[Client] Assigned slot: " .. mySlot_ .. " map: " .. mapW .. "x" .. mapH)

    MapData.Width = mapW
    MapData.Height = mapH

    Map.Build()

    Player.list = {}
    for i = 1, Config.NumPlayers do
        local nodeName = "Player_" .. i
        local existingNode = scene_:GetChild(nodeName, true)
        if existingNode then
            local p = Player.Create(i, (i == mySlot_), { existingNode = existingNode })
            Player.AttachVisuals(p)
            if i ~= mySlot_ then p.isHuman = false end
        else
            local p = Player.Create(i, (i == mySlot_))
            Player.AttachVisuals(p)
            if i ~= mySlot_ then p.isHuman = false end
            print("[Client] Warning: node " .. nodeName .. " not found, created locally")
        end
    end

    Pickup.Reset()
    RandomPickup.Reset()

    Camera.SetFixedForMap(mapW, mapH, 2)

    local dz = scene_:GetChild("DeathZone", false)
    if dz then
        dz.position = Vector3(mapW * 0.5, Config.DeathY, 0)
        dz.scale = Vector3(mapW + 20, 2, 10)
    end

    clientState_ = "PLAYING"
    GameManager.StartMatch()

    print("[Client] Game started, I am player " .. mySlot_)
end

function HandleGameState(eventType, eventData)
    if clientState_ ~= "PLAYING" then return end

    local serverState = eventData["State"]:GetString()
    local round = eventData["Round"]:GetInt()

    for i = 1, Config.NumPlayers do
        GameManager.scores[i] = eventData["Score" .. i]:GetInt()
        GameManager.killScores[i] = eventData["KillScore" .. i]:GetInt()
    end

    local resultCount = eventData["ResultCount"]:GetInt()
    GameManager.roundResults = {}
    for i = 1, resultCount do
        table.insert(GameManager.roundResults, eventData["Result" .. i]:GetInt())
    end

    GameManager.round = round

    if serverState ~= GameManager.state then
        GameManager.SetState(serverState)
    end

    GameManager.stateTimer = eventData["CountdownTimer"]:GetFloat()
    GameManager.roundTimer = eventData["RoundTimer"]:GetFloat()

    if serverState == GameManager.STATE_MENU then
        clientState_ = "MENU"
        mySlot_ = 0
        Player.list = {}
        Map.Clear()
        GameManager.EnterMenu()
    end
end

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

-- ============================================================================
-- Input Collection
-- ============================================================================

local wasLeftDown_ = false

function Client.CollectInputAdvanced()
    if mySlot_ == 0 then return end
    if clientState_ ~= "PLAYING" then return end

    local p = Player.list[mySlot_]
    if p == nil then return end

    if not GameManager.CanPlayersMove() then
        p.inputMoveX = 0
        p.inputJump = false
        p.inputDash = false
        if serverConnection_ then
            serverConnection_.controls.buttons = 0
        end
        return
    end

    local buttons = 0
    local moveX = 0

    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        buttons = buttons | CTRL.LEFT
        moveX = moveX - 1
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        buttons = buttons | CTRL.RIGHT
        moveX = moveX + 1
    end
    if input:GetKeyPress(KEY_SPACE) then
        buttons = buttons | CTRL.JUMP
        p.inputJump = true
    end
    if input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
        buttons = buttons | CTRL.DASH
        p.inputDash = true
    end

    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    if leftDown then
        buttons = buttons | CTRL.CHARGE
        if not p.charging then
            Player.StartCharging(p)
        end
    end
    if wasLeftDown_ and not leftDown then
        buttons = buttons | CTRL.EXPLODE_RELEASE
        if p.charging then
            local progress = math.min(1.0, (p.chargeTime or 0) / (Config.MaxChargeTime or 1.5))
            Player.DoExplode(p, progress)
        end
    end
    wasLeftDown_ = leftDown

    p.inputMoveX = moveX

    if serverConnection_ then
        serverConnection_.controls.buttons = buttons
    end
end

-- ============================================================================
-- Toast / State accessors
-- ============================================================================

function Client.ShowToast(msg)
    toastMessage_ = msg
    toastTimer_ = 3.0
end

function Client.GetState()
    return clientState_
end

function Client.GetMatchInfo()
    return matchPlayerCount_, matchTimeLeft_, matchRequired_
end

-- 兼容旧 HUD 接口名
function Client.GetQuickMatchInfo()
    return matchPlayerCount_, matchPlayerCount_
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

-- ============================================================================
-- Menu Actions
-- ============================================================================

function Client.RequestQuickMatch()
    if serverConnection_ == nil then
        Client.ShowToast("尚未连接到服务器")
        return
    end
    clientState_ = "MATCHING"
    matchPlayerCount_ = 1
    matchTimeLeft_ = Config.MatchingTimeout
    matchRequired_ = Config.NumPlayers
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_QUICK, true)
    print("[Client] Requesting quick match")
end

function Client.CancelQuickMatch()
    if serverConnection_ then
        serverConnection_:SendRemoteEvent(EVENTS.CANCEL_QUICK, true)
    end
    clientState_ = "MENU"
    print("[Client] Cancelled quick match")
end

-- ============================================================================
-- Update Loop
-- ============================================================================

---@param dt number
function Client.HandleUpdate(dt)
    HUD.CacheInput()

    if needSendReady_ and serverConnection_ then
        needSendReady_ = false
        serverConnection_:SendRemoteEvent(EVENTS.CLIENT_READY, true)
        print("[Client] CLIENT_READY sent")
    end

    Shared.UpdateDelayed()

    if toastTimer_ > 0 then
        toastTimer_ = toastTimer_ - dt
        if toastTimer_ <= 0 then toastMessage_ = "" end
    end

    -- 关卡列表 / 编辑器（与匹配状态独立）
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

    if GameManager.state == GameManager.STATE_EDITOR then
        LevelEditor.Update(dt)
        return
    end

    if GameManager.testPlayMode then
        if input:GetKeyPress(KEY_ESCAPE) or HUD.IsTestPlayExitClicked() then
            GameManager.ExitTestPlay()
            HUD.RefreshLevelList()
            return
        end
    end

    if clientState_ == "MENU" then
        Client.HandleMenuUpdate(dt)
    elseif clientState_ == "MATCHING" then
        Client.HandleMatchingUpdate(dt)
    elseif clientState_ == "PLAYING" then
        Client.HandlePlayingUpdate(dt)
    end
end

function Client.HandleMenuUpdate(dt)
    local btn = HUD.GetMenuButtonClicked()
    if btn == "quickStart" then
        Client.RequestQuickMatch()
    elseif btn == "editor" then
        HUD.RefreshLevelList()
        GameManager.EnterLevelList()
    end
end

function Client.HandleMatchingUpdate(dt)
    if input:GetKeyPress(KEY_ESCAPE) then
        Client.CancelQuickMatch()
    end
    -- 客户端本地倒计时（仅显示用，权威值来自 QUICK_UPDATE）
    if matchTimeLeft_ > 0 then
        matchTimeLeft_ = matchTimeLeft_ - dt
        if matchTimeLeft_ < 0 then matchTimeLeft_ = 0 end
    end
end

function Client.HandlePlayingUpdate(dt)
    Client.CollectInputAdvanced()
    Map.Update(dt)
    Player.UpdateAll(dt)
    Pickup.Update(dt)
    RandomPickup.Update(dt)
end

---@param dt number
function Client.HandlePostUpdate(dt)
    if clientState_ == "PLAYING" then
        local positions = Player.GetAlivePositions()
        local humanPos = Player.GetHumanPosition()
        Camera.Update(dt, positions, humanPos)
    end

    if debugDraw_ then
        local pw = scene_:GetComponent("PhysicsWorld")
        if pw then pw:DrawDebugGeometry(true) end
    end
end

_G.ClientModule = Client

return Client
-- ============================================================================
-- Client.lua - 超级红温！ 客户端（联机模式）
-- ============================================================================
-- 职责：
--   1. 连接服务端，发送 ClientReady
--   2. 接收 AssignRole → 绑定自己的角色节点
--   3. 每帧写入 Controls（键盘 → 位标志）
--   4. 为所有同步节点创建 LOCAL 视觉组件
--   5. 运行 Camera / HUD / SFX（仅客户端）
-- ============================================================================

require "LuaScripts/Utilities/Sample"

local Config   = require("Config")
local Shared   = require("Shared")
local Map      = require("Map")
local MapData  = require("MapData")
local Camera   = require("Camera")
local HUD      = require("HUD")
local SFX      = require("SFX")
local Player   = require("Player")
local GameManager = require("GameManager")

local EVENTS = Shared.EVENTS
local CTRL   = Shared.CTRL
local VARS   = Shared.VARS

local Client = {}

-- ============================================================================
-- Variables
-- ============================================================================

---@type Scene
local scene_ = nil

-- 我的角色
---@type Node
local myNode_ = nil
local myPlayerIndex_ = 0

-- 连接状态
local needSendReady_ = false
local pendingNodeId_ = 0        -- AssignRole 先到但节点还没同步时暂存
local pendingRoleNodes_ = {}    -- NodeAdded 收到的节点 ID 队列

-- 已设置视觉的节点 ID 集合
local visualSetup_ = {}

-- 游戏状态（从服务端同步）
local gameState_ = Shared.STATE_MENU
local serverTimeLeft_ = 0

-- 蓄力检测（客户端本地）
local wasChargingInput_ = false

-- ============================================================================
-- Entry
-- ============================================================================

function Client.Start()
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " (Client) ===")

    -- 注册远程事件
    Shared.RegisterEvents()

    -- 创建场景（客户端模式：含光照 + 渲染）
    scene_ = Shared.CreateScene(false)

    -- 背景渐变（LOCAL 纯视觉）
    Shared.CreateBackgroundPlane(scene_)

    -- 初始化本地地图（用于渲染方块视觉 — 物理由服务端同步）
    Map.Init(scene_)
    Map.Build()

    -- 初始化仅客户端的子系统
    SFX.Init(scene_)
    Camera.Init(scene_)

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
    renderer.defaultZone.fogColor = Color(0.95, 0.82, 0.68)

    -- 订阅网络事件
    SubscribeToEvent(EVENTS.ASSIGN_ROLE, "HandleAssignRole")
    SubscribeToEvent(EVENTS.GAME_STATE, "HandleGameState")
    SubscribeToEvent(EVENTS.KILL_EVENT, "HandleKillEvent")
    SubscribeToEvent(EVENTS.SCORE_UPDATE, "HandleScoreUpdate")
    SubscribeToEvent(EVENTS.PLAYER_DIED, "HandlePlayerDied")
    SubscribeToEvent(EVENTS.PLAYER_RESPAWN, "HandlePlayerRespawn")
    SubscribeToEvent(EVENTS.BLOCK_DESTROYED, "HandleBlockDestroyed")
    SubscribeToEvent(EVENTS.EXPLOSION_EVENT, "HandleExplosionEvent")
    SubscribeToEvent(scene_, "NodeAdded", "HandleNodeAdded")

    -- 连接服务端
    local serverConn = network:GetServerConnection()
    if serverConn then
        serverConn.scene = scene_
    end

    needSendReady_ = true
    Camera.spectateMode = true
    print("[Client] Started, connecting to server...")
end

function Client.Stop()
    print("[Client] Stopped")
end

-- ============================================================================
-- Event Handlers — Network
-- ============================================================================

--- 服务端分配角色
function HandleAssignRole(eventType, eventData)
    local nodeId = eventData["NodeId"]:GetUInt()
    myPlayerIndex_ = eventData["PlayerIndex"]:GetInt()

    print("[Client] AssignRole: nodeId=" .. nodeId .. " index=" .. myPlayerIndex_)

    local roleNode = scene_:GetNode(nodeId)
    if roleNode then
        Client.BindToRole(roleNode)
    else
        -- 节点还没同步过来，先暂存
        pendingNodeId_ = nodeId
        print("[Client] Node not yet synced, waiting...")
    end
end

--- 绑定到自己的角色节点
function Client.BindToRole(roleNode)
    myNode_ = roleNode
    Camera.spectateMode = false
    print("[Client] Bound to: " .. roleNode.name)
end

--- NodeAdded — 检查是否是等待中的角色节点
function HandleNodeAdded(eventType, eventData)
    local node = eventData["Node"]:GetPtr("Node")
    if node and node.replicated then
        table.insert(pendingRoleNodes_, node.ID)
    end
end

--- 游戏状态变更
function HandleGameState(eventType, eventData)
    local state = eventData["State"]:GetInt()
    serverTimeLeft_ = eventData["TimeLeft"]:GetFloat()
    gameState_ = state
    print("[Client] GameState → " .. state)
end

--- 击杀通知
function HandleKillEvent(eventType, eventData)
    local killerIndex = eventData["KillerIndex"]:GetInt()
    local victimIndex = eventData["VictimIndex"]:GetInt()
    local killType    = eventData["KillType"]:GetString()
    -- TODO: 传递给 HUD 显示击杀信息
    print("[Client] Kill: Player_" .. killerIndex .. " → Player_" .. victimIndex .. " (" .. killType .. ")")
end

--- 分数更新
function HandleScoreUpdate(eventType, eventData)
    local playerIndex = eventData["PlayerIndex"]:GetInt()
    local score       = eventData["Score"]:GetInt()
    -- TODO: 更新 HUD 分数显示
end

--- 玩家死亡
function HandlePlayerDied(eventType, eventData)
    -- TODO: 死亡特效
end

--- 玩家复活
function HandlePlayerRespawn(eventType, eventData)
    -- TODO: 复活特效
end

--- 方块被破坏
function HandleBlockDestroyed(eventType, eventData)
    -- TODO: 方块破坏视觉效果
end

--- 爆炸事件
function HandleExplosionEvent(eventType, eventData)
    -- TODO: 爆炸特效
end

-- ============================================================================
-- Update Loop
-- ============================================================================

---@param dt number
function Client.HandleUpdate(dt)
    -- 1. 首帧发送 ClientReady
    if needSendReady_ then
        needSendReady_ = false
        local serverConn = network:GetServerConnection()
        if serverConn then
            serverConn:SendRemoteEvent(EVENTS.CLIENT_READY, true)
            print("[Client] Sent ClientReady")
        end
    end

    -- 2. 处理待绑定的角色节点
    if pendingNodeId_ ~= 0 then
        local node = scene_:GetNode(pendingNodeId_)
        if node then
            Client.BindToRole(node)
            pendingNodeId_ = 0
        end
    end

    -- 3. 处理 NodeAdded 队列 → 为新同步的角色创建视觉
    Client.ProcessPendingNodes()

    -- 4. 发送输入（Controls）
    Client.SendInput()

    -- 5. 更新 HUD 输入缓存
    -- HUD.CacheInput()  -- TODO: 在 HUD 适配后启用
end

---@param dt number
function Client.HandlePostUpdate(dt)
    -- 相机跟随自己的角色
    if myNode_ then
        local pos = myNode_.position
        Camera.Update(dt, { pos }, pos)
    else
        -- 观战模式：跟随场景中的某个角色
        Camera.Update(dt, {}, nil)
    end
end

-- ============================================================================
-- Input → Controls
-- ============================================================================

--- 每帧将键盘/鼠标输入编码为 Controls 发送给服务端
function Client.SendInput()
    local serverConn = network:GetServerConnection()
    if not serverConn then return end

    local buttons = 0

    -- 方向
    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        buttons = buttons | CTRL.LEFT
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        buttons = buttons | CTRL.RIGHT
    end

    -- 跳跃（一次性）
    if input:GetKeyPress(KEY_SPACE) then
        buttons = buttons | CTRL.JUMP
    end

    -- 冲刺（一次性）
    if input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
        buttons = buttons | CTRL.DASH
    end

    -- 下砸（一次性）
    if input:GetKeyPress(KEY_S) or input:GetKeyPress(KEY_DOWN) then
        buttons = buttons | CTRL.SLAM
    end

    -- 蓄力（持续）
    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    if leftDown then
        buttons = buttons | CTRL.CHARGE
    end

    -- 释放爆炸（一次性：上帧按着 → 这帧松开）
    if wasChargingInput_ and not leftDown then
        buttons = buttons | CTRL.EXPLODE_RELEASE
    end
    wasChargingInput_ = leftDown

    -- 写入 Controls
    serverConn.controls.buttons = buttons
end

-- ============================================================================
-- Visual Setup for Replicated Nodes
-- ============================================================================

--- 为新同步的玩家节点创建 LOCAL 视觉组件
function Client.ProcessPendingNodes()
    if #pendingRoleNodes_ == 0 then return end

    local nodes = pendingRoleNodes_
    pendingRoleNodes_ = {}

    for _, nodeId in ipairs(nodes) do
        if not visualSetup_[nodeId] then
            local node = scene_:GetNode(nodeId)
            if node and string.find(node.name, "Player_") then
                -- 提取玩家编号
                local idxStr = string.match(node.name, "Player_(%d+)")
                local idx = tonumber(idxStr) or 1

                -- 创建视觉组件（LOCAL）
                Player.CreateVisuals(node, idx)
                visualSetup_[nodeId] = true
                print("[Client] Created visuals for " .. node.name)
            end
        end
    end
end

return Client

-- ============================================================================
-- Client.lua - 超级红温！ 客户端（联机模式）
-- ============================================================================
-- 职责：
--   1. 连接服务端，发送 ClientReady
--   2. 接收 AssignRole → 绑定自己的角色节点
--   3. 每帧写入 Controls（键盘 → 位标志）
--   4. 为所有同步节点创建 LOCAL 视觉组件
--   5. 运行 Camera / HUD / SFX（仅客户端）
--   6. 显示主菜单/结算/HUD（从服务端同步游戏状态）
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
local Pickup   = require("Pickup")
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

-- 场景扫描计时器（兜底：处理 NodeAdded 可能遗漏的复制节点）
local scanTimer_ = 0
local SCAN_INTERVAL = 1.0  -- 每秒扫描一次

-- 蓄力检测（客户端本地）
local wasChargingInput_ = false

-- Shared.STATE → GameManager.STATE 映射
local stateMap_ = {
    [Shared.STATE_MENU]      = GameManager.STATE_MENU,
    [Shared.STATE_COUNTDOWN] = GameManager.STATE_COUNTDOWN,
    [Shared.STATE_PLAYING]   = GameManager.STATE_PLAYING,
    [Shared.STATE_RESULT]    = GameManager.STATE_RESULT,
}

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

    -- 初始化本地地图（LOCAL 方块，不复制服务端地图几何）
    Map.Init(scene_)
    Map.Build()

    -- 初始化玩家模块（客户端：需要 Map 引用来创建视觉）
    Player.Init(scene_, Map)

    -- 初始化 Pickup 模块（客户端：仅用于视觉资源缓存）
    Pickup.Init(scene_, Player)

    -- 初始化仅客户端的子系统
    SFX.Init(scene_)
    Camera.Init(scene_)
    Camera.SetPlayerModule(Player)

    -- 初始化 GameManager（客户端只需要基础引用，用于 HUD 查询排名等）
    -- 客户端不运行游戏逻辑，只跟踪服务端广播的状态
    GameManager.Init(Player, Map, nil, nil, nil, Camera)
    GameManager.EnterMenu()

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
    renderer.defaultZone.fogColor = Color(0.95, 0.82, 0.68)

    -- 初始化 HUD（需要 Player、GameManager、Map 引用）
    HUD.Init(Player, GameManager, Map)

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

    -- 确保自己的节点在 Player.list 中标记为人类
    for _, p in ipairs(Player.list) do
        if p.node and p.node.ID == roleNode.ID then
            p.isHuman = true
            break
        end
    end
end

--- NodeAdded — 检查是否是等待中的角色节点
function HandleNodeAdded(eventType, eventData)
    local node = eventData["Node"]:GetPtr("Node")
    if node and node.replicated then
        table.insert(pendingRoleNodes_, node.ID)
    end
end

--- 游戏状态变更（从服务端广播）
function HandleGameState(eventType, eventData)
    local stateInt = eventData["State"]:GetInt()
    local timeLeft = eventData["TimeLeft"]:GetFloat()

    -- 将 Shared 数字状态映射为 GameManager 字符串状态
    local gmState = stateMap_[stateInt]
    if gmState then
        local oldState = GameManager.state
        GameManager.state = gmState
        -- 倒计时时 TimeLeft 是 stateTimer，游戏中 TimeLeft 是 gameTimer
        if stateInt == Shared.STATE_COUNTDOWN then
            GameManager.stateTimer = timeLeft
        elseif stateInt == Shared.STATE_PLAYING then
            GameManager.gameTimer = timeLeft
        end
        print("[Client] GameState: " .. oldState .. " → " .. gmState)
    else
        print("[Client] Unknown state int: " .. stateInt)
    end
end

--- 击杀通知
function HandleKillEvent(eventType, eventData)
    local killerIndex = eventData["KillerIndex"]:GetInt()
    local victimIndex = eventData["VictimIndex"]:GetInt()
    local killType    = eventData["KillType"]:GetString()

    -- 更新玩家存活状态
    for _, p in ipairs(Player.list) do
        if p.index == victimIndex then
            p.alive = false
        end
    end

    -- 生成击杀事件供 HUD 消费
    table.insert(GameManager.killEvents, {
        killerIndex = killerIndex,
        victimIndex = victimIndex,
        multiKillCount = 1,
        killStreak = 1,
        time = time.elapsedTime,
    })

    print("[Client] Kill: Player_" .. killerIndex .. " → Player_" .. victimIndex .. " (" .. killType .. ")")
end

--- 分数更新
function HandleScoreUpdate(eventType, eventData)
    local playerIndex = eventData["PlayerIndex"]:GetInt()
    local score       = eventData["Score"]:GetInt()

    for _, p in ipairs(Player.list) do
        if p.index == playerIndex then
            p.score = score
            break
        end
    end
end

--- 玩家死亡
function HandlePlayerDied(eventType, eventData)
    -- 死亡视觉效果由击杀事件处理
end

--- 玩家复活
function HandlePlayerRespawn(eventType, eventData)
    local playerIndex = eventData["PlayerIndex"]:GetInt()
    for _, p in ipairs(Player.list) do
        if p.index == playerIndex then
            p.alive = true
            break
        end
    end
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

    -- 3. 处理 NodeAdded 队列 → 为新同步的节点创建视觉
    Client.ProcessPendingNodes()

    -- 3.5 定期扫描场景复制节点（兜底：NodeAdded 可能遗漏初始同步）
    scanTimer_ = scanTimer_ + dt
    if scanTimer_ >= SCAN_INTERVAL then
        scanTimer_ = 0
        Client.ScanReplicatedNodes()
    end

    -- 4. 缓存鼠标输入（必须在 Update 阶段）
    HUD.CacheInput()

    -- 5. 菜单状态：处理"开始游戏"按钮点击
    if GameManager.state == GameManager.STATE_MENU then
        Camera.spectateMode = true
        local btn = HUD.GetMenuButtonClicked()
        if btn == "startGame" then
            -- 向服务端请求开始游戏
            local serverConn = network:GetServerConnection()
            if serverConn then
                serverConn:SendRemoteEvent(EVENTS.START_GAME, true)
                print("[Client] Sent START_GAME")
            end
        end
    end

    -- 6. 结算状态：处理"再来一局"/"返回菜单"按钮
    if GameManager.state == GameManager.STATE_RESULT then
        Camera.spectateMode = true
        local btn = HUD.GetResultButtonClicked()
        if btn == "restart" then
            local serverConn = network:GetServerConnection()
            if serverConn then
                serverConn:SendRemoteEvent(EVENTS.REQUEST_RESTART, true)
                print("[Client] Sent REQUEST_RESTART")
            end
        elseif btn == "menu" then
            -- 客户端本地返回菜单
            GameManager.state = GameManager.STATE_MENU
        end
    end

    -- 7. 状态切换时更新相机模式
    if GameManager.state == GameManager.STATE_COUNTDOWN or
       GameManager.state == GameManager.STATE_PLAYING then
        Camera.spectateMode = false
    end

    -- 8. 更新客户端本地的倒计时/计时器
    if GameManager.state == GameManager.STATE_COUNTDOWN then
        GameManager.stateTimer = GameManager.stateTimer - dt
    elseif GameManager.state == GameManager.STATE_PLAYING then
        GameManager.gameTimer = GameManager.gameTimer - dt
    end

    -- 9. 更新地图动画（方块重生倒计时等）
    Map.Update(dt)

    -- 10. 从复制节点同步代理玩家数据
    Client.SyncProxyPlayers()

    -- 11. 客户端视觉更新（squash、蓄力闪烁、眩晕、眼睛动画等）
    Client.UpdatePlayerVisuals(dt)

    -- 12. 发送输入（Controls）
    Client.SendInput()
end

---@param dt number
function Client.HandlePostUpdate(dt)
    -- 相机跟随
    if myNode_ and not Camera.spectateMode then
        local pos = myNode_.position
        Camera.Update(dt, { pos }, pos)
    else
        -- 观战模式
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

--- 为单个复制节点创建视觉组件（Player 或 Pickup）
---@param nodeId number
local function setupNodeVisuals(nodeId)
    if visualSetup_[nodeId] then return end

    local node = scene_:GetNode(nodeId)
    if not node or not node.replicated then return end

    local name = node.name

    -- Player 节点
    if string.find(name, "Player_") then
        local idxStr = string.match(name, "Player_(%d+)")
        local idx = tonumber(idxStr) or 1

        -- 创建视觉组件（LOCAL），保存返回的材质引用
        local visualNode, mat, outlineMat = Player.CreateVisuals(node, idx)
        visualSetup_[nodeId] = true

        -- 检查是否已在 Player.list 中
        local found = false
        for _, p in ipairs(Player.list) do
            if p.index == idx then
                found = true
                p.node = node  -- 更新节点引用
                p.visualNode = visualNode
                p.material = mat
                p.outlineMat = outlineMat
                break
            end
        end

        -- 不在列表中则创建代理条目
        if not found then
            local isMe = (myNode_ and myNode_.ID == nodeId)
                         or (idx == myPlayerIndex_)
            local proxy = Client.CreateProxyPlayer(node, idx, isMe, visualNode, mat, outlineMat)
            table.insert(Player.list, proxy)
            table.sort(Player.list, function(a, b) return a.index < b.index end)
        end

        print("[Client] Created visuals for " .. name)

    -- Pickup 节点
    elseif string.find(name, "Pickup_") then
        Pickup.CreateVisualsForNode(node)
        visualSetup_[nodeId] = true
    end
end

--- 为新同步的节点创建 LOCAL 视觉组件
function Client.ProcessPendingNodes()
    -- 处理 NodeAdded 队列
    if #pendingRoleNodes_ > 0 then
        local nodes = pendingRoleNodes_
        pendingRoleNodes_ = {}
        for _, nodeId in ipairs(nodes) do
            setupNodeVisuals(nodeId)
        end
    end
end

--- 定期扫描场景中的复制节点（兜底：NodeAdded 可能遗漏初始同步的节点）
function Client.ScanReplicatedNodes()
    local children = scene_:GetChildren()
    for _, node in ipairs(children) do
        if node.replicated and not visualSetup_[node.ID] then
            local name = node.name
            if string.find(name, "Player_") or string.find(name, "Pickup_") then
                setupNodeVisuals(node.ID)
            end
        end
    end
end

--- 创建代理玩家条目（供 HUD 读取）
---@param node Node
---@param index number
---@param isHuman boolean
---@return table
function Client.CreateProxyPlayer(node, index, isHuman, visualNode, mat, outlineMat)
    return {
        index = index,
        node = node,
        body = nil,                -- 客户端无物理
        isHuman = isHuman,
        alive = true,

        -- HUD 需要的字段
        score = 0,
        heightScore = 0,
        killScore = 0,
        pickupScore = 0,
        deaths = 0,
        maxHeight = 0,
        kills = 0,
        killStreak = 0,
        multiKillCount = 0,

        -- 能量/蓄力（从复制变量同步）
        energy = 0,
        charging = false,
        chargeProgress = 0,
        chargeTimer = 0,
        dashCooldown = 0,

        -- 输入字段（代理不需要，但避免 nil 错误）
        inputMoveX = 0,
        inputJump = false,
        inputDash = false,
        inputCharging = false,
        inputExplodeRelease = false,
        inputSlam = false,
        wasChargingInput = false,

        -- 视觉引用（材质动态效果需要）
        visualNode = visualNode,
        material = mat,
        outlineMat = outlineMat,
        lastFaceDir = 1,

        -- 下砸 / 眩晕（视觉更新需要）
        slamming = false,
        stunTimer = 0,
        dashTimer = 0,
        dashDir = 1,
        dashRoll = 0,

        -- squash & stretch 弹簧参数
        squashScaleX = 1.0,
        squashScaleY = 1.0,
        squashVelX = 0,
        squashVelY = 0,

        -- 碰撞状态（视觉形变需要，代理无物理所以始终为默认值）
        onGround = false,
        hitCeiling = false,
        hitWallX = 0,

        -- 眼睛动画参数
        eyeOffsetX = 0,
        eyeOffsetY = 0,
        eyeBaseX = 0.16,
        eyeBaseY = 0.06,
        eyeBaseZ = -0.48,
        eyeRadius = 0.22,
        blinkTimer = 0,
        blinkInterval = 3.0 + math.random() * 3.0,
        blinkPhase = 0,
        isBlinking = false,
        idleTimer = 0,
    }
end

-- ============================================================================
-- Sync Proxy Players from Replicated Node Vars
-- ============================================================================

--- 每帧从复制节点同步代理玩家数据（位置由引擎自动同步，
--- 但 score/alive 等自定义状态通过 Remote Events + 节点变量同步）
function Client.SyncProxyPlayers()
    for _, p in ipairs(Player.list) do
        if p.node then
            -- 位置由引擎自动同步（REPLICATED 节点）
            local pos = p.node.position

            -- 更新最高高度（客户端本地计算，用于 HUD 显示）
            local heightInBlocks = pos.y / Config.BlockSize
            if heightInBlocks > (p.maxHeight or 0) then
                p.maxHeight = heightInBlocks
            end

            -- 高度得分（客户端本地估算）
            p.heightScore = math.floor(heightInBlocks)

            -- 从节点变量同步能量/蓄力/冲刺状态（Server 每帧写入 REPLICATED 节点）
            local energyVar = p.node:GetVar("Energy")
            if not energyVar:IsEmpty() then
                p.energy = energyVar:GetFloat()
            end
            local chargingVar = p.node:GetVar("Charging")
            if not chargingVar:IsEmpty() then
                p.charging = chargingVar:GetBool()
            end
            local chargeVar = p.node:GetVar("ChargeProgress")
            if not chargeVar:IsEmpty() then
                p.chargeProgress = chargeVar:GetFloat()
            end
            local dashCdVar = p.node:GetVar("DashCooldown")
            if not dashCdVar:IsEmpty() then
                p.dashCooldown = dashCdVar:GetFloat()
            end
            local aliveVar = p.node:GetVar("Alive")
            if not aliveVar:IsEmpty() then
                p.alive = aliveVar:GetBool()
            end

            -- 视觉动效状态（驱动客户端 squash/flash/stun 等）
            local chargeTimerVar = p.node:GetVar("ChargeTimer")
            if not chargeTimerVar:IsEmpty() then
                p.chargeTimer = chargeTimerVar:GetFloat()
            end
            local dashTimerVar = p.node:GetVar("DashTimer")
            if not dashTimerVar:IsEmpty() then
                p.dashTimer = dashTimerVar:GetFloat()
            end
            local dashDirVar = p.node:GetVar("DashDir")
            if not dashDirVar:IsEmpty() then
                p.dashDir = dashDirVar:GetInt()
            end
            local stunTimerVar = p.node:GetVar("StunTimer")
            if not stunTimerVar:IsEmpty() then
                p.stunTimer = stunTimerVar:GetFloat()
            end
            local faceDirVar = p.node:GetVar("FaceDir")
            if not faceDirVar:IsEmpty() then
                p.lastFaceDir = faceDirVar:GetInt()
            end

            -- 计分同步（Server 权威）
            local scoreVar = p.node:GetVar("Score")
            if not scoreVar:IsEmpty() then
                p.score = scoreVar:GetInt()
            end
            local killScoreVar = p.node:GetVar("KillScore")
            if not killScoreVar:IsEmpty() then
                p.killScore = killScoreVar:GetInt()
            end
            local pickupScoreVar = p.node:GetVar("PickupScore")
            if not pickupScoreVar:IsEmpty() then
                p.pickupScore = pickupScoreVar:GetInt()
            end
            local deathsVar = p.node:GetVar("Deaths")
            if not deathsVar:IsEmpty() then
                p.deaths = deathsVar:GetInt()
            end
            local killsVar = p.node:GetVar("Kills")
            if not killsVar:IsEmpty() then
                p.kills = killsVar:GetInt()
            end
        end
    end
end

-- ============================================================================
-- Client-Side Visual Updates
-- ============================================================================

--- 客户端每帧更新所有玩家的视觉效果
--- 包括 squash & stretch、蓄力闪烁、眩晕形变、眼睛动画等
---@param dt number
function Client.UpdatePlayerVisuals(dt)
    for _, p in ipairs(Player.list) do
        if not p.visualNode then goto continue end

        -- 蓄力"红温"闪烁效果
        if p.charging and p.chargeProgress > 0 then
            Player.UpdateExplodeVisual(p)
        else
            -- 不在蓄力时确保材质是正常颜色
            -- 只在从蓄力→非蓄力的过渡帧恢复一次
            if p._wasCharging then
                Player.RestoreMaterial(p)
            end
        end
        p._wasCharging = p.charging

        -- squash & stretch + 冲刺旋转 + 眩晕 + 眼睛动画
        Player.UpdateVisualEffects(p, dt)

        ::continue::
    end
end

return Client

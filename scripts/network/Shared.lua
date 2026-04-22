-- ============================================================================
-- Shared.lua - 联机模块共享定义
-- 服务端和客户端共用的常量、远程事件注册、Controls 位掩码
-- ============================================================================

local Shared = {}

-- ============================================================================
-- Controls 位掩码（客户端输入 → connection.controls.buttons）
-- ============================================================================

Shared.CTRL = {
    LEFT            = 1,       -- A / ←
    RIGHT           = 2,       -- D / →
    JUMP            = 4,       -- Space
    DASH            = 8,       -- Shift / 右键
    CHARGE          = 16,      -- 鼠标左键按住
    EXPLODE_RELEASE = 32,      -- 鼠标左键松开（脉冲）
}

-- ============================================================================
-- 远程事件名
-- ============================================================================

Shared.EVENTS = {
    -- 服务端 → 客户端
    ASSIGN_ROLE      = "E_AssignRole",          -- 分配玩家角色
    ROOM_CREATED     = "E_RoomCreated",         -- 房间已创建（含房间码）
    ROOM_JOINED      = "E_RoomJoined",          -- 成功加入房间
    ROOM_UPDATE      = "E_RoomUpdate",          -- 房间状态更新（玩家列表等）
    ROOM_DISMISSED   = "E_RoomDismissed",       -- 房间被解散
    GAME_STARTING    = "E_GameStarting",        -- 游戏即将开始
    GAME_STATE       = "E_GameState",           -- 游戏状态同步（分数/回合等）
    JOIN_FAILED      = "E_JoinFailed",          -- 加入失败
    MATCH_FOUND      = "E_MatchFound",          -- 快速匹配成功
    QUICK_UPDATE     = "E_QuickUpdate",         -- 快速匹配队列人数更新
    KILL_EVENT       = "E_KillEvent",           -- 击杀事件广播

    -- 客户端 → 服务端
    CLIENT_READY     = "E_ClientReady",         -- 客户端场景准备完毕
    REQUEST_CREATE   = "E_RequestCreate",       -- 请求创建房间
    REQUEST_JOIN     = "E_RequestJoin",         -- 请求加入房间（含房间码）
    REQUEST_LEAVE    = "E_RequestLeave",        -- 请求离开房间
    REQUEST_DISMISS  = "E_RequestDismiss",      -- 请求解散房间
    REQUEST_ADD_AI   = "E_RequestAddAI",        -- 请求添加 AI
    REQUEST_START    = "E_RequestStart",        -- 请求开始游戏
    REQUEST_QUICK    = "E_RequestQuick",        -- 请求快速匹配
    CANCEL_QUICK     = "E_CancelQuick",         -- 取消快速匹配
}

-- ============================================================================
-- 节点变量 key
-- ============================================================================

Shared.VARS = {
    PLAYER_INDEX = "PlayerIdx",     -- number: 玩家编号 1~4
    IS_ALIVE     = "IsAlive",       -- bool
    IS_FINISHED  = "IsFinished",    -- bool
    ENERGY       = "Energy",        -- float: 能量值 0~1
    CHARGING     = "Charging",      -- bool: 是否蓄力中
    CHARGE_PROG  = "ChargeProg",    -- float: 蓄力进度 0~1
    FACE_DIR     = "FaceDir",       -- int: 面朝方向 1/-1
}

-- ============================================================================
-- 注册远程事件
-- ============================================================================

function Shared.RegisterEvents()
    for _, eventName in pairs(Shared.EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
    print("[Shared] Remote events registered")
end

-- ============================================================================
-- 延迟一帧执行（确保复制完成后再发远程事件）
-- ============================================================================

local pendingCallbacks_ = {}

function Shared.DelayOneFrame(callback)
    table.insert(pendingCallbacks_, { frames = 1, fn = callback })
end

function Shared.UpdateDelayed()
    local i = 1
    while i <= #pendingCallbacks_ do
        local cb = pendingCallbacks_[i]
        cb.frames = cb.frames - 1
        if cb.frames <= 0 then
            cb.fn()
            table.remove(pendingCallbacks_, i)
        else
            i = i + 1
        end
    end
end

return Shared

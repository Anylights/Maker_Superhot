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
    -- 服务端 → 客户端（会话事件）
    SESSION_START          = "E_SessionStart",         -- 会话开始（含 slot/地图种子/初始位置）
    SESSION_END            = "E_SessionEnd",           -- 会话结束（含最终分数）
    SCORE_UPDATE           = "E_ScoreUpdate",          -- 分数更新（高度/击杀/拾取）
    CHECKPOINT_ACTIVATED   = "E_CheckpointActivated",  -- 检查点激活确认
    LEADERBOARD_UPDATE     = "E_LeaderboardUpdate",    -- 实时排行榜更新
    GAME_STATE             = "E_GameState",            -- 游戏状态同步（保留，用于通用数据）

    -- 服务端 → 客户端（游戏事件，保留）
    KILL_EVENT       = "E_KillEvent",           -- 击杀事件广播
    EXPLODE_SYNC     = "E_ExplodeSync",         -- 爆炸同步（服务端→客户端）
    PLAYER_DEATH     = "E_PlayerDeath",         -- 玩家死亡同步（服务端→客户端）
    PICKUP_COLLECTED = "E_PickupCollected",     -- 道具被拾取（服务端→客户端，触发即时移除）

    -- 客户端 → 服务端
    CLIENT_READY     = "E_ClientReady",         -- 客户端场景准备完毕
    REQUEST_RESTART  = "E_RequestRestart",      -- 请求重新开始会话
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

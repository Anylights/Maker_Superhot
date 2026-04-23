-- ============================================================================
-- Shared.lua - 联机模块共享定义（精简版：仅保留快速匹配）
-- ============================================================================

local Shared = {}

-- ============================================================================
-- Controls 位掩码（客户端输入 → connection.controls.buttons）
-- ============================================================================

Shared.CTRL = {
    LEFT            = 1,
    RIGHT           = 2,
    JUMP            = 4,
    DASH            = 8,
    CHARGE          = 16,
    EXPLODE_RELEASE = 32,
}

-- ============================================================================
-- 远程事件名（仅快速匹配相关）
-- ============================================================================

Shared.EVENTS = {
    -- 服务端 → 客户端
    QUICK_UPDATE  = "E_QuickUpdate",   -- 匹配进度 {playerCount, timeLeft}
    MATCH_FOUND   = "E_MatchFound",    -- 匹配成功
    ASSIGN_ROLE   = "E_AssignRole",    -- 分配玩家槽位 + 节点 ID 列表
    GAME_STATE    = "E_GameState",     -- 同步对局状态
    KILL_EVENT    = "E_KillEvent",     -- 击杀广播

    -- 客户端 → 服务端
    CLIENT_READY  = "E_ClientReady",   -- 场景就绪
    REQUEST_QUICK = "E_RequestQuick",  -- 请求加入快速匹配
    CANCEL_QUICK  = "E_CancelQuick",   -- 取消匹配
}

Shared.VARS = {
    PLAYER_INDEX = "PlayerIdx",
    IS_ALIVE     = "IsAlive",
    IS_FINISHED  = "IsFinished",
    ENERGY       = "Energy",
    CHARGING     = "Charging",
    CHARGE_PROG  = "ChargeProg",
    FACE_DIR     = "FaceDir",
}

function Shared.RegisterEvents()
    for _, eventName in pairs(Shared.EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
    print("[Shared] Remote events registered (quick-match only)")
end

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

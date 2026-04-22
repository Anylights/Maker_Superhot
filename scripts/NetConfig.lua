-- ============================================================================
-- NetConfig.lua - 网络常量定义
-- Controls 位域、远程事件名、节点变量键名
-- ============================================================================

local NetConfig = {}

-- ============================================================================
-- Controls 位域（connection.controls.buttons）
-- ============================================================================
NetConfig.CTRL = {
    MOVE_LEFT       = 1,
    MOVE_RIGHT      = 2,
    JUMP            = 4,
    DASH            = 8,
    CHARGING        = 16,
    EXPLODE_RELEASE = 32,
}

-- 脉冲按键掩码（需要 SetPulseButtonMask 保证 reliable 传输）
NetConfig.PULSE_MASK = NetConfig.CTRL.JUMP
                     | NetConfig.CTRL.DASH
                     | NetConfig.CTRL.EXPLODE_RELEASE

-- ============================================================================
-- 远程事件名
-- ============================================================================
NetConfig.EVENTS = {
    -- 客户端 → 服务端
    CLIENT_READY    = "ClientReady",

    -- 服务端 → 客户端
    ASSIGN_ROLE     = "AssignRole",       -- 分配角色节点
    GAME_STATE      = "GameState",        -- 状态机变更
    MAP_DATA        = "MapData",          -- 地图数据同步
    MAP_EXPLODE     = "MapExplode",       -- 爆炸事件（视效）
    PLAYER_KILL     = "PlayerKill",       -- 击杀事件
    ROUND_RESULTS   = "RoundResults",     -- 回合结算
    COUNTDOWN_TICK  = "CountdownTick",    -- 倒计时
    PLAYER_FINISH   = "PlayerFinish",     -- 玩家到达终点
    SCORE_UPDATE    = "ScoreUpdate",      -- 积分同步
}

-- ============================================================================
-- 节点网络变量键名（SetVar / GetVar）
-- ============================================================================
NetConfig.VARS = {
    PLAYER_INDEX    = "PIdx",
    IS_ROLE         = "IsRole",
    ENERGY          = "Nrg",
    ALIVE           = "Alv",
    CHARGING        = "Chg",
    CHARGE_PROGRESS = "ChgP",
    FINISHED        = "Fin",
    FINISH_ORDER    = "FnOd",
    FACE_DIR        = "FDir",
    ON_GROUND       = "OGnd",
    DASH_COOLDOWN   = "DCd",
    INVINCIBLE      = "Inv",
}

-- ============================================================================
-- 注册所有远程事件（双端调用）
-- ============================================================================
function NetConfig.RegisterEvents()
    for _, eventName in pairs(NetConfig.EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
end

return NetConfig

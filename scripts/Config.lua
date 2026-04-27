-- ============================================================================
-- Config.lua - 超级红温！ 游戏配置常量
-- ============================================================================

local Config = {}

-- 游戏基本信息
Config.Title = "超级红温！"

-- 方块/网格尺寸（米）
Config.BlockSize = 1.0

-- 玩家颜色（4 名玩家）— 高饱和鲜艳
Config.PlayerColors = {
    Color(0.95, 0.22, 0.18, 1.0),  -- 番茄红
    Color(0.20, 0.48, 0.95, 1.0),  -- 宝蓝
    Color(0.18, 0.85, 0.35, 1.0),  -- 翠绿
    Color(0.98, 0.78, 0.12, 1.0),  -- 鲜黄
}

Config.PlayerEmissive = {
    Color(0.12, 0.02, 0.01),
    Color(0.01, 0.05, 0.12),
    Color(0.02, 0.10, 0.03),
    Color(0.12, 0.10, 0.01),
}

-- 玩家描边颜色（深色，每色独立）
Config.PlayerOutlineColors = {
    Color(0.45, 0.08, 0.06, 1.0),  -- 深红
    Color(0.06, 0.15, 0.50, 1.0),  -- 深蓝
    Color(0.06, 0.35, 0.10, 1.0),  -- 深绿
    Color(0.50, 0.35, 0.03, 1.0),  -- 深黄
}

-- 方块类型
Config.BLOCK_EMPTY      = 0
Config.BLOCK_NORMAL     = 1  -- 普通可破坏（白色）
Config.BLOCK_SAFE       = 2  -- 永久安全（深色）
Config.BLOCK_ENERGY_PAD = 3  -- 能量托台（亮色）
Config.BLOCK_SPAWN      = 4  -- 起点（旧版通用，兼容）
Config.BLOCK_FINISH     = 5  -- 终点
Config.BLOCK_SPAWN_P1   = 10 -- P1 出生点（番茄红）
Config.BLOCK_SPAWN_P2   = 11 -- P2 出生点（宝蓝）
Config.BLOCK_SPAWN_P3   = 12 -- P3 出生点（翠绿）
Config.BLOCK_SPAWN_P4   = 13 -- P4 出生点（鲜黄）

-- 方块颜色（温暖色调）
Config.BlockColors = {
    [1] = Color(0.92, 0.88, 0.82, 1.0),   -- 普通：奶白
    [2] = Color(0.30, 0.25, 0.22, 1.0),   -- 安全：巧克力灰
    [3] = Color(0.35, 0.85, 0.80, 1.0),   -- 能量托台：薄荷绿
    [4] = Color(0.45, 0.88, 0.40, 1.0),   -- 起点：暖绿（旧版兼容）
    [5] = Color(1.00, 0.75, 0.15, 1.0),   -- 终点：橙金
    [10] = Color(0.95, 0.22, 0.18, 1.0),  -- P1 出生点：番茄红
    [11] = Color(0.20, 0.48, 0.95, 1.0),  -- P2 出生点：宝蓝
    [12] = Color(0.18, 0.85, 0.35, 1.0),  -- P3 出生点：翠绿
    [13] = Color(0.98, 0.78, 0.12, 1.0),  -- P4 出生点：鲜黄
}

-- 出生点方块自发光颜色（复用 PlayerEmissive）
Config.SpawnBlockEmissive = {
    [10] = Config.PlayerEmissive[1],
    [11] = Config.PlayerEmissive[2],
    [12] = Config.PlayerEmissive[3],
    [13] = Config.PlayerEmissive[4],
}

-- 方块描边颜色（统一深棕）
Config.BlockOutlineColor = Color(0.20, 0.16, 0.13, 1.0)

-- 橡皮质感 PBR 参数
Config.RubberMetallic  = 0.02
Config.RubberRoughness = 0.65

-- 背景渐变色（NanoVG 绘制）
Config.BgColorTop = { 0.98, 0.85, 0.70 }  -- 温暖桃色
Config.BgColorBot = { 0.88, 0.65, 0.60 }  -- 淡玫瑰

-- 拾取物颜色
Config.PickupSmallColor   = Color(0.30, 0.90, 0.85, 1.0)  -- 薄荷
Config.PickupSmallOutline = Color(0.08, 0.40, 0.38, 1.0)
Config.PickupLargeColor   = Color(1.00, 0.80, 0.15, 1.0)  -- 金
Config.PickupLargeOutline = Color(0.50, 0.35, 0.03, 1.0)

-- 移动系统
Config.MoveSpeed       = 8.0     -- 水平移动速度 m/s
Config.MaxJumps        = 2       -- 最大跳跃次数（二段跳）
Config.DashSpeed       = 25.0    -- 冲刺速度 m/s（3x 移动速度，冲刺感更强）
Config.DashDuration    = 0.22    -- 冲刺持续时间（秒）：覆盖约 5.5m
Config.DashCooldown    = 2.0     -- 冲刺冷却（秒）
Config.AirControlRatio = 0.7     -- 空中控制系数

-- 冲刺击退
Config.DashKnockbackRadius = 1.5  -- 冲刺碰撞检测半径（米）
Config.DashKnockbackForce  = 28.0 -- 冲刺击退水平力（m/s）— 大于下砸
Config.DashKnockbackUp     = 8.0  -- 冲刺击退垂直力（m/s）

-- 下砸
Config.SlamSpeed         = 40.0   -- 下砸下落速度（m/s，非常快）
Config.SlamRadius        = 1.2    -- 下砸着陆水平击飞范围（米，左右各约 1 格）
Config.SlamKnockbackForce = 20.0  -- 下砸击飞水平力（m/s）— 小于冲刺
Config.SlamKnockbackUp   = 12.0   -- 下砸击飞垂直力（m/s）

-- 物理跳跃系统（速度 + 重力，类似超级鸡马）
-- 按一下跳固定高度，不需要长按。上升靠初速度，下落靠重力。
Config.JumpSpeed         = 14.0  -- 跳跃初始向上速度 (m/s)
Config.FallGravityMul    = 2.2   -- 下落时重力倍率（>1 = 下落更快更利落）
Config.MaxFallSpeed      = 30.0  -- 最大下落速度 (m/s)

-- 跳跃辅助
Config.CoyoteTime        = 0.08  -- 土狼时间（秒）
Config.JumpBufferTime    = 0.10  -- 跳跃缓冲（秒）

-- 能量系统
Config.EnergyChargeTime   = 16.0   -- 自动充满时间（秒）
Config.SmallEnergyAmount  = 0.20   -- 小能量块增加量
Config.LargeEnergyAmount  = 0.40   -- 大能量块增加量
Config.PickupRespawnTime  = 8.0    -- 道具刷新时间（秒）

-- 爆炸系统
Config.ExplosionRadius     = 7      -- 爆炸最大半径（格）
Config.ExplosionChargeTime = 2.5    -- 蓄力到最大范围的时间（秒）
Config.ExplosionRecovery   = 0.20   -- 爆炸后摇（秒）
Config.PlatformRespawnTime = 6.0    -- 平台重生时间（秒）

-- 死亡与重生
Config.RespawnDelay       = 1.5    -- 复活等待（秒）
Config.InvincibleDuration = 1.0    -- 出生保护（秒）
Config.DeathY             = -10.0  -- 死亡区域 Y 坐标

-- 比赛系统
Config.RoundDuration     = 75.0    -- 单局时长（秒）
Config.WinScore          = 15      -- 胜利积分目标
Config.PlaceScores       = { 5, 3, 2, 1 }  -- 名次对应积分
Config.CountdownTime     = 3.0     -- 开局倒计时（秒）

-- 击杀积分
Config.KillScore         = 1       -- 每次击杀得分
Config.MultiKillWindow   = 2.0     -- 连续击杀判定窗口（秒）
Config.MultiKillTexts    = {       -- 连杀文字（按连续击杀数索引）
    [1] = "击杀!",
    [2] = "双杀!",
    [3] = "三杀!",
    [4] = "四杀!",
    [5] = "超神!",
}
Config.KillStreakTexts    = {       -- 连杀文字（按连续不死击杀数索引，≥3 显示）
    [3] = "连杀中!",
    [5] = "杀疯了!",
    [7] = "无人能挡!",
}

-- 开场镜头动画
Config.IntroFocusFinishTime  = 1.5   -- 聚焦终点持续时间（秒）
Config.IntroPanToSpawnTime   = 1.5   -- 平移到起点持续时间（秒）
Config.IntroZoomTextTime     = 1.5   -- 放大+文字显示持续时间（秒）
Config.IntroZoomOutTime      = 1.0   -- 拉远回全景过渡时间（秒）
Config.IntroFinishOrtho      = 8.0   -- 聚焦终点时的正交尺寸（拉近）
Config.IntroSpawnOrtho       = 10.0  -- 聚焦起点时的正交尺寸

-- 匹配系统
Config.MatchingTimeout   = 10.0    -- 匹配超时（秒），超时后 AI 静默补齐

-- 联机配置
Config.RoomStartDelay    = 1.5     -- 点击开始后延迟（秒），给客户端准备时间

-- 相机
Config.CameraZ           = -40.0   -- 相机 Z 位置（侧视）
Config.CameraMinOrtho    = 12.0    -- 最小正交尺寸
Config.CameraMaxOrtho    = 40.0    -- 最大正交尺寸（适配更大地图）
Config.CameraPadding     = 4.0     -- 相机包围盒边距
Config.CameraSmoothSpeed = 3.0     -- 相机平滑速度
Config.CameraEndTransDur = 1.5     -- 回合结束时镜头过渡到全景的时长（秒）

-- 玩家数量
Config.NumPlayers = 4

-- 默认地图尺寸（30x24 固定相机可视全局）
Config.DefaultMapWidth  = 30
Config.DefaultMapHeight = 24

-- 出生点方块类型列表（按玩家编号索引）
Config.SpawnBlockTypes = {
    Config.BLOCK_SPAWN_P1,
    Config.BLOCK_SPAWN_P2,
    Config.BLOCK_SPAWN_P3,
    Config.BLOCK_SPAWN_P4,
}

--- 判断方块类型是否为出生点（含旧版和 P1-P4）
---@param blockType number
---@return boolean
function Config.IsSpawnBlock(blockType)
    return blockType == Config.BLOCK_SPAWN
        or blockType == Config.BLOCK_SPAWN_P1
        or blockType == Config.BLOCK_SPAWN_P2
        or blockType == Config.BLOCK_SPAWN_P3
        or blockType == Config.BLOCK_SPAWN_P4
end

return Config

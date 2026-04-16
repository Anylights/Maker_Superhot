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
Config.BLOCK_SPAWN      = 4  -- 起点
Config.BLOCK_FINISH     = 5  -- 终点

-- 方块颜色（温暖色调）
Config.BlockColors = {
    [1] = Color(0.92, 0.88, 0.82, 1.0),   -- 普通：奶白
    [2] = Color(0.30, 0.25, 0.22, 1.0),   -- 安全：巧克力灰
    [3] = Color(0.35, 0.85, 0.80, 1.0),   -- 能量托台：薄荷绿
    [4] = Color(0.45, 0.88, 0.40, 1.0),   -- 起点：暖绿
    [5] = Color(1.00, 0.75, 0.15, 1.0),   -- 终点：橙金
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
Config.MaxJumps        = 1       -- 最大跳跃次数（仅一段跳）
Config.DashSpeed       = 25.0    -- 冲刺速度 m/s（3x 移动速度，冲刺感更强）
Config.DashDuration    = 0.22    -- 冲刺持续时间（秒）：覆盖约 5.5m
Config.DashCooldown    = 2.0     -- 冲刺冷却（秒）
Config.AirControlRatio = 0.7     -- 空中控制系数

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

-- 相机
Config.CameraZ           = -40.0   -- 相机 Z 位置（侧视）
Config.CameraMinOrtho    = 12.0    -- 最小正交尺寸
Config.CameraMaxOrtho    = 30.0    -- 最大正交尺寸
Config.CameraPadding     = 4.0     -- 相机包围盒边距
Config.CameraSmoothSpeed = 3.0     -- 相机平滑速度

-- 玩家数量
Config.NumPlayers = 4

return Config

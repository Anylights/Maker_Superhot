-- ============================================================================
-- Config.lua - 超级红温！ 游戏配置常量
-- ============================================================================

local Config = {}

-- 游戏基本信息
Config.Title = "超级红温！"

-- 方块/网格尺寸（米）
Config.BlockSize = 1.0

-- 玩家颜色（4 名玩家）
Config.PlayerColors = {
    Color(0.90, 0.25, 0.20, 1.0),  -- 红
    Color(0.20, 0.55, 0.90, 1.0),  -- 蓝
    Color(0.25, 0.80, 0.35, 1.0),  -- 绿
    Color(0.95, 0.75, 0.15, 1.0),  -- 黄
}

Config.PlayerEmissive = {
    Color(0.15, 0.03, 0.02),
    Color(0.02, 0.08, 0.15),
    Color(0.03, 0.12, 0.04),
    Color(0.15, 0.12, 0.02),
}

-- 方块类型
Config.BLOCK_EMPTY      = 0
Config.BLOCK_NORMAL     = 1  -- 普通可破坏（白色）
Config.BLOCK_SAFE       = 2  -- 永久安全（深色）
Config.BLOCK_ENERGY_PAD = 3  -- 能量托台（亮色）
Config.BLOCK_SPAWN      = 4  -- 起点
Config.BLOCK_FINISH     = 5  -- 终点

-- 方块颜色
Config.BlockColors = {
    [1] = Color(0.85, 0.85, 0.88, 1.0),   -- 普通：浅灰白
    [2] = Color(0.25, 0.25, 0.30, 1.0),   -- 安全：深灰
    [3] = Color(0.40, 0.85, 0.95, 1.0),   -- 能量托台：亮青
    [4] = Color(0.30, 0.90, 0.40, 1.0),   -- 起点：绿色
    [5] = Color(1.00, 0.85, 0.20, 1.0),   -- 终点：金色
}

-- 移动系统
Config.MoveSpeed       = 8.0     -- 水平移动速度 m/s
Config.MaxJumps        = 1       -- 最大跳跃次数（仅一段跳）
Config.DashSpeed       = 25.0    -- 冲刺速度 m/s（3x 移动速度，冲刺感更强）
Config.DashDuration    = 0.22    -- 冲刺持续时间（秒）：覆盖约 5.5m
Config.DashCooldown    = 2.0     -- 冲刺冷却（秒）
Config.AirControlRatio = 0.7     -- 空中控制系数

-- 曲线跳跃系统（替代物理跳跃）
-- 横轴 = 时间，纵轴 = Y 位移，用幂次曲线控制形状
-- 上升：y(t) = H * (1 - (1-t)^e_rise)，t ∈ [0,1] 映射到 [0, RiseTime]
-- 下落：y(t) = H * (1 - t^e_fall)，t ∈ [0,1] 映射到 [0, FallTime]
Config.JumpHeight        = 3.5   -- 跳跃最大高度（米）
Config.JumpRiseTime      = 0.22  -- 上升持续时间（秒）：越小越快到顶
Config.JumpFallTime      = 0.18  -- 下落持续时间（秒）：越小落得越快
Config.JumpRiseExponent  = 2.0   -- 上升曲线指数：>1 前快后慢，=1 线性
Config.JumpFallExponent  = 2.5   -- 下落曲线指数：>1 先慢后快（重力感）

-- 跳跃手感增强（参考 Celeste / Hollow Knight 设计）
Config.CoyoteTime        = 0.10  -- 土狼时间：走出平台后仍可跳跃的窗口（秒）
Config.JumpBufferTime    = 0.10  -- 跳跃缓冲：落地前提前按跳跃的有效窗口（秒）
Config.JumpCutMultiplier = 0.4   -- 可变跳跃高度：松开跳跃键时 Y 速度乘以此系数（<1 = 短按跳得低）
Config.ApexHangThreshold = 0.15  -- 顶点滞空：顶点附近速度低于此比例时触发减速
Config.ApexHangGravityMul = 0.3  -- 顶点滞空时重力/下落速度的缩放系数（<1 = 顶点悬浮更久）

-- 能量系统
Config.EnergyChargeTime   = 16.0   -- 自动充满时间（秒）
Config.SmallEnergyAmount  = 0.20   -- 小能量块增加量
Config.LargeEnergyAmount  = 0.40   -- 大能量块增加量
Config.PickupRespawnTime  = 8.0    -- 道具刷新时间（秒）

-- 爆炸系统
Config.ExplosionRadius    = 7      -- 爆炸半径（格）
Config.ExplosionWindup    = 0.35   -- 爆炸前摇（秒）
Config.ExplosionRecovery  = 0.20   -- 爆炸后摇（秒）
Config.PlatformRespawnTime = 3.5   -- 平台重生时间（秒）

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

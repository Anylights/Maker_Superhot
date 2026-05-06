-- ============================================================================
-- Config.lua - 超级红温！ 游戏配置常量
-- ============================================================================

local Config = {}

-- 游戏基本信息
Config.Title = "超级红温！"

-- 方块/网格尺寸（米）
Config.BlockSize = 1.0

-- 玩家颜色（4 名玩家）— 高饱和鲜艳，加亮以抵消网络复制变灰
Config.PlayerColors = {
    Color(1.00, 0.38, 0.32, 1.0),  -- 亮番茄红
    Color(0.40, 0.65, 1.00, 1.0),  -- 亮宝蓝
    Color(0.35, 1.00, 0.50, 1.0),  -- 亮翠绿
    Color(1.00, 0.90, 0.28, 1.0),  -- 亮鲜黄
}

-- 自发光强度进一步提升，让玩家在场景中更醒目
Config.PlayerEmissive = {
    Color(0.55, 0.10, 0.06),   -- 红光
    Color(0.08, 0.20, 0.55),   -- 蓝光
    Color(0.08, 0.45, 0.12),   -- 绿光
    Color(0.55, 0.42, 0.06),   -- 黄光
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
Config.BLOCK_SAFE       = 2  -- 永久安全（深色）— 也用于检查点平台
Config.BLOCK_ENERGY_PAD = 3  -- 能量托台（亮色）
Config.BLOCK_SPAWN      = 4  -- 起点（旧版通用，兼容）
Config.BLOCK_CHECKPOINT = 5  -- 检查点标记（视觉特殊，不可破坏）
Config.BLOCK_SPAWN_P1   = 10 -- P1 出生点（番茄红）
Config.BLOCK_SPAWN_P2   = 11 -- P2 出生点（宝蓝）
Config.BLOCK_SPAWN_P3   = 12 -- P3 出生点（翠绿）
Config.BLOCK_SPAWN_P4   = 13 -- P4 出生点（鲜黄）

-- 方块颜色（温暖色调，提亮以抵消变灰）
Config.BlockColors = {
    [1] = Color(1.00, 0.97, 0.92, 1.0),   -- 普通：明亮暖白
    [2] = Color(0.45, 0.38, 0.32, 1.0),   -- 安全：浅棕
    [3] = Color(0.50, 0.98, 0.92, 1.0),   -- 能量托台：亮薄荷绿
    [4] = Color(0.58, 1.00, 0.55, 1.0),   -- 起点：亮暖绿
    [5] = Color(0.90, 0.55, 1.00, 1.0),   -- 检查点：亮紫色（醒目标识）
    [10] = Color(1.00, 0.38, 0.32, 1.0),  -- P1 出生点：亮红（同步玩家色）
    [11] = Color(0.40, 0.65, 1.00, 1.0),  -- P2 出生点：亮蓝（同步玩家色）
    [12] = Color(0.35, 1.00, 0.50, 1.0),  -- P3 出生点：亮绿（同步玩家色）
    [13] = Color(1.00, 0.90, 0.28, 1.0),  -- P4 出生点：亮黄（同步玩家色）
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

-- 橡皮质感 PBR 参数（低粗糙度增强反光，对抗变灰）
Config.RubberMetallic  = 0.04
Config.RubberRoughness = 0.42

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

-- 物理跳跃系统（速度 + 重力，类似超级鸡马）
-- 按一下跳固定高度，不需要长按。上升靠初速度，下落靠重力。
Config.JumpSpeed         = 14.0  -- 跳跃初始向上速度 (m/s)
Config.FallGravityMul    = 2.2   -- 下落时重力倍率（>1 = 下落更快更利落）
Config.MaxFallSpeed      = 30.0  -- 最大下落速度 (m/s)

-- 跳跃辅助
Config.CoyoteTime        = 0.08  -- 土狼时间（秒）- 单机/服务端本地
Config.JumpBufferTime    = 0.10  -- 跳跃缓冲（秒）- 单机/服务端本地
-- 联机补偿：RTT 导致 coyoteTime 在服务端几乎失效，需要更宽的窗口
Config.NetCoyoteTime     = 0.20  -- 联机土狼时间（秒）
Config.NetJumpBufferTime = 0.20  -- 联机跳跃缓冲（秒）

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
Config.RespawnDelay       = 3.0    -- 复活等待（秒）— 检查点复活延迟
Config.InvincibleDuration = 1.0    -- 出生保护（秒）
Config.DeathY             = -10.0  -- 死亡区域 Y 坐标

-- 会话系统（个人独立计时）
Config.SessionDuration   = 60.0    -- 个人会话时长（秒）

-- 计分系统
Config.HeightScorePerBlock = 10    -- 每上/下1格 ±10 分
Config.KillScore           = 10    -- 击杀得分
Config.DeathPenalty        = 10    -- 死亡扣分
Config.MultiKillWindow     = 2.0   -- 连续击杀判定窗口（秒）
Config.MultiKillBonus      = 5     -- 双杀/三杀额外加分
Config.PickupScoreSmall    = 1     -- 小拾取物得分
Config.PickupScoreLarge    = 3     -- 大拾取物得分
Config.MultiKillTexts      = {     -- 连杀文字（按连续击杀数索引）
    [1] = "击杀!",
    [2] = "双杀!",
    [3] = "三杀!",
    [4] = "四杀!",
    [5] = "超神!",
}
Config.KillStreakTexts     = {     -- 连杀文字（按连续不死击杀数索引，≥3 显示）
    [3] = "连杀中!",
    [5] = "杀疯了!",
    [7] = "无人能挡!",
}

-- 检查点系统
Config.CheckpointInterval = 10     -- 每隔多少层一个检查点

-- AI 密度管理
Config.AIEntitiesPerSection  = 3   -- 每10层目标实体数（含真人）
Config.AISectionLayers       = 10  -- 一个分区的层数
Config.AIMinPerSection       = 1   -- 分区最少AI数
Config.AIMaxPerSection       = 3   -- 分区最多AI数
Config.AIDensityUpdateInterval = 5.0  -- AI密度检查间隔（秒）
Config.AISessionDuration     = 60.0   -- AI会话时长（与人类相同）

-- 最大实体数
Config.MaxTotalEntities  = 24     -- 服务端最大同时实体数（真人+AI）

-- 相机（大世界模式：跟随本地玩家）
Config.CameraZ           = -40.0   -- 相机 Z 位置（侧视）
Config.CameraMinOrtho    = 12.0    -- 最小正交尺寸
Config.CameraMaxOrtho    = 40.0    -- 最大正交尺寸（适配更大地图）
Config.CameraPadding     = 4.0     -- 相机包围盒边距
Config.CameraSmoothSpeed = 3.0     -- 相机平滑速度
Config.CameraFollowOrtho = 14.0    -- 跟随玩家时的正交尺寸

-- 分块渲染
Config.ChunkRenderBuffer = 15.0    -- 相机上下各渲染 ±15m 的方块

-- 玩家数量（颜色槽位数，实际在线玩家可超过4，颜色循环使用）
Config.NumPlayerColors = 4

-- 默认地图尺寸（30x500 大世界）
Config.DefaultMapWidth  = 30
Config.DefaultMapHeight = 500

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

--- 判断方块类型是否不可破坏（安全/检查点/出生点）
---@param blockType number
---@return boolean
function Config.IsIndestructible(blockType)
    return blockType == Config.BLOCK_SAFE
        or blockType == Config.BLOCK_CHECKPOINT
        or Config.IsSpawnBlock(blockType)
end

-- 排行榜
Config.LeaderboardUpdateInterval = 2.0  -- 排行榜广播间隔（秒）
Config.LeaderboardMaxEntries     = 16   -- 排行榜最大显示条数

return Config

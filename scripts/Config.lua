-- ============================================================================
-- Config.lua - 超级红温！ 游戏配置常量
-- ============================================================================

local Config = {}

-- 游戏基本信息
Config.Title = "超级红温！"

-- 方块/网格尺寸（米）
Config.BlockSize = 1.0

-- 玩家颜色（6 名玩家）— 高饱和鲜艳
Config.PlayerColors = {
    Color(0.95, 0.22, 0.18, 1.0),  -- 番茄红
    Color(0.20, 0.48, 0.95, 1.0),  -- 宝蓝
    Color(0.18, 0.85, 0.35, 1.0),  -- 翠绿
    Color(0.98, 0.78, 0.12, 1.0),  -- 鲜黄
    Color(0.85, 0.30, 0.90, 1.0),  -- 紫罗兰
    Color(1.00, 0.55, 0.15, 1.0),  -- 橙色
}

Config.PlayerEmissive = {
    Color(0.12, 0.02, 0.01),
    Color(0.01, 0.05, 0.12),
    Color(0.02, 0.10, 0.03),
    Color(0.12, 0.10, 0.01),
    Color(0.10, 0.03, 0.12),
    Color(0.12, 0.06, 0.01),
}

-- 玩家描边颜色（深色，每色独立）
Config.PlayerOutlineColors = {
    Color(0.45, 0.08, 0.06, 1.0),  -- 深红
    Color(0.06, 0.15, 0.50, 1.0),  -- 深蓝
    Color(0.06, 0.35, 0.10, 1.0),  -- 深绿
    Color(0.50, 0.35, 0.03, 1.0),  -- 深黄
    Color(0.38, 0.10, 0.42, 1.0),  -- 深紫
    Color(0.50, 0.22, 0.03, 1.0),  -- 深橙
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
    [2] = Color(0.259, 0.255, 0.318, 1.0), -- 安全：深灰紫 #424151
    [3] = Color(0.35, 0.85, 0.80, 1.0),   -- 能量托台：薄荷绿
    [4] = Color(0.45, 0.88, 0.40, 1.0),   -- 起点：暖绿（旧版兼容）
    [5] = Color(1.00, 0.75, 0.15, 1.0),   -- 终点：橙金
    [10] = Color(0.95, 0.22, 0.18, 1.0),  -- P1 出生点：番茄红
    [11] = Color(0.20, 0.48, 0.95, 1.0),  -- P2 出生点：宝蓝
    [12] = Color(0.18, 0.85, 0.35, 1.0),  -- P3 出生点：翠绿
    [13] = Color(0.98, 0.78, 0.12, 1.0),  -- P4 出生点：鲜黄
    [14] = Color(0.85, 0.30, 0.90, 1.0),  -- P5 出生点：紫罗兰
    [15] = Color(1.00, 0.55, 0.15, 1.0),  -- P6 出生点：橙色
    [6]  = Color(0.22, 0.855, 0.867, 1.0), -- 检查点：青绿 #38DADD
}

-- P5/P6 出生点方块
Config.BLOCK_SPAWN_P5   = 14 -- P5 出生点（紫罗兰）
Config.BLOCK_SPAWN_P6   = 15 -- P6 出生点（橙色）

-- 出生点方块自发光颜色（复用 PlayerEmissive）
Config.SpawnBlockEmissive = {
    [10] = Config.PlayerEmissive[1],
    [11] = Config.PlayerEmissive[2],
    [12] = Config.PlayerEmissive[3],
    [13] = Config.PlayerEmissive[4],
    [14] = Config.PlayerEmissive[5],
    [15] = Config.PlayerEmissive[6],
}

-- 检查点方块类型
Config.BLOCK_CHECKPOINT = 6

-- 方块描边颜色（统一深棕）
Config.BlockOutlineColor = Color(0.20, 0.16, 0.13, 1.0)

-- 橡皮质感 PBR 参数
Config.RubberMetallic  = 0.02
Config.RubberRoughness = 0.65

-- 背景渐变色（NanoVG 绘制）
Config.BgColorTop = { 0.16, 0.10, 0.35 }  -- 深蓝紫（上）
Config.BgColorBot = { 0.10, 0.07, 0.25 }  -- 更深蓝紫（下）

-- 拾取物颜色
Config.PickupSmallColor   = Color(0.30, 0.90, 0.85, 1.0)  -- 薄荷
Config.PickupSmallOutline = Color(0.08, 0.40, 0.38, 1.0)
Config.PickupLargeColor   = Color(1.00, 0.80, 0.15, 1.0)  -- 金
Config.PickupLargeOutline = Color(0.50, 0.35, 0.03, 1.0)

-- 移动系统
Config.MoveSpeed       = 8.0     -- 水平移动速度 m/s
Config.MaxJumps        = 2       -- 最大跳跃次数（二段跳）
Config.DashSpeed       = 33.33   -- 冲刺速度 m/s
Config.DashDuration    = 0.0825  -- 冲刺持续时间（秒）：覆盖约 2.75m
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
Config.SlamStunDuration  = 1.0    -- 下砸击中后眩晕时间（秒）

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

-- 游戏模式
Config.GAMEMODE_NORMAL   = "normal"   -- 普通模式（2分钟限时赛）
Config.GAMEMODE_ONELIFE  = "onelife"  -- 一命通天（无限时间，一条命）

-- 游戏时间
Config.GameDuration      = 120.0   -- 单局总时长（秒）= 2 分钟
Config.CountdownTime     = 3.0     -- 开局倒计时（秒）

-- 高度积分
Config.HeightScoreUnit   = 10      -- 每上升 1 格得分
Config.HeightPenaltyUnit = 10      -- 每下降 1 格扣分（同步实时）

-- 击杀积分
Config.KillScoreBase     = 50      -- 单杀基础分
Config.DeathPenalty      = 10      -- 死亡扣分
Config.MultiKillBonus    = {       -- 连杀额外加分（在基础分之上）
    [2] = 50,                      -- 双杀 +50
    [3] = 100,                     -- 三杀 +100
    [4] = 200,                     -- 四杀 +200
}
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

-- 拾取物积分
Config.PickupSmallScore  = 10      -- 小能量块得分
Config.PickupLargeScore  = 30      -- 大能量块得分

-- ============================================================================
-- 特殊道具系统
-- ============================================================================
Config.PowerUpDuration      = 8.0    -- 道具持续时间（秒）
Config.PowerUpSpawnRatio    = 0.30   -- 道具刷新概率（30%）

-- 超级变大
Config.SuperBigScale        = 2.0    -- 放大倍率（视觉 + 碰撞体）
Config.SuperBigSlamShake    = 0.45   -- 变大后下砸震屏强度（默认 0.10）

-- 超级变小
Config.SuperSmallScale      = 0.4    -- 缩小倍率
Config.SuperSmallJumpMul    = 1.4    -- 变小后跳跃力增强
Config.SuperSmallDashMul    = 1.3    -- 变小后冲刺速度增强

-- 缩放过渡
Config.ScaleLerpSpeed       = 3.0    -- scale lerp 速率

-- 道具颜色（用于外观 + 角色发光）
Config.PowerUpColors = {
    superBig     = Color(1.00, 0.60, 0.10, 1.0),  -- 橙色
    superSmall   = Color(0.20, 0.90, 0.30, 1.0),  -- 绿色
    infiniteDash = Color(0.20, 0.50, 1.00, 1.0),  -- 蓝色
    unstoppable  = Color(0.70, 0.20, 0.90, 1.0),  -- 紫色
    instantHot   = Color(1.00, 0.20, 0.15, 1.0),  -- 红色
}

-- 道具名称（HUD 显示）
Config.PowerUpNames = {
    superBig     = "超级变大",
    superSmall   = "超级变小",
    infiniteDash = "无限冲刺",
    unstoppable  = "势如破竹",
    instantHot   = "直接红温",
}

-- 尖刺系统
Config.SpikeStartFloor   = 10     -- 尖刺开始出现的层数
Config.SpikeMaxProb       = 0.80   -- 尖刺最大概率（80%）
Config.SpikeDecayParam    = 200    -- 反函数衰减参数（越大越缓，600层时趋近上限）
Config.SpikeColor         = Color(0.95, 0.15, 0.10, 1.0)   -- 尖刺红色
Config.SpikeOutlineColor  = Color(0.50, 0.06, 0.04, 1.0)   -- 尖刺暗红描边

-- 检查点
Config.CheckpointInterval = 20     -- 每隔多少格放一个检查点（~5层）

-- 开场镜头动画
Config.IntroFocusFinishTime  = 1.5   -- 聚焦终点持续时间（秒）
Config.IntroPanToSpawnTime   = 1.5   -- 平移到起点持续时间（秒）
Config.IntroZoomTextTime     = 1.5   -- 放大+文字显示持续时间（秒）
Config.IntroZoomOutTime      = 1.0   -- 拉远回全景过渡时间（秒）
Config.IntroFinishOrtho      = 8.0   -- 聚焦终点时的正交尺寸（拉近）
Config.IntroSpawnOrtho       = 10.0  -- 聚焦起点时的正交尺寸

-- 伪联机：观战与 AI 散布
Config.SpectateSwitchTime  = 5.0   -- 观战切换 AI 目标间隔（秒）
Config.AIScatterMaxRatio   = 0.6   -- AI 散布到地图下方 60% 的检查点

-- 相机
Config.CameraZ           = -40.0   -- 相机 Z 位置（侧视）
Config.CameraMinOrtho    = 12.0    -- 最小正交尺寸
Config.CameraMaxOrtho    = 40.0    -- 最大正交尺寸（适配更大地图）
Config.CameraPadding     = 4.0     -- 相机包围盒边距
Config.CameraSmoothSpeed = 3.0     -- 相机平滑速度
Config.CameraEndTransDur = 1.5     -- 回合结束时镜头过渡到全景的时长（秒）

-- 玩家数量（1 人类 + 24 AI，保证检查点间密度 3-4 人）
Config.NumPlayers = 25

-- 默认地图尺寸（30 宽 × 200 高，大地图攀登模式）
Config.DefaultMapWidth  = 30
Config.DefaultMapHeight = 600

-- 出生点方块类型列表（按玩家编号索引）
Config.SpawnBlockTypes = {
    Config.BLOCK_SPAWN_P1,
    Config.BLOCK_SPAWN_P2,
    Config.BLOCK_SPAWN_P3,
    Config.BLOCK_SPAWN_P4,
    Config.BLOCK_SPAWN_P5,
    Config.BLOCK_SPAWN_P6,
}

--- 获取玩家颜色（超过 6 人时循环复用）
---@param index number 玩家编号 1~N
---@return Color
function Config.GetPlayerColor(index)
    return Config.PlayerColors[(index - 1) % #Config.PlayerColors + 1]
end

--- 获取玩家描边颜色（超过 6 人时循环复用）
---@param index number
---@return Color
function Config.GetPlayerOutlineColor(index)
    return Config.PlayerOutlineColors[(index - 1) % #Config.PlayerOutlineColors + 1]
end

--- 获取玩家自发光颜色（超过 6 人时循环复用）
---@param index number
---@return Color
function Config.GetPlayerEmissive(index)
    return Config.PlayerEmissive[(index - 1) % #Config.PlayerEmissive + 1]
end

--- 判断方块类型是否为出生点（含旧版和 P1-P6）
---@param blockType number
---@return boolean
function Config.IsSpawnBlock(blockType)
    return blockType == Config.BLOCK_SPAWN
        or blockType == Config.BLOCK_SPAWN_P1
        or blockType == Config.BLOCK_SPAWN_P2
        or blockType == Config.BLOCK_SPAWN_P3
        or blockType == Config.BLOCK_SPAWN_P4
        or blockType == Config.BLOCK_SPAWN_P5
        or blockType == Config.BLOCK_SPAWN_P6
end

--- 判断方块类型是否为检查点
---@param blockType number
---@return boolean
function Config.IsCheckpoint(blockType)
    return blockType == Config.BLOCK_CHECKPOINT
end

return Config

-- ============================================================================
-- CharacterClass.lua - 职业定义模块
-- 定义所有可选职业的属性覆盖、描述和专属外观配色
-- ============================================================================

local Config = require("Config")

local CharacterClass = {}

-- ============================================================================
-- 职业列表
-- ============================================================================

---@class ClassDef
---@field id number 职业 ID（1~6）
---@field name string 职业名称
---@field desc string 一句话描述
---@field price number 购买价格（0 = 免费/默认）
---@field maxJumps number 最大跳跃次数
---@field energyChargeTime number 能量充满时间（秒）
---@field dashCooldown number 冲刺冷却（秒）
---@field dashSpeed number 冲刺速度
---@field dashDuration number 冲刺持续时间
---@field dashCount number 单次冷却内可冲刺次数
---@field slamStunDuration number 下砸眩晕时间（秒）
---@field explosionChargeTime number 蓄力到最大的时间（秒）
---@field jumpSpeed number 跳跃初速度
---@field bodyColor Color 身体颜色
---@field outlineColor Color 描边颜色
---@field emissiveColor Color 自发光颜色
---@field icon string 图标 emoji

local classes = {
    -- 1. 默认角色（免费）
    {
        id    = 1,
        name  = "街头小子",
        desc  = "均衡全面，入门之选",
        price = 0,
        icon  = "👊",
        -- 属性：全部使用 Config 默认值
        maxJumps           = Config.MaxJumps,           -- 2
        energyChargeTime   = Config.EnergyChargeTime,   -- 16.0
        dashCooldown       = Config.DashCooldown,       -- 2.0
        dashSpeed          = Config.DashSpeed,           -- 25.0
        dashDuration       = Config.DashDuration,        -- 0.22
        dashCount          = 1,
        slamStunDuration   = Config.SlamStunDuration,    -- 1.0
        explosionChargeTime = Config.ExplosionChargeTime, -- 2.5
        jumpSpeed          = Config.JumpSpeed,           -- 14.0
        -- 外观：番茄红（复用默认 P1 色）
        bodyColor    = Color(0.95, 0.25, 0.20, 1.0),
        outlineColor = Color(0.50, 0.10, 0.08, 1.0),
        emissiveColor = Color(0.15, 0.03, 0.02),
    },

    -- 2. 三段跳
    {
        id    = 2,
        name  = "弹跳忍者",
        desc  = "可以三段跳！在空中更自由",
        price = 600,
        icon  = "🦘",
        maxJumps           = 3,                          -- ★ 核心：三段跳
        energyChargeTime   = Config.EnergyChargeTime,
        dashCooldown       = Config.DashCooldown,
        dashSpeed          = Config.DashSpeed,
        dashDuration       = Config.DashDuration,
        dashCount          = 1,
        slamStunDuration   = Config.SlamStunDuration,
        explosionChargeTime = Config.ExplosionChargeTime,
        jumpSpeed          = Config.JumpSpeed,
        -- 外观：薄荷绿
        bodyColor    = Color(0.18, 0.92, 0.65, 1.0),
        outlineColor = Color(0.06, 0.45, 0.32, 1.0),
        emissiveColor = Color(0.03, 0.15, 0.10),
    },

    -- 3. 能量积累快 40%
    {
        id    = 3,
        name  = "能量达人",
        desc  = "能量回复速度+40%",
        price = 500,
        icon  = "⚡",
        maxJumps           = Config.MaxJumps,
        energyChargeTime   = Config.EnergyChargeTime * 0.6, -- ★ 核心：充能快 40%
        dashCooldown       = Config.DashCooldown,
        dashSpeed          = Config.DashSpeed,
        dashDuration       = Config.DashDuration,
        dashCount          = 1,
        slamStunDuration   = Config.SlamStunDuration,
        explosionChargeTime = Config.ExplosionChargeTime,
        jumpSpeed          = Config.JumpSpeed,
        -- 外观：电光蓝
        bodyColor    = Color(0.20, 0.65, 1.00, 1.0),
        outlineColor = Color(0.06, 0.28, 0.55, 1.0),
        emissiveColor = Color(0.03, 0.10, 0.18),
    },

    -- 4. 连冲两次
    {
        id    = 4,
        name  = "疾风突击",
        desc  = "冲刺不冷却，连冲两次！",
        price = 700,
        icon  = "💨",
        maxJumps           = Config.MaxJumps,
        energyChargeTime   = Config.EnergyChargeTime,
        dashCooldown       = Config.DashCooldown,
        dashSpeed          = Config.DashSpeed,
        dashDuration       = Config.DashDuration,
        dashCount          = 2,                           -- ★ 核心：双冲
        slamStunDuration   = Config.SlamStunDuration,
        explosionChargeTime = Config.ExplosionChargeTime,
        jumpSpeed          = Config.JumpSpeed,
        -- 外观：暖橙
        bodyColor    = Color(1.00, 0.62, 0.18, 1.0),
        outlineColor = Color(0.55, 0.28, 0.05, 1.0),
        emissiveColor = Color(0.18, 0.08, 0.02),
    },

    -- 5. 砸晕时间翻倍
    {
        id    = 5,
        name  = "重锤战士",
        desc  = "下砸晕眩时间翻倍！",
        price = 600,
        icon  = "🔨",
        maxJumps           = Config.MaxJumps,
        energyChargeTime   = Config.EnergyChargeTime,
        dashCooldown       = Config.DashCooldown,
        dashSpeed          = Config.DashSpeed,
        dashDuration       = Config.DashDuration,
        dashCount          = 1,
        slamStunDuration   = Config.SlamStunDuration * 2, -- ★ 核心：眩晕翻倍
        explosionChargeTime = Config.ExplosionChargeTime,
        jumpSpeed          = Config.JumpSpeed,
        -- 外观：亮紫
        bodyColor    = Color(0.75, 0.28, 0.95, 1.0),
        outlineColor = Color(0.35, 0.10, 0.48, 1.0),
        emissiveColor = Color(0.12, 0.04, 0.16),
    },

    -- 6. 蓄力速度更快
    {
        id    = 6,
        name  = "爆破专家",
        desc  = "蓄力速度+50%，更快满爆！",
        price = 700,
        icon  = "💥",
        maxJumps           = Config.MaxJumps,
        energyChargeTime   = Config.EnergyChargeTime,
        dashCooldown       = Config.DashCooldown,
        dashSpeed          = Config.DashSpeed,
        dashDuration       = Config.DashDuration,
        dashCount          = 1,
        slamStunDuration   = Config.SlamStunDuration,
        explosionChargeTime = Config.ExplosionChargeTime * 0.5, -- ★ 核心：蓄力快 50%
        jumpSpeed          = Config.JumpSpeed,
        -- 外观：熔岩橙红（与街头小子区分：偏橙黄、高亮度）
        bodyColor    = Color(1.00, 0.45, 0.08, 1.0),
        outlineColor = Color(0.55, 0.15, 0.02, 1.0),
        emissiveColor = Color(0.25, 0.08, 0.01),
    },
}

-- ============================================================================
-- 公共 API
-- ============================================================================

--- 获取所有职业定义
---@return ClassDef[]
function CharacterClass.GetAll()
    return classes
end

--- 根据 ID 获取职业定义
---@param id number
---@return ClassDef|nil
function CharacterClass.GetById(id)
    for _, c in ipairs(classes) do
        if c.id == id then return c end
    end
    return nil
end

--- 获取职业数量
---@return number
function CharacterClass.GetCount()
    return #classes
end

--- 获取默认（免费）职业 ID
---@return number
function CharacterClass.GetDefaultId()
    return 1
end

--- 将职业属性写入玩家数据表（在 Player.Create 中调用）
--- 只覆盖战斗属性，不改变 Player 的其他字段
---@param playerData table 玩家实例 table (p)
---@param classId number
function CharacterClass.ApplyToPlayer(playerData, classId)
    local def = CharacterClass.GetById(classId)
    if not def then
        def = classes[1]  -- fallback 到默认
    end
    playerData.classId            = def.id
    playerData.className          = def.name
    playerData.maxJumps           = def.maxJumps
    playerData.energyChargeTime   = def.energyChargeTime
    playerData.dashCooldownMax    = def.dashCooldown
    playerData.dashSpeed          = def.dashSpeed
    playerData.dashDuration       = def.dashDuration
    playerData.dashCount          = def.dashCount
    playerData.dashesUsed         = 0  -- 当前冷却周期内已用冲刺次数
    playerData.slamStunDuration   = def.slamStunDuration
    playerData.explosionChargeTime = def.explosionChargeTime
    playerData.jumpSpeed          = def.jumpSpeed
end

--- 获取职业专属颜色（用于覆盖 Config.GetPlayerColor）
---@param classId number
---@return Color bodyColor
---@return Color outlineColor
---@return Color emissiveColor
function CharacterClass.GetColors(classId)
    local def = CharacterClass.GetById(classId)
    if not def then def = classes[1] end
    return def.bodyColor, def.outlineColor, def.emissiveColor
end

return CharacterClass

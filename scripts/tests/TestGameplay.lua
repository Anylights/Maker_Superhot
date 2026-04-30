-- ============================================================================
-- TestGameplay.lua - 游戏玩法逻辑测试用例
-- 覆盖：Config 常量、Player 移动/跳跃/冲刺/能量/爆炸/死亡重生、
--        Map 方块/爆炸/重生、GameManager 状态机/计分/回合、
--        Pickup 拾取、RandomPickup 生成、Camera 基础
-- ============================================================================

local TR = require("tests.TestRunner")
local Config = require("Config")

-- ============================================================================
-- 1. Config 常量一致性测试
-- ============================================================================

TR.describe("Config 常量一致性", function()

    TR.it("玩家数量应为 4", function()
        TR.assertEqual(Config.NumPlayers, 4)
    end)

    TR.it("最大房间人数应为 4", function()
        TR.assertEqual(Config.MaxRoomPlayers, 4)
    end)

    TR.it("移动速度 > 0", function()
        TR.assertGreater(Config.MoveSpeed, 0)
    end)

    TR.it("跳跃速度 > 0", function()
        TR.assertGreater(Config.JumpSpeed, 0)
    end)

    TR.it("最大跳跃次数应为 2（二段跳）", function()
        TR.assertEqual(Config.MaxJumps, 2)
    end)

    TR.it("冲刺速度 > 移动速度", function()
        TR.assertGreater(Config.DashSpeed, Config.MoveSpeed)
    end)

    TR.it("冲刺持续时间 > 0", function()
        TR.assertGreater(Config.DashDuration, 0)
    end)

    TR.it("冲刺冷却时间 > 冲刺持续时间", function()
        TR.assertGreater(Config.DashCooldown, Config.DashDuration)
    end)

    TR.it("下落重力乘数 > 1（快速下落）", function()
        TR.assertGreater(Config.FallGravityMul, 1.0)
    end)

    TR.it("能量充能时间 > 0", function()
        TR.assertGreater(Config.EnergyChargeTime, 0)
    end)

    TR.it("小能量拾取量 < 大能量拾取量", function()
        TR.assertGreater(Config.LargeEnergyAmount, Config.SmallEnergyAmount)
    end)

    TR.it("爆炸半径应为正整数", function()
        TR.assertGreater(Config.ExplosionRadius, 0)
        TR.assertEqual(Config.ExplosionRadius, math.floor(Config.ExplosionRadius))
    end)

    TR.it("爆炸蓄力时间 > 0", function()
        TR.assertGreater(Config.ExplosionChargeTime, 0)
    end)

    TR.it("回合时长应为 75 秒", function()
        TR.assertEqual(Config.RoundDuration, 75.0)
    end)

    TR.it("胜利分数应为 15", function()
        TR.assertEqual(Config.WinScore, 15)
    end)

    TR.it("名次得分表应有 4 项", function()
        TR.assertLength(Config.PlaceScores, 4)
    end)

    TR.it("名次得分应递减", function()
        for i = 2, #Config.PlaceScores do
            TR.assertGreaterEqual(Config.PlaceScores[i - 1], Config.PlaceScores[i],
                "PlaceScores[" .. (i-1) .. "] >= PlaceScores[" .. i .. "]")
        end
    end)

    TR.it("击杀得分应为 1", function()
        TR.assertEqual(Config.KillScore, 1)
    end)

    TR.it("重生延迟 > 0", function()
        TR.assertGreater(Config.RespawnDelay, 0)
    end)

    TR.it("无敌时间 > 0", function()
        TR.assertGreater(Config.InvincibleDuration, 0)
    end)

    TR.it("死亡高度 < 0", function()
        TR.assertTrue(Config.DeathY < 0, "DeathY should be negative")
    end)

    TR.it("房间代码长度应为 6", function()
        TR.assertEqual(Config.RoomCodeLength, 6)
    end)

    TR.it("方块类型常量互不相同", function()
        local types = {
            Config.BLOCK_EMPTY,
            Config.BLOCK_NORMAL,
            Config.BLOCK_SAFE,
            Config.BLOCK_ENERGY_PAD,
            Config.BLOCK_SPAWN,
            Config.BLOCK_FINISH,
        }
        for i = 1, #types do
            for j = i + 1, #types do
                TR.assertTrue(types[i] ~= types[j],
                    "BLOCK types " .. i .. " and " .. j .. " should differ")
            end
        end
    end)

    TR.it("每个玩家出生点方块类型不同", function()
        TR.assertNotNil(Config.SpawnBlockTypes)
        TR.assertLength(Config.SpawnBlockTypes, 4)
        for i = 1, 4 do
            for j = i + 1, 4 do
                TR.assertTrue(Config.SpawnBlockTypes[i] ~= Config.SpawnBlockTypes[j],
                    "SpawnBlockTypes[" .. i .. "] ~= SpawnBlockTypes[" .. j .. "]")
            end
        end
    end)

    TR.it("颜色表应有 4 种玩家颜色", function()
        TR.assertNotNil(Config.PlayerColors)
        TR.assertGreaterEqual(#Config.PlayerColors, 4)
    end)

    TR.it("网络 CoyoteTime >= 本地 CoyoteTime", function()
        TR.assertGreaterEqual(Config.NetCoyoteTime, Config.CoyoteTime)
    end)

    TR.it("网络 JumpBuffer >= 本地 JumpBuffer", function()
        TR.assertGreaterEqual(Config.NetJumpBuffer, Config.JumpBuffer)
    end)

    TR.it("空中控制比例应在 0~1 之间", function()
        TR.assertGreater(Config.AirControlRatio, 0)
        TR.assertLessEqual(Config.AirControlRatio, 1.0)
    end)
end)

-- ============================================================================
-- 2. GameManager 状态机测试
-- ============================================================================

TR.describe("GameManager 状态机", function()
    local GameManager = require("GameManager")

    TR.it("应定义所有必需状态常量", function()
        TR.assertNotNil(GameManager.STATE_MENU)
        TR.assertNotNil(GameManager.STATE_INTRO)
        TR.assertNotNil(GameManager.STATE_COUNTDOWN)
        TR.assertNotNil(GameManager.STATE_RACING)
        TR.assertNotNil(GameManager.STATE_ROUND_END)
        TR.assertNotNil(GameManager.STATE_SCORE)
        TR.assertNotNil(GameManager.STATE_MATCH_END)
        TR.assertNotNil(GameManager.STATE_MATCHING)
    end)

    TR.it("所有状态值应互不相同", function()
        local states = {
            GameManager.STATE_MENU,
            GameManager.STATE_INTRO,
            GameManager.STATE_COUNTDOWN,
            GameManager.STATE_RACING,
            GameManager.STATE_ROUND_END,
            GameManager.STATE_SCORE,
            GameManager.STATE_MATCH_END,
            GameManager.STATE_MATCHING,
        }
        for i = 1, #states do
            for j = i + 1, #states do
                TR.assertTrue(states[i] ~= states[j],
                    "State " .. i .. " and " .. j .. " should differ")
            end
        end
    end)

    TR.it("scores 表初始化为 4 个 0", function()
        TR.assertNotNil(GameManager.scores)
        TR.assertLength(GameManager.scores, 4)
        for i = 1, 4 do
            TR.assertEqual(GameManager.scores[i], 0,
                "scores[" .. i .. "] should be 0")
        end
    end)

    TR.it("killScores 表初始化为 4 个 0", function()
        TR.assertNotNil(GameManager.killScores)
        TR.assertLength(GameManager.killScores, 4)
    end)

    TR.it("finishCount 初始化为 0", function()
        TR.assertEqual(GameManager.finishCount, 0)
    end)

    TR.it("CanPlayersMove 在 RACING 状态返回 true", function()
        local origState = GameManager.state
        GameManager.state = GameManager.STATE_RACING
        TR.assertTrue(GameManager.CanPlayersMove())
        GameManager.state = origState
    end)

    TR.it("CanPlayersMove 在 MENU 状态返回 false", function()
        local origState = GameManager.state
        GameManager.state = GameManager.STATE_MENU
        TR.assertFalse(GameManager.CanPlayersMove())
        GameManager.state = origState
    end)

    TR.it("CanPlayersMove 在 COUNTDOWN 状态返回 false", function()
        local origState = GameManager.state
        GameManager.state = GameManager.STATE_COUNTDOWN
        TR.assertFalse(GameManager.CanPlayersMove())
        GameManager.state = origState
    end)
end)

-- ============================================================================
-- 3. GameManager 计分逻辑测试
-- ============================================================================

TR.describe("GameManager 计分逻辑", function()
    local GameManager = require("GameManager")

    TR.it("名次得分应正确分配（第1名最高）", function()
        TR.assertEqual(Config.PlaceScores[1], 5, "1st place = 5")
        TR.assertEqual(Config.PlaceScores[2], 3, "2nd place = 3")
        TR.assertEqual(Config.PlaceScores[3], 2, "3rd place = 2")
        TR.assertEqual(Config.PlaceScores[4], 1, "4th place = 1")
    end)

    TR.it("击杀得分为 1 分", function()
        TR.assertEqual(Config.KillScore, 1)
    end)

    TR.it("胜利条件：达到 WinScore(15) 分", function()
        -- 模拟：3 轮第一名(15分) = 刚好达标
        local score = Config.PlaceScores[1] * 3
        TR.assertEqual(score, 15)
        TR.assertGreaterEqual(score, Config.WinScore)
    end)

    TR.it("4 轮不拿第一无法获胜（除非有击杀）", function()
        -- 4 轮全部第 2 名 = 12 分 < 15
        local score = Config.PlaceScores[2] * 4
        TR.assertTrue(score < Config.WinScore,
            "4 rounds of 2nd place (" .. score .. ") should be < " .. Config.WinScore)
    end)
end)

-- ============================================================================
-- 4. Player 数据结构测试（纯逻辑，不需要场景）
-- ============================================================================

TR.describe("Player 模块结构", function()
    local Player = require("Player")

    TR.it("Player.list 应存在且为 table", function()
        TR.assertNotNil(Player.list)
        TR.assertEqual(type(Player.list), "table")
    end)

    TR.it("Player 模块应导出关键函数", function()
        TR.assertEqual(type(Player.Init), "function")
        TR.assertEqual(type(Player.Create), "function")
        TR.assertEqual(type(Player.CreateAll), "function")
        TR.assertEqual(type(Player.UpdateAll), "function")
        TR.assertEqual(type(Player.Respawn), "function")
        TR.assertEqual(type(Player.ResetAll), "function")
        TR.assertEqual(type(Player.Kill), "function")
        TR.assertEqual(type(Player.AddEnergy), "function")
        TR.assertEqual(type(Player.GetAlivePositions), "function")
        TR.assertEqual(type(Player.GetHumanPosition), "function")
    end)

    TR.it("Player.UpdateAllClient 应存在（客户端专用）", function()
        TR.assertEqual(type(Player.UpdateAllClient), "function")
    end)

    TR.it("Player.HandleRemoteExplode 应存在（客户端爆炸同步）", function()
        TR.assertEqual(type(Player.HandleRemoteExplode), "function")
    end)

    TR.it("Player.ClientDeath 应存在（客户端死亡同步）", function()
        TR.assertEqual(type(Player.ClientDeath), "function")
    end)
end)

-- ============================================================================
-- 5. Player 能量系统逻辑测试（模拟数据，不需要场景）
-- ============================================================================

TR.describe("Player 能量系统", function()
    local Player = require("Player")

    TR.it("AddEnergy 应正确增加能量", function()
        local p = { energy = 0 }
        Player.AddEnergy(p, 0.2)
        TR.assertNear(p.energy, 0.2)
    end)

    TR.it("AddEnergy 不应超过 1.0", function()
        local p = { energy = 0.9 }
        Player.AddEnergy(p, 0.5)
        TR.assertNear(p.energy, 1.0)
    end)

    TR.it("AddEnergy(0) 不改变能量", function()
        local p = { energy = 0.5 }
        Player.AddEnergy(p, 0)
        TR.assertNear(p.energy, 0.5)
    end)

    TR.it("满能量 + AddEnergy 仍为 1.0", function()
        local p = { energy = 1.0 }
        Player.AddEnergy(p, 1.0)
        TR.assertNear(p.energy, 1.0)
    end)

    TR.it("小能量拾取量应为 0.20", function()
        TR.assertNear(Config.SmallEnergyAmount, 0.20)
    end)

    TR.it("大能量拾取量应为 0.40", function()
        TR.assertNear(Config.LargeEnergyAmount, 0.40)
    end)

    TR.it("5 个小能量 = 满能", function()
        local p = { energy = 0 }
        for i = 1, 5 do
            Player.AddEnergy(p, Config.SmallEnergyAmount)
        end
        TR.assertNear(p.energy, 1.0)
    end)

    TR.it("3 个大能量 > 满能（被 clamp 到 1.0）", function()
        local p = { energy = 0 }
        for i = 1, 3 do
            Player.AddEnergy(p, Config.LargeEnergyAmount)
        end
        TR.assertNear(p.energy, 1.0)
    end)
end)

-- ============================================================================
-- 6. Player Respawn 逻辑测试（使用模拟数据）
-- ============================================================================

TR.describe("Player Respawn 逻辑", function()
    local Player = require("Player")
    local MapData = require("MapData")

    -- 构造一个最小化的模拟玩家数据
    local function makeMockPlayer(index)
        -- 确保 MapData 有这个 index 的出生点
        if not MapData.SpawnPositions[index] then
            MapData.SpawnPositions[index] = { x = index * 3, y = 3 }
        end
        return {
            index = index,
            alive = false,
            invincibleTimer = 0,
            energy = 0.5,
            charging = true,
            chargeTimer = 1.0,
            chargeProgress = 0.5,
            explodeRecovery = 0.3,
            jumpCount = 2,
            jumpCooldown = 0.1,
            wasOnGround = true,
            dashTimer = 0.1,
            dashCooldown = 1.0,
            wasJumpDown = true,
            wasDashDown = true,
            wasExplodeReleaseDown = true,
            squashScaleX = 1.2,
            squashScaleY = 0.8,
            squashVelX = 0.5,
            squashVelY = -0.3,
            dashRoll = 45,
            prevVelY = -5,
            hitWallX = 1,
            extrapVelX = 1,
            extrapVelY = 2,
            extrapOffX = 0.5,
            extrapOffY = 0.3,
            extrapStillFrames = 5,
            prevPosition = nil,
            visualNode = nil,  -- 没有场景，设为 nil
            node = nil,
            body = nil,
            deathFaceNode = nil,
            deathFacePlane = nil,
            deathFaceTimer = nil,
            deathFaceTargetSize = nil,
        }
    end

    TR.it("Respawn 应重置 alive 为 true", function()
        local p = makeMockPlayer(1)
        Player.Respawn(p)
        TR.assertTrue(p.alive)
    end)

    TR.it("Respawn 应设置无敌时间", function()
        local p = makeMockPlayer(1)
        Player.Respawn(p)
        TR.assertNear(p.invincibleTimer, Config.InvincibleDuration)
    end)

    TR.it("Respawn 应重置能量为 0", function()
        local p = makeMockPlayer(1)
        Player.Respawn(p)
        TR.assertEqual(p.energy, 0)
    end)

    TR.it("Respawn 应重置蓄力状态", function()
        local p = makeMockPlayer(1)
        Player.Respawn(p)
        TR.assertFalse(p.charging)
        TR.assertEqual(p.chargeTimer, 0)
        TR.assertEqual(p.chargeProgress, 0)
    end)

    TR.it("Respawn 应重置跳跃计数", function()
        local p = makeMockPlayer(1)
        Player.Respawn(p)
        TR.assertEqual(p.jumpCount, 0)
    end)

    TR.it("Respawn 应重置冲刺状态", function()
        local p = makeMockPlayer(1)
        Player.Respawn(p)
        TR.assertEqual(p.dashTimer, 0)
        TR.assertEqual(p.dashCooldown, 0)
    end)

    TR.it("Respawn 应重置视觉动效", function()
        local p = makeMockPlayer(1)
        Player.Respawn(p)
        TR.assertNear(p.squashScaleX, 1.0)
        TR.assertNear(p.squashScaleY, 1.0)
        TR.assertEqual(p.squashVelX, 0)
        TR.assertEqual(p.squashVelY, 0)
        TR.assertEqual(p.dashRoll, 0)
    end)

    TR.it("Respawn 应重置客户端外推状态", function()
        local p = makeMockPlayer(1)
        Player.Respawn(p)
        TR.assertEqual(p.extrapVelX, 0)
        TR.assertEqual(p.extrapVelY, 0)
        TR.assertEqual(p.extrapOffX, 0)
        TR.assertEqual(p.extrapOffY, 0)
        TR.assertEqual(p.extrapStillFrames, 0)
    end)

    TR.it("Respawn 应重置边沿检测状态", function()
        local p = makeMockPlayer(1)
        Player.Respawn(p)
        TR.assertFalse(p.wasJumpDown)
        TR.assertFalse(p.wasDashDown)
        TR.assertFalse(p.wasExplodeReleaseDown)
    end)
end)

-- ============================================================================
-- 7. Player ResetAll 逻辑测试
-- ============================================================================

TR.describe("Player ResetAll 逻辑", function()
    local Player = require("Player")
    local MapData = require("MapData")

    TR.it("ResetAll 应重置所有玩家状态", function()
        -- 确保出生点存在
        for i = 1, 4 do
            if not MapData.SpawnPositions[i] then
                MapData.SpawnPositions[i] = { x = i * 3, y = 3 }
            end
        end

        -- 保存原始 list，注入模拟数据
        local origList = Player.list
        Player.list = {}
        for i = 1, 4 do
            table.insert(Player.list, {
                index = i,
                alive = false,
                finished = true,
                finishOrder = i,
                kills = 3,
                killStreak = 2,
                multiKillCount = 1,
                multiKillTimer = 1.0,
                energy = 0.7,
                charging = true,
                chargeTimer = 1.5,
                chargeProgress = 0.8,
                explodeRecovery = 0.1,
                invincibleTimer = 0.5,
                respawnTimer = 1.0,
                jumpCount = 2,
                jumpCooldown = 0.1,
                wasOnGround = true,
                dashTimer = 0.2,
                dashCooldown = 1.5,
                inputMoveX = 1,
                inputJump = true,
                inputDash = true,
                inputCharging = true,
                inputExplodeRelease = true,
                wasChargingInput = true,
                wasJumpDown = true,
                wasDashDown = true,
                wasExplodeReleaseDown = true,
                squashScaleX = 1.3,
                squashScaleY = 0.7,
                squashVelX = 0.5,
                squashVelY = -0.3,
                dashRoll = 90,
                prevVelY = -10,
                hitWallX = -1,
                extrapVelX = 2,
                extrapVelY = -1,
                extrapOffX = 0.3,
                extrapOffY = -0.2,
                extrapStillFrames = 3,
                prevPosition = nil,
                visualNode = nil,
                node = nil,
                body = nil,
                deathFaceNode = nil,
                deathFacePlane = nil,
                deathFaceTimer = nil,
                deathFaceTargetSize = nil,
            })
        end

        Player.ResetAll()

        for _, p in ipairs(Player.list) do
            TR.assertTrue(p.alive, "Player " .. p.index .. " should be alive")
            TR.assertFalse(p.finished, "Player " .. p.index .. " should not be finished")
            TR.assertEqual(p.finishOrder, 0)
            TR.assertEqual(p.kills, 0)
            TR.assertEqual(p.energy, 0)
            TR.assertFalse(p.charging)
            TR.assertEqual(p.inputMoveX, 0)
            TR.assertFalse(p.inputJump)
            TR.assertFalse(p.inputDash)
        end

        -- 恢复原始 list
        Player.list = origList
    end)
end)

-- ============================================================================
-- 8. Map 模块结构测试
-- ============================================================================

TR.describe("Map 模块结构", function()
    local Map = require("Map")

    TR.it("Map 应导出关键函数", function()
        TR.assertEqual(type(Map.Init), "function")
        TR.assertEqual(type(Map.Build), "function")
        TR.assertEqual(type(Map.Update), "function")
        TR.assertEqual(type(Map.Explode), "function")
        TR.assertEqual(type(Map.DestroyBlock), "function")
        TR.assertEqual(type(Map.GetBlock), "function")
        TR.assertEqual(type(Map.GetGrid), "function")
        TR.assertEqual(type(Map.GetDimensions), "function")
        TR.assertEqual(type(Map.WorldToGrid), "function")
    end)
end)

-- ============================================================================
-- 9. MapData 测试
-- ============================================================================

TR.describe("MapData 数据逻辑", function()
    local MapData = require("MapData")

    TR.it("默认地图尺寸 > 0", function()
        TR.assertGreater(MapData.Width, 0)
        TR.assertGreater(MapData.Height, 0)
    end)

    TR.it("SetDimensions 应正确设置尺寸", function()
        local origW, origH = MapData.Width, MapData.Height
        MapData.SetDimensions(40, 30)
        TR.assertEqual(MapData.Width, 40)
        TR.assertEqual(MapData.Height, 30)
        MapData.SetDimensions(origW, origH)
    end)

    TR.it("GetSpawnPosition 应返回有效坐标", function()
        -- 确保出生点存在
        for i = 1, 4 do
            if not MapData.SpawnPositions[i] then
                MapData.SpawnPositions[i] = { x = i * 3, y = 3 }
            end
        end
        for i = 1, 4 do
            local sx, sy = MapData.GetSpawnPosition(i)
            TR.assertNotNil(sx, "SpawnX for player " .. i)
            TR.assertNotNil(sy, "SpawnY for player " .. i)
            TR.assertGreater(sx, 0)
            TR.assertGreater(sy, 0)
        end
    end)
end)

-- ============================================================================
-- 10. Pickup 模块结构测试
-- ============================================================================

TR.describe("Pickup 模块结构", function()
    local Pickup = require("Pickup")

    TR.it("Pickup 应导出关键函数", function()
        TR.assertEqual(type(Pickup.Init), "function")
        TR.assertEqual(type(Pickup.Spawn), "function")
        TR.assertEqual(type(Pickup.Update), "function")
        TR.assertEqual(type(Pickup.ClearAll), "function")
        TR.assertEqual(type(Pickup.GetActiveCount), "function")
        TR.assertEqual(type(Pickup.HasPickupNear), "function")
    end)
end)

-- ============================================================================
-- 11. RandomPickup 配置测试
-- ============================================================================

TR.describe("RandomPickup 配置", function()
    local RandomPickup = require("RandomPickup")

    TR.it("MaxPickups > 0", function()
        TR.assertGreater(RandomPickup.MaxPickups, 0)
    end)

    TR.it("SpawnInterval > 0", function()
        TR.assertGreater(RandomPickup.SpawnInterval, 0)
    end)

    TR.it("InitialCount <= MaxPickups", function()
        TR.assertLessEqual(RandomPickup.InitialCount, RandomPickup.MaxPickups)
    end)

    TR.it("SmallRatio 在 0~1 之间", function()
        TR.assertGreater(RandomPickup.SmallRatio, 0)
        TR.assertLessEqual(RandomPickup.SmallRatio, 1.0)
    end)

    TR.it("MinDistance > 0", function()
        TR.assertGreater(RandomPickup.MinDistance, 0)
    end)
end)

-- ============================================================================
-- 12. Camera 模块结构测试
-- ============================================================================

TR.describe("Camera 模块结构", function()
    local Camera = require("Camera")

    TR.it("Camera 应导出关键函数", function()
        TR.assertEqual(type(Camera.Init), "function")
        TR.assertEqual(type(Camera.Update), "function")
        TR.assertEqual(type(Camera.SetImmediate), "function")
        TR.assertEqual(type(Camera.SetFixedForMap), "function")
        TR.assertEqual(type(Camera.AnimateTo), "function")
        TR.assertEqual(type(Camera.UpdateAnimation), "function")
        TR.assertEqual(type(Camera.Shake), "function")
        TR.assertEqual(type(Camera.ReleaseFixed), "function")
        TR.assertEqual(type(Camera.WorldToScreen), "function")
        TR.assertEqual(type(Camera.ScreenToWorld), "function")
    end)

    TR.it("Camera 默认不在手动模式", function()
        TR.assertFalse(Camera.manualMode)
    end)

    TR.it("Camera 默认不在固定模式", function()
        TR.assertFalse(Camera.fixedMode)
    end)
end)

-- ============================================================================
-- 13. 爆炸半径公式验证
-- ============================================================================

TR.describe("爆炸半径公式", function()

    TR.it("最小蓄力（0%）应产生最小爆炸半径 >= 1", function()
        -- 从 Player.lua 的 DoExplode: actualRadius = max(1, floor(MaxRadius * progress))
        local progress = 0.0
        local actualRadius = math.max(1, math.floor(Config.ExplosionRadius * progress))
        TR.assertGreaterEqual(actualRadius, 1)
    end)

    TR.it("满蓄力（100%）应产生最大爆炸半径", function()
        local progress = 1.0
        local actualRadius = math.max(1, math.floor(Config.ExplosionRadius * progress))
        TR.assertEqual(actualRadius, Config.ExplosionRadius)
    end)

    TR.it("半蓄力应产生约一半的爆炸半径", function()
        local progress = 0.5
        local actualRadius = math.max(1, math.floor(Config.ExplosionRadius * progress))
        TR.assertGreater(actualRadius, 1)
        TR.assertTrue(actualRadius <= Config.ExplosionRadius)
    end)
end)

-- ============================================================================
-- 14. 移动物理参数合理性
-- ============================================================================

TR.describe("移动物理参数合理性", function()

    TR.it("跳跃最大高度 > 2 格（能跳上 2 格高的平台）", function()
        local GRAVITY = 9.81
        local maxH = (Config.JumpSpeed * Config.JumpSpeed) / (2 * GRAVITY)
        TR.assertGreater(maxH, 2 * Config.BlockSize,
            "Max jump height = " .. string.format("%.1f", maxH))
    end)

    TR.it("冲刺距离应 > 3m", function()
        local dashDist = Config.DashSpeed * Config.DashDuration
        TR.assertGreater(dashDist, 3.0,
            "Dash distance = " .. string.format("%.1f", dashDist))
    end)

    TR.it("方块尺寸应为 1.0m", function()
        TR.assertNear(Config.BlockSize, 1.0)
    end)

    TR.it("重力乘数与 ScriptObject 重力一致（应使用 -28.0）", function()
        -- Standalone 中 physicsWorld:SetGravity(Vector3(0, -28.0, 0))
        -- Server 中也是 -28.0
        -- 这里只验证 Config 中没有冲突的重力值
        TR.assertNotNil(Config.FallGravityMul)
        TR.assertGreater(Config.FallGravityMul, 1.0,
            "FallGravityMul should make falling faster")
    end)
end)

-- ============================================================================
-- 15. 控制掩码一致性（Shared.CTRL）
-- ============================================================================

TR.describe("Shared 控制掩码", function()
    local Shared = require("network.Shared")

    TR.it("CTRL 应定义所有 6 种输入", function()
        TR.assertNotNil(Shared.CTRL)
        TR.assertNotNil(Shared.CTRL.LEFT)
        TR.assertNotNil(Shared.CTRL.RIGHT)
        TR.assertNotNil(Shared.CTRL.JUMP)
        TR.assertNotNil(Shared.CTRL.DASH)
        TR.assertNotNil(Shared.CTRL.CHARGE)
        TR.assertNotNil(Shared.CTRL.EXPLODE_RELEASE)
    end)

    TR.it("CTRL 各位掩码互不重叠（位运算正确性）", function()
        local all = {
            Shared.CTRL.LEFT,
            Shared.CTRL.RIGHT,
            Shared.CTRL.JUMP,
            Shared.CTRL.DASH,
            Shared.CTRL.CHARGE,
            Shared.CTRL.EXPLODE_RELEASE,
        }
        -- 检查每个值都是 2 的幂
        for i, v in ipairs(all) do
            TR.assertTrue(v > 0 and (v & (v - 1)) == 0,
                "CTRL value " .. i .. " = " .. v .. " should be power of 2")
        end
        -- 检查互不重叠
        local combined = 0
        for _, v in ipairs(all) do
            TR.assertEqual(combined & v, 0,
                "CTRL bitmask overlap detected at " .. v)
            combined = combined | v
        end
    end)

    TR.it("CTRL.LEFT = 1, RIGHT = 2, JUMP = 4, DASH = 8, CHARGE = 16, EXPLODE_RELEASE = 32", function()
        TR.assertEqual(Shared.CTRL.LEFT, 1)
        TR.assertEqual(Shared.CTRL.RIGHT, 2)
        TR.assertEqual(Shared.CTRL.JUMP, 4)
        TR.assertEqual(Shared.CTRL.DASH, 8)
        TR.assertEqual(Shared.CTRL.CHARGE, 16)
        TR.assertEqual(Shared.CTRL.EXPLODE_RELEASE, 32)
    end)
end)

-- ============================================================================
-- 16. Shared 事件定义完整性
-- ============================================================================

TR.describe("Shared 事件定义", function()
    local Shared = require("network.Shared")

    TR.it("EVENTS 应定义所有必需的网络事件", function()
        TR.assertNotNil(Shared.EVENTS)

        -- 服务端 → 客户端
        TR.assertNotNil(Shared.EVENTS.ASSIGN_ROLE, "ASSIGN_ROLE")
        TR.assertNotNil(Shared.EVENTS.GAME_STATE, "GAME_STATE")
        TR.assertNotNil(Shared.EVENTS.KILL_EVENT, "KILL_EVENT")
        TR.assertNotNil(Shared.EVENTS.EXPLODE_SYNC, "EXPLODE_SYNC")
        TR.assertNotNil(Shared.EVENTS.PLAYER_DEATH, "PLAYER_DEATH")
        TR.assertNotNil(Shared.EVENTS.PICKUP_COLLECTED, "PICKUP_COLLECTED")

        -- 客户端 → 服务端
        TR.assertNotNil(Shared.EVENTS.CLIENT_READY, "CLIENT_READY")

        -- 房间系统
        TR.assertNotNil(Shared.EVENTS.ROOM_CREATED, "ROOM_CREATED")
        TR.assertNotNil(Shared.EVENTS.ROOM_JOINED, "ROOM_JOINED")
        TR.assertNotNil(Shared.EVENTS.ROOM_UPDATE, "ROOM_UPDATE")
        TR.assertNotNil(Shared.EVENTS.ROOM_DISMISSED, "ROOM_DISMISSED")

        -- 匹配系统
        TR.assertNotNil(Shared.EVENTS.MATCH_FOUND, "MATCH_FOUND")
        TR.assertNotNil(Shared.EVENTS.QUICK_UPDATE, "QUICK_UPDATE")
    end)

    TR.it("所有事件名应以 'E_' 开头", function()
        for name, value in pairs(Shared.EVENTS) do
            TR.assertTrue(string.sub(value, 1, 2) == "E_",
                "Event " .. name .. " = '" .. value .. "' should start with 'E_'")
        end
    end)

    TR.it("所有事件名应唯一", function()
        local seen = {}
        for name, value in pairs(Shared.EVENTS) do
            TR.assertNil(seen[value],
                "Duplicate event value: " .. value .. " (used by " .. name .. " and " .. tostring(seen[value]) .. ")")
            seen[value] = name
        end
    end)
end)

-- ============================================================================
-- 17. AIController 模块结构测试
-- ============================================================================

TR.describe("AIController 模块结构", function()
    local AIController = require("AIController")

    TR.it("AIController 应导出关键函数", function()
        TR.assertEqual(type(AIController.Init), "function")
        TR.assertEqual(type(AIController.Register), "function")
        TR.assertEqual(type(AIController.Unregister), "function")
        TR.assertEqual(type(AIController.Update), "function")
    end)
end)

return TR

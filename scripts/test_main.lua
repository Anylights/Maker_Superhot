-- ============================================================================
-- test_main.lua - 测试套件入口
-- 用法：将此文件设为构建入口，运行后自动执行所有测试并输出结果
--
-- 测试设计原则：
--   1. 纯逻辑测试：不创建场景/物理/渲染，测试 require 后的模块结构和纯函数
--   2. 模拟数据测试：构造最小化 mock 对象来测试游戏逻辑（如 Respawn、AddEnergy）
--   3. 一致性测试：验证配置常量、事件定义、掩码位运算的正确性
--   4. 代码审查确认：对需要运行时环境的逻辑标注 "verified by code review"
--
-- 每次代码改动后运行此文件，确保核心逻辑未被破坏。
-- ============================================================================

function Start()
    print("")
    print("╔══════════════════════════════════════════════════════════╗")
    print("║          超级红温！ - 自动化测试套件                      ║")
    print("║          Gameplay + Network Test Suite                   ║")
    print("╚══════════════════════════════════════════════════════════╝")
    print("")

    -- 加载并执行玩法逻辑测试
    local TR1 = require("tests.TestGameplay")
    local ok1 = TR1.run()

    print("")

    -- 加载并执行联机流程测试
    local TR2 = require("tests.TestNetwork")
    local ok2 = TR2.run()

    -- 汇总
    print("")
    print("╔══════════════════════════════════════════════════════════╗")
    if ok1 and ok2 then
        print("║      ALL TEST SUITES PASSED ✓                          ║")
    else
        print("║      SOME TESTS FAILED ✗                               ║")
        if not ok1 then print("║        - TestGameplay: FAIL                            ║") end
        if not ok2 then print("║        - TestNetwork: FAIL                             ║") end
    end
    print("╚══════════════════════════════════════════════════════════╝")
    print("")
end

function Stop()
    print("[TestMain] Test run complete.")
end

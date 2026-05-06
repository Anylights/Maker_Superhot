-- ============================================================================
-- TestRunner.lua - 轻量级游戏内测试框架
-- 设计目标：在 UrhoX 引擎内运行，无外部依赖
-- 用法：
--   local TR = require("tests.TestRunner")
--   TR.describe("Config", function()
--       TR.it("should have correct player count", function()
--           TR.assertEqual(Config.NumPlayers, 4)
--       end)
--   end)
--   TR.run()
-- ============================================================================

local TestRunner = {}

-- 内部状态
local suites_ = {}         -- { { name, tests = { { name, fn }, ... } }, ... }
local currentSuite_ = nil  -- 当前正在注册的 suite

-- 统计
local totalTests_ = 0
local passedTests_ = 0
local failedTests_ = 0
local failedDetails_ = {}  -- { { suite, test, message }, ... }

-- ============================================================================
-- 注册 API
-- ============================================================================

--- 定义一个测试套件（可嵌套调用 it）
---@param name string 套件名称
---@param fn function 包含 it() 调用的函数
function TestRunner.describe(name, fn)
    local suite = { name = name, tests = {} }
    table.insert(suites_, suite)
    currentSuite_ = suite
    fn()
    currentSuite_ = nil
end

--- 定义一个测试用例（必须在 describe 内调用）
---@param name string 用例名称
---@param fn function 测试函数
function TestRunner.it(name, fn)
    if currentSuite_ == nil then
        error("[TestRunner] it() must be called inside describe()")
    end
    table.insert(currentSuite_.tests, { name = name, fn = fn })
end

-- ============================================================================
-- 断言 API
-- ============================================================================

--- 断言相等
function TestRunner.assertEqual(actual, expected, msg)
    if actual ~= expected then
        local detail = string.format("expected %s, got %s",
            tostring(expected), tostring(actual))
        if msg then detail = msg .. ": " .. detail end
        error(detail)
    end
end

--- 断言近似相等（浮点数）
function TestRunner.assertNear(actual, expected, epsilon, msg)
    epsilon = epsilon or 0.001
    if math.abs(actual - expected) > epsilon then
        local detail = string.format("expected ~%s (±%s), got %s",
            tostring(expected), tostring(epsilon), tostring(actual))
        if msg then detail = msg .. ": " .. detail end
        error(detail)
    end
end

--- 断言为真
function TestRunner.assertTrue(value, msg)
    if not value then
        error(msg or "expected true, got " .. tostring(value))
    end
end

--- 断言为假
function TestRunner.assertFalse(value, msg)
    if value then
        error(msg or "expected false, got " .. tostring(value))
    end
end

--- 断言不为 nil
function TestRunner.assertNotNil(value, msg)
    if value == nil then
        error(msg or "expected non-nil value")
    end
end

--- 断言为 nil
function TestRunner.assertNil(value, msg)
    if value ~= nil then
        error(msg or "expected nil, got " .. tostring(value))
    end
end

--- 断言大于
function TestRunner.assertGreater(actual, threshold, msg)
    if actual <= threshold then
        local detail = string.format("expected > %s, got %s",
            tostring(threshold), tostring(actual))
        if msg then detail = msg .. ": " .. detail end
        error(detail)
    end
end

--- 断言大于等于
function TestRunner.assertGreaterEqual(actual, threshold, msg)
    if actual < threshold then
        local detail = string.format("expected >= %s, got %s",
            tostring(threshold), tostring(actual))
        if msg then detail = msg .. ": " .. detail end
        error(detail)
    end
end

--- 断言小于等于
function TestRunner.assertLessEqual(actual, threshold, msg)
    if actual > threshold then
        local detail = string.format("expected <= %s, got %s",
            tostring(threshold), tostring(actual))
        if msg then detail = msg .. ": " .. detail end
        error(detail)
    end
end

--- 断言 table 包含某个值
function TestRunner.assertContains(tbl, value, msg)
    for _, v in ipairs(tbl) do
        if v == value then return end
    end
    error(msg or "table does not contain " .. tostring(value))
end

--- 断言 table 长度
function TestRunner.assertLength(tbl, expected, msg)
    local actual = #tbl
    if actual ~= expected then
        local detail = string.format("expected length %d, got %d", expected, actual)
        if msg then detail = msg .. ": " .. detail end
        error(detail)
    end
end

-- ============================================================================
-- 执行
-- ============================================================================

--- 运行所有已注册的测试，输出结果
---@return boolean allPassed
function TestRunner.run()
    totalTests_ = 0
    passedTests_ = 0
    failedTests_ = 0
    failedDetails_ = {}

    print("╔══════════════════════════════════════════════════════════╗")
    print("║              TEST RUNNER - 开始执行测试                  ║")
    print("╚══════════════════════════════════════════════════════════╝")
    print("")

    for _, suite in ipairs(suites_) do
        print("┌─ " .. suite.name .. " (" .. #suite.tests .. " tests)")

        for _, test in ipairs(suite.tests) do
            totalTests_ = totalTests_ + 1
            local ok, err = pcall(test.fn)
            if ok then
                passedTests_ = passedTests_ + 1
                print("│  ✓ " .. test.name)
            else
                failedTests_ = failedTests_ + 1
                print("│  ✗ " .. test.name)
                print("│    → " .. tostring(err))
                table.insert(failedDetails_, {
                    suite = suite.name,
                    test = test.name,
                    message = tostring(err),
                })
            end
        end

        print("└─")
        print("")
    end

    -- 汇总
    print("══════════════════════════════════════════════════════════")
    print(string.format("  Total: %d | Passed: %d | Failed: %d",
        totalTests_, passedTests_, failedTests_))

    if failedTests_ > 0 then
        print("")
        print("  FAILED TESTS:")
        for i, f in ipairs(failedDetails_) do
            print(string.format("    %d) [%s] %s", i, f.suite, f.test))
            print("       " .. f.message)
        end
        print("")
        print("  RESULT: FAIL ✗")
    else
        print("")
        print("  RESULT: ALL PASSED ✓")
    end
    print("══════════════════════════════════════════════════════════")

    -- 重置已注册的 suites 以支持多次运行
    suites_ = {}

    return failedTests_ == 0
end

--- 获取最后一次运行的统计
---@return number total, number passed, number failed
function TestRunner.getStats()
    return totalTests_, passedTests_, failedTests_
end

return TestRunner

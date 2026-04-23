# Postmortem：REPLICATED 节点下的视觉子节点丢失

> **日期**: 2026-04-23
> **症状**: 角色无表情/全灰/消失、道具不可见、平台逐渐消失、能量条不更新
> **结论**: 在 REPLICATED 父节点下创建本地视觉子节点（CustomGeometry / 子 Node），会与服务端节点同步发生 hash 冲突或被覆盖

---

## 1. 用户上报现象

1. 地图块全是灰的、角色也是灰的，没有表情
2. 看不到道具（不清楚是没生成还是没显示）
3. 角色每局有大概率"消失"——只剩头顶能量条，物体仍在运动
4. 平台方块随游戏进行逐个消失（碰撞体仍在）
5. 能量条不显示积攒（但服务端积攒确实在跑）
6. 角色操控明显卡顿

用户明确：**除了第 6 点是性能问题，其余 1~5 都是渲染层 bug**。

---

## 2. 诊断过程（不靠猜测，全部基于日志）

### 2.1 日志路径
- 客户端用户脚本：`/opt/log/dev/Web(MacIntel)_p_3wqd_1.0.63_user_script.log`
- 客户端引擎：`/opt/log/dev/Web(MacIntel)_p_3wqd_1.0.63_engine.log`
- 服务端用户脚本：`/opt/log/dev/server_Linux_p_3wqd_1.0.63_user_script.log`
- 服务端引擎：`/opt/log/dev/server_Linux_p_3wqd_1.0.63_engine.log`

> ⚠️ Maker 沙箱用户**无法在游戏内看到日志**，所有诊断必须依赖上述文件，并在代码中保留可被 grep 的关键日志锚点。

### 2.2 关键 grep 结果（实证证据）

```
grep -c "RECV: ASSIGN_ROLE"     → 4 次（正常，4 局游戏）
grep -c "Visuals attached"      → 0 次（异常！）
grep -c "RandomPickup Spawned"  → 0 次（异常！）客户端从未独立 Spawn
grep -c "A76AD7FE" engine.log   → 数千次（节点父子关系混乱）
```

服务端日志反而正常：

```
[Pickup] Player N picked up large energy
[RandomPickup] Spawned small pickup at (17.5, 5.5) active=5
```

### 2.3 关键代码路径

`Client.HandleAssignRole`（network/Client.lua:354）逻辑：

```lua
for i = 1, Config.NumPlayers do
    local existingNode = scene_:GetChild("Player_" .. i, true)
    if existingNode then
        -- ⚠️ Bug 在这里：Create 内部已经 CreateVisuals 了
        local p = Player.Create(i, (i == mySlot_), { existingNode = existingNode })
        Player.AttachVisuals(p)   -- ← 因 p.visualNode 已存在直接 return
    end
end
```

`Player.Create`（Player.lua:134）的 `existingNode` 路径：

```lua
if not opts.skipVisuals then
    visualNode, mat, outlineMat = Player.CreateVisuals(node, index)
    --                              ↑ node 是 REPLICATED 父节点
    --                              ↑ 在它下面 CreateChild("Visual") 会冲突
end
```

`Player.AttachVisuals`（Player.lua:120）：

```lua
function Player.AttachVisuals(p)
    if p.visualNode then return end   -- ← 提前 return，print 永远不触发
    ...
    print("[Player] Visuals attached to player " .. p.index)
end
```

### 2.4 根因

**在 REPLICATED 父节点下用客户端代码创建子节点是不安全的**：

1. 服务端节点同步会基于子节点名字 hash 维护父子关系
2. 客户端独立 CreateChild 会产生**孤儿子节点**或**hash 冲突**
3. 引擎 warning `Failed to find parent node with name hash A76AD7FE` 是直接证据

这一个 root cause 同时解释了所有渲染 bug：

| 现象 | 原因 |
|------|------|
| 角色看不见、无表情 | Visual / EyeL / EyeR 子节点在 REPLICATED Player_N 下被覆盖 |
| 道具不可见 | `Pickup.Spawn` 在服务端调用，REPLICATED Pickup_xxx 节点同步到客户端时不带 CustomGeometry；客户端无补挂逻辑 |
| 平台逐渐消失 | Map 块虽 LOCAL 父节点（MapRoot LOCAL），但同名子节点 hash 与服务端可能冲突 |
| 全灰 | 同上，材质未应用到客户端节点 |
| 能量条不更新 | HUD 读取的玩家数据可能因 visualNode 被丢弃后引用失效 |

---

## 3. 修复方案

### 3.1 核心原则

**REPLICATED 节点只承载位置/旋转/物理同步，所有视觉/装饰子节点必须在客户端用 LOCAL 模式创建。**

### 3.2 修复点

#### Fix 1: Player.Create 客户端路径必须 skipVisuals

`Client.HandleAssignRole` 改为：

```lua
local p = Player.Create(i, (i == mySlot_), {
    existingNode = existingNode,
    skipVisuals = true,   -- ← 新增：不在 Create 里创建 visual
})
Player.AttachVisuals(p)   -- ← 由 AttachVisuals 用 LOCAL 模式创建
```

#### Fix 2: Player.CreateVisuals 子节点显式 LOCAL

```lua
local visualNode = node:CreateChild("Visual", LOCAL)
local outlineNode = visualNode:CreateChild("Outline", LOCAL)
local eyeL = visualNode:CreateChild("EyeL", LOCAL)
local eyeR = visualNode:CreateChild("EyeR", LOCAL)
```

#### Fix 3: Pickup.Spawn 分离 server/client 路径

服务端：只创建 REPLICATED 节点 + LOCAL 物理
客户端：监听 NodeAdded 事件，在 Pickup_xxx 节点出现时挂上 LOCAL 视觉子节点

```lua
function Pickup.SpawnServer(x, y, size)
    local node = scene_:CreateChild("Pickup_" .. size)  -- REPLICATED
    -- 物理 LOCAL（不需要复制）
    local body = node:CreateComponent("RigidBody", LOCAL)
    -- 不创建 CustomGeometry
end

function Pickup.AttachClientVisuals(node, size)
    -- 客户端 NodeAdded 触发后调用
    local geom = node:CreateComponent("CustomGeometry")  -- LOCAL by default in REPLICATED parent? 显式 LOCAL
    -- ...
end
```

#### Fix 4: 客户端订阅 NodeAdded

```lua
SubscribeToEvent(scene_, "NodeAdded", function(eventType, eventData)
    local node = eventData["Node"]:GetPtr("Node")
    local name = node.name
    if name == "Pickup_small" or name == "Pickup_large" then
        local size = name:sub(8)  -- "small" or "large"
        Pickup.AttachClientVisuals(node, size)
    end
end)
```

### 3.3 持久化诊断日志

由于 Maker 无法在游戏内看日志，关键代码路径必须保留 `print` 锚点：

- `[Player] Visuals attached to player N` - 已存在
- `[Pickup] Client visual attached to Pickup_xxx (id=N)` - 需新增
- `[Map] Block created at (x,y) type=N` - 已存在

每次会话开始通过 `grep` 上述 5 个锚点的出现次数来判定渲染流程是否健康。

---

## 4. 验证清单

修复后必须确认：

- [ ] 客户端日志 `Visuals attached to player` 出现 4 次（每局）
- [ ] 客户端日志出现 `Client visual attached to Pickup_` 数十次
- [ ] 客户端 engine.log 中 `A76AD7FE` 警告消失或大幅减少
- [ ] 游戏内角色有眼睛、有颜色、不消失
- [ ] 道具可见
- [ ] 能量条随时间增长

---

## 5. 教训

1. **在 UrhoX 的网络模型下，REPLICATED 节点只能承载"复制必要"的最小信息**
2. **所有 cosmetic 子节点必须用 LOCAL 模式独立创建**
3. **客户端补挂视觉的唯一安全时机是 `NodeAdded` 事件，而不是 ASSIGN_ROLE 处理时遍历**
4. **不要凭"应该能工作"的直觉修代码——先 grep 日志确认假设**

---

*相关文档*：
- `docs/postmortem-multiplayer-silent-failure.md` - 服务端启动失败 postmortem

# 方块变灰 Bug 修复日志

## 现象
- 联机模块加入后，地图平台方块颜色整体变灰、饱和度降低
- 完全删除联机模块时画面恢复正常
- 单机分支（docs 中的正常版本 Standalone.lua / Client.lua / Map.lua / main.lua）画面正常
- 玩家角色颜色正常（高饱和红/蓝/绿/黄），仅地图方块受影响

## 用户提供的对照
- 上传至 docs/ 的 4 个文件：Standalone.lua / Client.lua / Map.lua / main.lua（来自单机分支正常版本）
- 截图对比：玩家颜色正确，地图方块灰色（应为奶白 0.92,0.88,0.82）

## 关键截图观察

用户截图显示：
- **玩家 P1(红)、P2(蓝)、P3(绿)、P4(黄) 颜色全部正确**
- **地图方块全部灰色**（应为奶白 Color(0.92, 0.88, 0.82)）
- 背景渐变可见

## 代码对比分析

### Map.lua vs Player.lua 材质创建
- 完全相同模式：`Material:new()` → `SetTechnique(0, PBRNoTexture)` → `SetShaderParameter("MatDiffColor", color)`
- 完全相同渲染组件：`CustomGeometry` + `geom:SetMaterial(mat)`
- materialCache_ 正确填充：Client 路径中 skipVisuals_=false
- Server 不干扰：Server.lua 调用 Map.SetSkipVisuals(true)，运行在独立 Linux 进程

### 光照差异
- **Standalone**：加载 LightGroup/Daytime.xml（引擎内置，含 IBL 环境贴图）→ 丰富间接光照
- **Client（bug 版本）**：直接走 fallback 光照（Zone ambient 0.40,0.35,0.30 + 单个 DirectionalLight，无 IBL）→ 平坦光照

### Player 有 MatEmissiveColor，普通方块没有
- Player.lua：设有 MatEmissiveColor（来自 Config.PlayerEmissive），自发光补偿弱光照
- Background：设有 MatEmissiveColor（color * 0.3），自发光补偿弱光照
- Map.lua 普通方块（BLOCK_NORMAL / BLOCK_SAFE）：无 MatEmissiveColor → 完全依赖环境光照

---

## 修复尝试记录

### 尝试 1：Intro 阶段3 镜头改为聚焦出生区
- **假设**：相机离地图巨远 → 平台像素化采样 → 看起来灰
- **修改**：GameManager.lua intro 阶段3 镜头改为全景拉远
- **结果**：❌ 用户明确否定"胡说八道"，与镜头距离无关
- **处理**：已回滚

### 尝试 2：提高 fallback 光照参数
- **假设**：fallback ambientColor(0.40,0.35,0.30) 太暗
- **修改**：Client.lua / Standalone.lua fallback ambientColor → (0.75,0.72,0.68)，light.brightness = 1.2
- **结果**：❌ 截图仍变灰
- **处理**：已回滚

### 尝试 3：Camera 节点 LOCAL → REPLICATED
- **假设**：Camera 节点用 LOCAL 导致 Viewport/Renderer 无法正确关联
- **修改**：Camera.lua CreateChild("Camera", LOCAL) → CreateChild("Camera")
- **结果**：❌ 仍灰
- **处理**：已回滚

### 尝试 4：InstantiateXML + LOCAL 加载 LightGroup/Daytime.xml
- **假设**：Client 缺少 IBL 环境贴图是根因，用 InstantiateXML(LOCAL) 加载
- **修改**：Client.lua CreateScene 中用 InstantiateXML + LOCAL 加载 LightGroup
- **结果**：❌ 仍灰
- **处理**：已回滚

### 尝试 5：CreateChild(LOCAL) + LoadXML 加载 LightGroup
- **假设**：换一种方式加载 LightGroup（CreateChild + LoadXML 而非 InstantiateXML）
- **修改**：Client.lua 用 scene_:CreateChild("LightGroup", LOCAL) + lightGroup:LoadXML()
- **结果**：❌ 用户截图确认：方块灰，玩家有色
- **关键发现**：此截图证明问题不在渲染管线整体，而是方块特有

### 尝试 6（验证 4）：纯红色测试确认材质是否生效
- **目的**：判断材质系统本身是否工作
- **修改**：Config.lua 将 BlockColors[1] 从奶白(0.92,0.88,0.82) 改为纯红(1,0,0)
- **结果**：✅ 方块显示红色（但有轻微灰度，不是纯红）
- **结论**：材质系统正常工作，颜色被 PBR 光照压暗，低饱和色受影响更大
- **处理**：Config.lua 已回滚

### 尝试 7：LightGroup(无 fallback 双 Zone) + 普通方块添加微弱 MatEmissiveColor
- **假设**：
  1. 之前尝试 4/5 失败的原因之一是 LightGroup 与 fallback 同时创建了双 Zone，互相冲突
  2. 普通方块缺少 MatEmissiveColor 导致在弱光照下颜色失真
- **修改**：
  - Client.lua：优先加载 LightGroup(LOCAL)，成功则不创建 fallback（避免双 Zone）
  - Map.lua：为 BLOCK_NORMAL / BLOCK_SAFE 添加 MatEmissiveColor(color * 0.15)
- **结果**：❌ 用户报告"依然没有恢复"
- **分析**：LightGroup 仍使用 LOCAL 标志，可能是 LOCAL 导致 Zone 不生效

### 尝试 8：移除所有灯光节点的 LOCAL 标志
- **假设**：
  - 原始工作版本 docs/Client.lua 中所有节点（LightGroup / Zone / Light / BackgroundGradient）创建时均无 LOCAL 标志（即默认 REPLICATED）
  - 所有失败的尝试（4、5、7）都使用了 LOCAL 标志
  - LOCAL 模式可能导致 Zone/Light 组件不被渲染管线正确识别（特别是 IBL 环境贴图）
- **修改**：
  - Client.lua CreateScene：`CreateChild("LightGroup", LOCAL)` → `CreateChild("LightGroup")`
  - Client.lua CreateFallbackLighting：移除 Zone / Light 节点及组件的 LOCAL
  - Client.lua CreateBackgroundPlane：移除所有子节点/组件的 LOCAL
- **结果**：❌ 用户报告"依然没有解决"

---

## 已确认排除的方向

| 方向 | 排除原因 |
|------|---------|
| 镜头距离 | 尝试 1，用户否定 |
| fallback 光照参数太暗 | 尝试 2，提高后仍灰 |
| Camera 节点 LOCAL | 尝试 3，改 REPLICATED 仍灰 |
| 缺少 LightGroup（LOCAL 模式） | 尝试 4/5/7，加载 LOCAL LightGroup 仍灰 |
| 双 Zone 冲突 | 尝试 7 去掉双 Zone 仍灰 |
| 材质系统失效 | 尝试 6（纯红测试）证明材质正常工作 |
| LightGroup/Zone/Light 的 LOCAL 标志 | 尝试 8，全部移除 LOCAL 仍灰 |
| Server 覆盖客户端 Zone/Light | Server.lua 不创建 Zone/Light/Material |

## 已确认的事实

1. **材质系统正常**：纯红测试证明 Material + PBRNoTexture + SetShaderParameter 可以正确设置颜色
2. **玩家颜色正常**：Player 使用完全相同的材质模式，颜色正确
3. **背景颜色正常**：Background 使用完全相同的材质模式，颜色正确
4. **Player 和 Background 有 MatEmissiveColor，普通方块没有**：这是已知差异
5. **单机版（Standalone）方块颜色正常**：同样没有 MatEmissiveColor，但光照环境不同
6. **单机版加载 LightGroup 无 LOCAL 标志**：但客户端改为无 LOCAL 后仍无效

## 尝试 9（根因修复）：客户端所有节点/组件改为 LOCAL 模式 + InstantiateXML

### 根因分析

通过网上搜索 Urho3D PBR 变灰/变暗问题，结合引擎文档 `engine-docs/recipes/network-game-guide.md`，找到了根本原因：

**Urho3D 场景复制（Scene Replication）机制**：
1. `CreateChild()` 和 `CreateComponent()` 默认创建 **REPLICATED** 节点/组件
2. 客户端连接服务端后，服务端拥有所有 REPLICATED 节点的权威控制权
3. **服务端场景中不存在的 REPLICATED 节点，会在客户端被场景复制机制删除**

**Client.lua 中的问题**：
- `CreateScene()` 中：`scene_:CreateChild("LightGroup")` — **REPLICATED**（默认）
- `CreateFallbackLighting()` 中：Zone 和 Light 节点 — **REPLICATED**
- `CreateBackgroundPlane()` 中：BackgroundGradient 和 Strip 子节点 — **REPLICATED**

而 Server.lua 中只创建了 Octree、PhysicsWorld 和 DeathZone（LOCAL），**没有 LightGroup/Zone/Light**。

**结果**：客户端连接服务端后，服务端的场景复制机制会删除客户端的 REPLICATED LightGroup/Zone/Light 节点。失去 Zone（IBL 环境贴图）和方向光后，PBR 材质在 HDR 模式下颜色被严重压暗/降饱和 → 方块变灰。

**为什么 Standalone 不受影响**：Standalone 不连接服务端，不存在场景复制，所以 LightGroup 不会被删除。

**为什么之前尝试 4/5 用 LOCAL 也失败**：
- `CreateChild("LightGroup", LOCAL)` + `LoadXML()` 的方式，LoadXML 内部创建的子节点/组件可能仍然使用了默认的 REPLICATED 模式
- 正确做法是使用 `InstantiateXML(root, pos, rot, LOCAL)`，这会让所有子节点和组件都强制 LOCAL

### 修改内容

**Client.lua**：
1. `CreateScene()`:
   - `DebugRenderer` 组件改为 `LOCAL`
   - LightGroup 改用 `scene_:InstantiateXML(root, Vector3.ZERO, Quaternion.IDENTITY, LOCAL)` — 所有子节点/组件强制 LOCAL
2. `CreateFallbackLighting()`:
   - Zone 节点/组件：`CreateChild("Zone", LOCAL)` + `CreateComponent("Zone", LOCAL)`
   - Light 节点/组件：`CreateChild("DirectionalLight", LOCAL)` + `CreateComponent("Light", LOCAL)`
3. `CreateBackgroundPlane()`:
   - BackgroundGradient 和所有 Strip 子节点、StaticModel 组件：全部加 `LOCAL`

### 关键引用

引擎文档 `engine-docs/recipes/network-game-guide.md` 第 1799-1800 行：
> - **服务器**：游戏实体用 REPLICATED（或默认），环境用 LOCAL
> - **客户端**：**所有节点和组件都必须用 LOCAL**

### 结果

待用户测试确认。

---

*状态：尝试 9 已实施，等待用户验证。*
*最后更新：2026-04-27*

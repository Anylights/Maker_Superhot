---
name: tilemap-creator
description: |
  Tilemap 瓦片资源制作工具。支持两种工作流：(1) 从零使用 AI 生成完整瓦片集（generate_image/batch_generate_images），保持风格一致和边缘可拼接；(2) 从用户上传的 tilemap spritesheet 中精确切割出独立瓦片（内缩+放大方法，避免白边）。
  Use when users need to (1) 生成 tilemap 瓦片, (2) 制作瓦片地图素材, (3) 切割 tilemap/spritesheet, (4) 创建游戏地图瓦片, (5) tilemap tiles, (6) 用户上传了一张大的瓦片图需要切割成小瓦片, (7) 需要从零 AI 生成一套风格统一的瓦片。
---

# Tilemap 瓦片制作

## 工作流选择

| 场景 | 工作流 | 参考文档 |
|------|--------|---------|
| 用户无素材，需要从零生成 | **AI 生成** | [from-scratch.md](references/from-scratch.md) |
| 用户提供了 spritesheet 大图 | **切割提取** | [from-upload.md](references/from-upload.md) |

## 设计规范（必读）

无论哪种工作流，瓦片必须遵循统一设计规范。开始前先阅读：[tile-design-rules.md](references/tile-design-rules.md)

核心要点：
- 每张图只含一个瓦片，正方形，推荐 128x128
- **同元素同颜色** — 所有瓦片中相同的元素颜色必须完全一致（铁律）
- 两种地形的完整过渡需要 16 张瓦片（基础 + 4边缘 + 4外角 + 4内角）
- 相邻瓦片边缘必须无缝拼接

## AI 生成流程摘要

1. **定义颜色词表** — 为每种元素锁定唯一颜色描述词（如"绿色草地"、"深蓝色海水"），全套 prompt 严格复用
2. 设计瓦片清单（按 tile-design-rules.md 的分类体系）
3. 先生成 1 张锚点瓦片（如 grass_base1），确认风格满意
4. 用锚点作为 reference_image + 固定 seed + 统一颜色词，分批生成其余瓦片
5. 每批 2-4 张（避免超时），方向性瓦片的 prompt 必须明确"哪半/哪角是什么"
6. 全部生成后复制到目标目录，去掉时间戳后缀

详细步骤和 prompt 模板 → [from-scratch.md](references/from-scratch.md)

## 切割提取流程摘要

1. 分析 spritesheet 的网格参数（cols/rows/gap/margin）
2. 用**内缩+放大**方法切割（不要填充边缘）
3. 内缩量根据间距调整（通常 2-5px）
4. 放大到目标尺寸时，像素风用 NEAREST，其他用 LANCZOS
5. 检查边缘干净度，无白边残留

详细步骤和切割脚本 → [from-upload.md](references/from-upload.md)

## 输出规范

- 文件格式：PNG
- 命名：`类型_方向.png`（如 `road_edge_N.png`、`grass_base1.png`）
- 存放目录：`assets/Textures/tiles/`
- 编辑器集成：更新 `LoadTiles()` 中的 tileDefs 数组，按分类组织

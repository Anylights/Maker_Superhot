# 用户上传 Tilemap 切割流程

## 目录

1. [总体策略](#总体策略)
2. [网格分析](#网格分析)
3. [切割方法：内缩+放大](#切割方法内缩放大)
4. [批量切割脚本](#批量切割脚本)
5. [验收检查](#验收检查)
6. [常见问题](#常见问题)

---

## 总体策略

用户提供一张 tilemap spritesheet（多个瓦片排列在一张大图中），需要将其切割成独立的单瓦片图片。

关键难点：spritesheet 的瓦片之间通常有间距（gap）或边距（margin），直接按网格切割会导致白边或邻瓦片内容混入。

## 网格分析

### 第一步：获取图片信息

```bash
# 用 Python PIL 分析图片尺寸
python3 -c "
from PIL import Image
img = Image.open('uploaded_tilemap.png')
print(f'尺寸: {img.size}')
print(f'模式: {img.mode}')
"
```

### 第二步：确定网格参数

需要确定 4 个参数：

| 参数 | 含义 | 确定方法 |
|------|------|---------|
| cols, rows | 列数、行数 | 用户告知 或 目视图片计数 |
| cell_w, cell_h | 单个格子宽高（含间距） | `图片宽 / cols`, `图片高 / rows` |
| gap | 瓦片间距像素数 | 放大图片观察瓦片之间的空白列 |
| margin | 图片边距 | 放大图片观察最外圈空白 |

### 第三步：验证网格

```python
# 计算并验证
cell_w = (img_width - 2 * margin + gap) / cols  # 或直接 img_width / cols（无 margin 时）
cell_h = (img_height - 2 * margin + gap) / rows
# cell_w 和 cell_h 应为整数或接近整数
```

## 切割方法：内缩+放大

### 核心原则

**不要直接按网格边界切割，也不要用颜色填充边缘。**

正确做法：

1. **内缩**（inset）：从网格边界向内收缩若干像素，避开间距和边缘模糊区域
2. **裁切**：取内缩后的区域
3. **放大**（scale up）：将裁切结果等比例放大到目标尺寸（如 128x128）

```
原始网格区域       内缩后的区域        放大到目标尺寸
┌─────────┐       ┌───────┐          ┌─────────┐
│ ░░░░░░░ │       │ █████ │          │ ███████ │
│ ░█████░ │  ──>  │ █████ │   ──>   │ ███████ │
│ ░█████░ │       │ █████ │          │ ███████ │
│ ░░░░░░░ │       └───────┘          │ ███████ │
└─────────┘                          └─────────┘
  64x64             56x56              128x128
```

### 为什么不填充

- 填充白色/透明像素 → 拼接时出现明显接缝
- 填充邻近像素颜色 → 色差、纹理断裂
- 内缩+放大 → 保持原有纹理连续性，放大后边缘自然

### 内缩量选择

| 场景 | 推荐内缩量 | 说明 |
|------|-----------|------|
| 无间距，边缘清晰 | 1-2 px | 仅去除可能的抗锯齿 |
| 有 1px 间距 | 2-3 px | 跳过间距 + 模糊过渡 |
| 有 2-4px 间距 | 3-5 px | 确保完全避开间距区域 |
| 边缘有明显模糊/渐变 | 4-6 px | 大幅内缩确保干净 |

**判断依据**：放大查看切割后的瓦片边缘，如果有白色像素残留或颜色突变，增大内缩量。

## 批量切割脚本

```python
from PIL import Image
import os

def cut_tilemap(input_path, output_dir, cols, rows, target_size=128, inset=3):
    """
    切割 tilemap spritesheet 为独立瓦片。
    
    Args:
        input_path: 原始 spritesheet 路径
        output_dir: 输出目录
        cols, rows: 列数、行数
        target_size: 输出瓦片尺寸（正方形）
        inset: 内缩像素数
    """
    img = Image.open(input_path)
    w, h = img.size
    cell_w = w / cols
    cell_h = h / rows
    
    os.makedirs(output_dir, exist_ok=True)
    
    for row in range(rows):
        for col in range(cols):
            # 格子起始坐标
            x0 = col * cell_w
            y0 = row * cell_h
            
            # 内缩裁切
            crop_box = (
                int(x0 + inset),
                int(y0 + inset),
                int(x0 + cell_w - inset),
                int(y0 + cell_h - inset)
            )
            tile = img.crop(crop_box)
            
            # 等比例放大到目标尺寸
            tile = tile.resize((target_size, target_size), Image.LANCZOS)
            
            # 保存
            tile.save(os.path.join(output_dir, f"tile_{row}_{col}.png"))
    
    print(f"切割完成: {cols * rows} 张瓦片 → {output_dir}")
```

### 调用方式

```python
cut_tilemap(
    input_path="assets/image/uploaded_tilemap.png",
    output_dir="assets/Textures/tiles",
    cols=8, rows=4,        # 根据实际网格确定
    target_size=128,       # 目标尺寸
    inset=3                # 内缩像素数，根据间距调整
)
```

## 验收检查

切割后逐项检查：

1. **边缘干净度**：放大瓦片查看四边，无白色/透明像素残留
2. **尺寸一致**：所有瓦片 target_size × target_size
3. **内容完整**：瓦片核心内容未被过度裁切
4. **拼接测试**：将相邻瓦片并排放置，确认边缘过渡自然

### 边缘检测辅助

```python
from PIL import Image
import numpy as np

def check_edge_brightness(tile_path, edge_width=2):
    """检查瓦片边缘是否有异常亮色（白边残留）"""
    img = np.array(Image.open(tile_path))
    h, w = img.shape[:2]
    
    edges = {
        "top":    img[:edge_width, :],
        "bottom": img[h-edge_width:, :],
        "left":   img[:, :edge_width],
        "right":  img[:, w-edge_width:]
    }
    
    for name, edge in edges.items():
        avg = edge.mean()
        if avg > 240:  # 接近白色
            print(f"⚠ {tile_path} {name} 边缘亮度 {avg:.0f}，可能有白边")
```

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| 瓦片有白边 | 内缩量不够，切到了间距区域 | 增大 inset 值 |
| 瓦片内容被截 | 内缩量过大 | 减小 inset 值 |
| 瓦片是长方形 | 原始网格非正方形 | 分别设置 cell_w/cell_h，放大时不保持比例或裁切为正方形 |
| 颜色偏差 | 放大算法影响 | 使用 `Image.LANCZOS`（最高质量）或 `Image.NEAREST`（像素风保持锐利） |
| 像素风格变模糊 | 使用了 LANCZOS 放大 | 改用 `Image.NEAREST` 保持像素锐利边缘 |

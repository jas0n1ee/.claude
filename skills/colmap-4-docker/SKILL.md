---
name: colmap-4-docker
description: COLMAP 4.x Docker 正确使用指南，包含先验位姿导入、空间匹配、参数变更等核心知识。当用户遇到 COLMAP 4.x 相关问题、需要搭建 COLMAP Docker 重建流程、使用 spatial_matcher 或 pose_priors、或遇到参数报错时使用此 skill。
tools: Bash, Read, Write, Glob, Grep
---

# COLMAP 4.x Docker 使用指南

基于实际项目经验总结的 COLMAP 4.x Docker 镜像正确使用方式。

## 快速开始

```bash
# 1. 目录结构
mkdir -p {images,sparse/0,database,logs}

# 2. 创建数据库
docker run --rm --gpus "device=0" \
  -v $(pwd):/workspace \
  -w /workspace \
  colmap/colmap:latest \
  colmap database_creator --database_path /workspace/database/database.db

# 3. 特征提取
docker run --rm --gpus "device=0" \
  -v $(pwd):/workspace \
  -w /workspace \
  colmap/colmap:latest \
  colmap feature_extractor \
    --database_path /workspace/database/database.db \
    --image_path /workspace/images \
    --ImageReader.camera_model PINHOLE \
    --SiftExtraction.use_gpu 1

# 4. 特征匹配 (exhaustive)
docker run --rm --gpus "device=0" \
  -v $(pwd):/workspace \
  -w /workspace \
  colmap/colmap:latest \
  colmap exhaustive_matcher \
    --database_path /workspace/database/database.db

# 5. 重建
docker run --rm --gpus "device=0" \
  -v $(pwd):/workspace \
  -w /workspace \
  colmap/colmap:latest \
  colmap mapper \
    --database_path /workspace/database/database.db \
    --image_path /workspace/images \
    --output_path /workspace/sparse
```

---

## 关键概念：先验位姿 (Prior Poses)

### 问题背景
COLMAP 4.x 的 `spatial_matcher` 需要 `pose_priors` 表中有正确的位姿数据才能基于空间位置匹配。

### 数据库表结构

```sql
-- 关键表：pose_priors
CREATE TABLE pose_priors (
    pose_prior_id INTEGER PRIMARY KEY,
    corr_data_id INTEGER,          -- 必须关联到 frame_data.frame_id
    corr_sensor_id INTEGER,        -- 关联到 frame_data.sensor_id
    corr_sensor_type INTEGER,      -- 0 = camera
    position BLOB,                 -- 3 doubles (x, y, z)
    position_covariance BLOB,      -- 9 doubles (3x3 matrix)
    coordinate_system INTEGER      -- 关键！0=UNKNOWN, 1=ENU, 2=LLA
);

-- 关联表：frame_data
CREATE TABLE frame_data (
    frame_id INTEGER,
    data_id INTEGER,               -- 对应 images.image_id
    sensor_id INTEGER,             -- 对应 cameras.camera_id
    sensor_type INTEGER            -- 0 = camera
);
```

### 正确导入先验位姿的步骤

```python
#!/usr/bin/env python3
"""正确导入先验位姿到 COLMAP 4.x 数据库"""

import sqlite3
import struct

def import_pose_priors(db_path, images_txt_path):
    """
    从 COLMAP images.txt 导入位姿到 pose_priors 表
    
    关键要点：
    1. corr_data_id 必须关联 frame_data.frame_id，不是 images.image_id
    2. coordinate_system 必须设为 1 (ENU)，默认 0 无法识别
    """
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    # 清空现有数据
    cursor.execute("DELETE FROM pose_priors")
    
    # 获取 image_id -> frame_id 映射（关键！）
    cursor.execute("SELECT frame_id, data_id FROM frame_data")
    image_to_frame = {row[1]: row[0] for row in cursor.fetchall()}
    
    # 解析 images.txt
    with open(images_txt_path, 'r') as f:
        lines = f.readlines()
    
    # 跳过头部注释，找到数据开始位置
    start_idx = 0
    for i, line in enumerate(lines):
        if line.startswith('# Number of images:'):
            start_idx = i + 1
            break
    
    count = 0
    i = start_idx
    while i < len(lines):
        line = lines[i].strip()
        if not line or line.startswith('#'):
            i += 1
            continue
        
        # 解析：IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        parts = line.split()
        if len(parts) < 10:
            i += 1
            continue
        
        image_id = int(parts[0])
        tx, ty, tz = float(parts[5]), float(parts[6]), float(parts[7])
        
        # 获取 frame_id（关键步骤！）
        frame_id = image_to_frame.get(image_id)
        if frame_id is None:
            i += 2
            continue
        
        # 编码位置数据
        position_blob = struct.pack('ddd', tx, ty, tz)
        cov_blob = struct.pack('ddddddddd', 0.01, 0, 0, 0, 0.01, 0, 0, 0, 0.01)
        
        # 插入 pose_priors
        # 关键：coordinate_system = 1 (ENU)
        cursor.execute(
            """INSERT INTO pose_priors
               (pose_prior_id, corr_data_id, corr_sensor_id, corr_sensor_type,
                position, position_covariance, coordinate_system)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (count + 1, frame_id, frame_id, 0, position_blob, cov_blob, 1)
        )
        
        count += 1
        i += 2  # 跳过点行
    
    conn.commit()
    conn.close()
    print(f"导入完成：{count} 个位姿")

if __name__ == '__main__':
    import_pose_priors('database.db', 'images.txt')
```

### 验证导入

```bash
# 检查 pose_priors 数量
sqlite3 database.db "SELECT COUNT(*) FROM pose_priors;"
# 应该等于图像数量

# 检查 coordinate_system
sqlite3 database.db "SELECT coordinate_system, COUNT(*) FROM pose_priors GROUP BY coordinate_system;"
# 应该显示 1 | <图像数量>

# 检查 frame 关联
sqlite3 database.db "SELECT pp.corr_data_id, fd.frame_id 
FROM pose_priors pp 
JOIN frame_data fd ON pp.corr_data_id = fd.frame_id 
LIMIT 5;"
```

---

## 常见问题与解决方案

### ❌ 错误 1: "No images with location data"

**症状：** spatial_matcher 报告没有位置数据

**原因：**
1. pose_priors 表为空
2. coordinate_system = 0 (UNKNOWN)
3. corr_data_id 关联错误

**解决：**
```bash
# 1. 确认 pose_priors 已导入
sqlite3 database.db "SELECT COUNT(*) FROM pose_priors;"

# 2. 设置 coordinate_system = 1 (关键！)
sqlite3 database.db "UPDATE pose_priors SET coordinate_system = 1;"

# 3. 重新运行 spatial_matcher
docker run --rm --gpus "device=0" \
  -v $(pwd):/workspace \
  -w /workspace \
  colmap/colmap:latest \
  colmap spatial_matcher \
    --database_path /workspace/database/database.db \
    --SpatialMatching.max_distance 20.0 \
    --SpatialMatching.max_num_neighbors 50 \
    --FeatureMatching.use_gpu 1
```

---

### ❌ 错误 2: "unrecognised option '--SiftMatching.use_gpu'"

**症状：** 参数错误，命令无法识别

**原因：** COLMAP 4.x 参数名变更

**解决：**
```bash
# 错误 ❌
--SiftMatching.use_gpu 1
--SiftMatching.gpu_index 0

# 正确 ✅
--FeatureMatching.use_gpu 1
--FeatureMatching.gpu_index 0
```

**完整变更对照：**

| 旧参数 (COLMAP 3.x) | 新参数 (COLMAP 4.x) | 说明 |
|---------------------|---------------------|------|
| `--SiftMatching.use_gpu` | `--FeatureMatching.use_gpu` | GPU 开关 |
| `--SiftMatching.gpu_index` | `--FeatureMatching.gpu_index` | GPU 索引 |
| `--SpatialMatching.verify_two_view_geometry` | 不存在 | 已移除 |
| `--SpatialMatching.num_neighbors` | `--SpatialMatching.max_num_neighbors` | 重命名 |

---

### ❌ 错误 3: 匹配数量极少 (< 1000 对)

**症状：** spatial_matcher 完成但匹配对很少

**诊断：**
```bash
# 检查匹配数量
sqlite3 database.db "SELECT COUNT(*) FROM matches;"

# 检查位姿范围
python3 << 'EOF'
import sqlite3, struct
conn = sqlite3.connect('database.db')
cursor = conn.cursor()
cursor.execute("SELECT position FROM pose_priors")
positions = [struct.unpack('ddd', row[0]) for row in cursor.fetchall()]
xs, ys, zs = zip(*positions)
print(f"X: {min(xs):.2f} to {max(xs):.2f}, span: {max(xs)-min(xs):.2f}m")
print(f"Y: {min(ys):.2f} to {max(ys):.2f}, span: {max(ys)-min(ys):.2f}m")
print(f"Z: {min(zs):.2f} to {max(zs):.2f}, span: {max(zs)-min(zs):.2f}m")
EOF
```

**解决：**
```bash
# 如果数据跨度 > 50米，增加距离阈值
--SpatialMatching.max_distance 20.0  # 默认 100，可减小到 5-20
--SpatialMatching.max_num_neighbors 50  # 默认 50
```

---

### ❌ 错误 4: Worker 偏离使用 exhaustive_matcher

**警告：** 切勿在小数据量 (< 1000 张) 以外使用 exhaustive_matcher！

**后果：**
- 25,192 张图像会产生 6.3 亿对匹配
- 计算量爆炸，永远无法完成
- 严重偏离空间匹配优化目标

**正确做法：**
```bash
# ✅ 小数据集 (< 1000 张)
colmap exhaustive_matcher

# ✅ 大数据集使用 spatial_matcher（基于先验位姿）
colmap spatial_matcher \
  --SpatialMatching.max_distance 20.0 \
  --SpatialMatching.max_num_neighbors 50

# ✅ 或 sequential_matcher（视频序列）
colmap sequential_matcher
```

---

## 完整工作流程示例

### 场景：基于先验位姿的重建

```bash
#!/bin/bash
set -e

WORKSPACE="/data/project"
IMAGES="/share/data/images"
PRIOR_POSES="/share/data/sparse/0/images.txt"
GPU="device=7"

cd $WORKSPACE

# Step 1: 准备目录
mkdir -p {images,sparse/0,database,logs}
ln -sf $IMAGES/* images/

# Step 2: 创建数据库
docker run --rm --gpus "$GPU" \
  -v $(pwd):/workspace \
  -w /workspace \
  colmap/colmap:latest \
  colmap database_creator \
    --database_path /workspace/database/database.db

# Step 3: 特征提取
docker run --rm --gpus "$GPU" \
  -v $(pwd):/workspace \
  -w /workspace \
  colmap/colmap:latest \
  colmap feature_extractor \
    --database_path /workspace/database/database.db \
    --image_path /workspace/images \
    --ImageReader.camera_model PINHOLE \
    --SiftExtraction.use_gpu 1 \
    --SiftExtraction.gpu_index 0 \
    --SiftExtraction.max_num_features 8192 \
  2>&1 | tee logs/feature_extractor.log

# Step 4: 导入先验位姿（关键！）
python3 << 'EOF'
import sqlite3, struct

# ... (上面的导入脚本)

conn = sqlite3.connect('database/database.db')
cursor = conn.cursor()

# 清空并重新导入
cursor.execute("DELETE FROM pose_priors")

# 获取 frame 映射
cursor.execute("SELECT frame_id, data_id FROM frame_data")
image_to_frame = {row[1]: row[0] for row in cursor.fetchall()}

# 解析并导入...
# (完整代码见上文)

# 关键：设置 coordinate_system = 1
cursor.execute("UPDATE pose_priors SET coordinate_system = 1;")
conn.commit()
conn.close()
EOF

# Step 5: 空间匹配
docker run --rm --gpus "$GPU" \
  -v $(pwd):/workspace \
  -w /workspace \
  colmap/colmap:latest \
  colmap spatial_matcher \
    --database_path /workspace/database/database.db \
    --SpatialMatching.max_distance 20.0 \
    --SpatialMatching.max_num_neighbors 50 \
    --FeatureMatching.use_gpu 1 \
    --FeatureMatching.gpu_index 0 \
  2>&1 | tee logs/spatial_matcher.log

# Step 6: 验证匹配数量
MATCHES=$(sqlite3 database/database.db "SELECT COUNT(*) FROM matches;")
echo "匹配对数量: $MATCHES"
if [ "$MATCHES" -lt 10000 ]; then
    echo "错误：匹配数量过少，检查 pose_priors"
    exit 1
fi

# Step 7: GLOMAP 重建
docker run --rm --gpus "$GPU" \
  -v $(pwd):/workspace \
  -w /workspace \
  colmap/colmap:latest \
  colmap global_mapper \
    --database_path /workspace/database/database.db \
    --image_path /workspace/images \
    --output_path /workspace/sparse \
  2>&1 | tee logs/global_mapper.log

# Step 8: 验证结果
ls -lh sparse/0/
echo "重建完成！"
```

---

## 关键检查点

### 每次运行前检查

```bash
# 1. 检查 pose_priors
check_pose_priors() {
    echo "=== Pose Priors 检查 ==="
    sqlite3 database.db "SELECT COUNT(*) as count FROM pose_priors;"
    sqlite3 database.db "SELECT coordinate_system, COUNT(*) FROM pose_priors GROUP BY coordinate_system;"
}

# 2. 检查匹配
check_matches() {
    echo "=== 匹配检查 ==="
    sqlite3 database.db "SELECT COUNT(*) FROM matches;"
    sqlite3 database.db "SELECT COUNT(*) FROM two_view_geometries;"
}

# 3. 检查输出
check_output() {
    echo "=== 输出检查 ==="
    ls -lh sparse/0/ 2>/dev/null || echo "无输出目录"
}
```

---

## 参考资源

- COLMAP 官方文档：https://colmap.github.io/
- COLMAP GitHub：https://github.com/colmap/colmap
- Docker Hub：https://hub.docker.com/r/colmap/colmap

---

## 版本信息

- 文档基于：COLMAP 4.0.3 (Docker)
- 最后更新：2026-04-09
- 验证环境：CUDA 12.9.1, Ubuntu 22.04

#!/usr/bin/env python3
"""Trae 配置查找工具"""

import os
import json
from pathlib import Path

print("\n" + "=" * 50)
print("  Trae 配置信息查找工具")
print("=" * 50 + "\n")

trae_dir = Path("D:/Trae CN")

if not trae_dir.exists():
    print(f"错误: Trae 目录不存在: {trae_dir}")
    exit(1)

print("[1/4] 查找配置文件...\n")

# 查找 JSON 文件
print("  JSON 配置文件:")
json_files = list(trae_dir.rglob("*.json"))[:20]
if json_files:
    for f in json_files:
        print(f"    - {f}")
        # 尝试读取小文件
        if f.stat().st_size < 10000:
            try:
                with open(f, 'r', encoding='utf-8') as file:
                    data = json.load(file)
                    # 查找可能的 API 配置
                    if any(key in str(data).lower() for key in ['api', 'token', 'key', 'auth', 'endpoint']):
                        print(f"      ⭐ 可能包含 API 配置")
            except:
                pass
else:
    print("    未找到")

print()

# 查找 YAML 文件
print("  YAML 配置文件:")
yaml_files = list(trae_dir.rglob("*.yaml")) + list(trae_dir.rglob("*.yml"))
yaml_files = yaml_files[:20]
if yaml_files:
    for f in yaml_files:
        print(f"    - {f}")
else:
    print("    未找到")

print()

# 查找 TOML 文件
print("  TOML 配置文件:")
toml_files = list(trae_dir.rglob("*.toml"))[:20]
if toml_files:
    for f in toml_files:
        print(f"    - {f}")
else:
    print("    未找到")

print()
print("[2/4] 查找日志文件...\n")

log_files = list(trae_dir.rglob("*.log"))[:10]
if log_files:
    for f in log_files:
        print(f"    - {f}")
else:
    print("    未找到")

print()
print("[3/4] 检查常见配置目录...\n")

config_dirs = [
    trae_dir / "config",
    trae_dir / "data",
    trae_dir / "user",
    Path(os.environ.get("APPDATA", "")) / "Trae",
    Path(os.environ.get("LOCALAPPDATA", "")) / "Trae",
    Path.home() / ".trae"
]

for dir_path in config_dirs:
    if dir_path.exists():
        print(f"    [存在] {dir_path}")
        files = list(dir_path.glob("*"))[:5]
        for f in files:
            if f.is_file():
                print(f"           - {f.name}")
    else:
        print(f"    [不存在] {dir_path}")

print()
print("[4/4] 查找可执行文件...\n")

exe_files = list(trae_dir.rglob("*.exe"))[:10]
if exe_files:
    for f in exe_files:
        print(f"    - {f.name}")
else:
    print("    未找到")

print()
print("=" * 50)
print("  查找完成")
print("=" * 50)
print()
print("下一步:")
print("1. 检查上述配置文件，查找 API 端点和认证信息")
print("2. 或使用 Fiddler/Wireshark 抓包查看 API 请求")
print("3. 将找到的信息配置到 trae-gateway/.env")
print()

#!/usr/bin/env python3
"""检查 storage.json 的结构（不显示敏感内容）"""

import json
from pathlib import Path

storage_file = Path(r"C:\Users\zhuyulin\AppData\Roaming\Trae CN\User\globalStorage\storage.json")

if not storage_file.exists():
    print(f"文件不存在: {storage_file}")
    exit(1)

print(f"检查文件: {storage_file}")
print(f"文件大小: {storage_file.stat().st_size} bytes\n")

with open(storage_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

def inspect_dict(d, prefix="", max_depth=3, current_depth=0):
    """递归检查字典结构，不显示敏感值"""
    if current_depth >= max_depth:
        return
    
    for key, value in d.items():
        full_key = f"{prefix}.{key}" if prefix else key
        
        if isinstance(value, dict):
            print(f"  {full_key}: {{dict, {len(value)} keys}}")
            inspect_dict(value, full_key, max_depth, current_depth + 1)
        elif isinstance(value, list):
            print(f"  {full_key}: [list, {len(value)} items]")
            if value and isinstance(value[0], dict):
                print(f"    First item keys: {list(value[0].keys())}")
        elif isinstance(value, str):
            # 不显示完整字符串，只显示长度和前几个字符
            if len(value) > 50:
                print(f"  {full_key}: (string, {len(value)} chars, starts with '{value[:20]}...')")
            else:
                # 短字符串可能不敏感
                if any(keyword in key.lower() for keyword in ['token', 'password', 'secret', 'key']):
                    print(f"  {full_key}: (string, {len(value)} chars, HIDDEN)")
                else:
                    print(f"  {full_key}: '{value}'")
        else:
            print(f"  {full_key}: {type(value).__name__} = {value}")

print("storage.json 结构:\n")
inspect_dict(data)

print("\n" + "=" * 60)
print("查找可能的 Token 字段:\n")

# 查找可能包含 Token 的字段
token_keywords = ['token', 'jwt', 'auth', 'access', 'refresh', 'credential']

def find_token_fields(d, prefix=""):
    """查找可能包含 Token 的字段"""
    results = []
    for key, value in d.items():
        full_key = f"{prefix}.{key}" if prefix else key
        
        # 检查键名
        if any(keyword in key.lower() for keyword in token_keywords):
            if isinstance(value, str) and len(value) > 20:
                results.append((full_key, len(value), value[:30] + "..."))
        
        # 递归检查嵌套字典
        if isinstance(value, dict):
            results.extend(find_token_fields(value, full_key))
    
    return results

token_fields = find_token_fields(data)
if token_fields:
    for field, length, preview in token_fields:
        print(f"  {field}: ({length} chars) {preview}")
else:
    print("  未找到明显的 Token 字段")

print("\n提示: 请查看上述结构，确认 Token 字段的实际名称")

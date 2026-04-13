#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
设置 Git 仓库并推送到远程服务器
"""
import subprocess
import os

def run_command(cmd, cwd=None):
    """运行命令并返回结果"""
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding='utf-8'
        )
        return result.returncode == 0, result.stdout, result.stderr
    except Exception as e:
        return False, "", str(e)

def main():
    print("=" * 70)
    print("设置 Git 仓库")
    print("=" * 70)
    
    # 工作目录
    work_dir = r"D:\Kiro\testopenclaw"
    
    print(f"\n工作目录: {work_dir}")
    print("\n步骤:")
    
    # 1. 检查是否已经是 git 仓库
    print("\n[1/8] 检查 Git 状态...")
    if os.path.exists(os.path.join(work_dir, ".git")):
        print("  ✓ 已存在 .git 目录")
    else:
        print("  → 初始化 Git 仓库...")
        success, stdout, stderr = run_command("git init", work_dir)
        if success:
            print("  ✓ Git 仓库初始化成功")
        else:
            print(f"  ✗ 初始化失败: {stderr}")
            return
    
    # 2. 配置 Git 用户信息
    print("\n[2/8] 配置 Git 用户信息...")
    run_command('git config user.name "zhuyl"', work_dir)
    run_command('git config user.email "zhuyl@local"', work_dir)
    print("  ✓ 用户信息已配置")
    
    # 3. 创建 .gitignore
    print("\n[3/8] 创建 .gitignore...")
    gitignore_content = """# Python
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
env/
venv/
*.egg-info/
dist/
build/

# Node
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.next/
out/

# IDE
.vscode/
.idea/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db
desktop.ini

# Logs
*.log
logs/

# Temp
*.tmp
*.temp
.cache/

# Env
.env
.env.local

# Lock files
*.lock
package-lock.json
yarn.lock

# Backup
*.bak
*.backup
*_backup.*
"""
    
    gitignore_path = os.path.join(work_dir, ".gitignore")
    with open(gitignore_path, 'w', encoding='utf-8') as f:
        f.write(gitignore_content)
    print("  ✓ .gitignore 已创建")
    
    # 4. 添加所有文件
    print("\n[4/8] 添加文件到 Git...")
    success, stdout, stderr = run_command("git add .", work_dir)
    if success:
        print("  ✓ 文件已添加")
    else:
        print(f"  ⚠ 添加文件时有警告: {stderr}")
    
    # 5. 提交
    print("\n[5/8] 提交更改...")
    commit_msg = "Initial commit: OpenClaw Multi-Agent Hub with dashboard updates"
    success, stdout, stderr = run_command(f'git commit -m "{commit_msg}"', work_dir)
    if success:
        print("  ✓ 提交成功")
    else:
        if "nothing to commit" in stderr:
            print("  ℹ 没有新的更改需要提交")
        else:
            print(f"  ⚠ 提交时有警告: {stderr}")
    
    # 6. 添加远程仓库
    print("\n[6/8] 配置远程仓库...")
    remote_url = "http://zhuyl:999999yylx%60@172.16.0.108/zhuyl/openclaw.git"
    
    # 检查是否已有 origin
    success, stdout, stderr = run_command("git remote get-url origin", work_dir)
    if success:
        print("  → 更新现有的 origin...")
        run_command(f'git remote set-url origin {remote_url}', work_dir)
    else:
        print("  → 添加新的 origin...")
        run_command(f'git remote add origin {remote_url}', work_dir)
    print("  ✓ 远程仓库已配置")
    
    # 7. 设置默认分支
    print("\n[7/8] 设置默认分支...")
    run_command("git branch -M main", work_dir)
    print("  ✓ 默认分支设置为 main")
    
    # 8. 推送到远程
    print("\n[8/8] 推送到远程仓库...")
    print("  → 正在推送...")
    success, stdout, stderr = run_command("git push -u origin main --force", work_dir)
    
    if success or "Everything up-to-date" in stderr:
        print("  ✓ 推送成功！")
    else:
        print(f"  ✗ 推送失败: {stderr}")
        print("\n可能的原因:")
        print("  1. 远程仓库不存在，需要先在 GitLab 创建仓库")
        print("  2. 网络连接问题")
        print("  3. 认证信息错误")
        print("\n手动推送命令:")
        print(f"  cd {work_dir}")
        print(f"  git push -u origin main")
        return
    
    print("\n" + "=" * 70)
    print("✓ Git 设置完成！")
    print("=" * 70)
    print(f"\n远程仓库: http://172.16.0.108/zhuyl/openclaw.git")
    print(f"分支: main")
    print(f"\n查看状态: git status")
    print(f"查看日志: git log")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""测试 Trae 认证"""

from pathlib import Path
import sys

# 添加当前目录到 Python 路径
sys.path.insert(0, str(Path(__file__).parent))

def test_trae_auth():
    """测试 Trae 认证管理器"""
    print("\n" + "=" * 60)
    print("  Trae 认证测试")
    print("=" * 60 + "\n")
    
    try:
        from kiro.auth_trae import TraeAuthManager
        print("[✓] TraeAuthManager 导入成功")
        
        # 测试创建实例
        storage_file = r"C:\Users\zhuyulin\AppData\Roaming\Trae CN\User\globalStorage\storage.json"
        
        if not Path(storage_file).exists():
            print(f"[✗] 文件不存在: {storage_file}")
            print("\n请确认:")
            print("  1. Trae CN 已安装")
            print("  2. 已在 Trae CN 中登录")
            return False
        
        print(f"[✓] 找到 storage.json")
        
        # 创建认证管理器
        auth = TraeAuthManager(storage_file)
        print(f"[✓] TraeAuthManager 创建成功")
        
        # 加载 Token
        tokens = auth.load_tokens()
        print(f"[✓] Token 加载成功")
        
        # 显示信息（不显示完整 Token）
        has_access = bool(tokens.get('access_token'))
        has_refresh = bool(tokens.get('refresh_token'))
        user_name = tokens.get('user', {}).get('name', 'N/A')
        
        print(f"\n认证信息:")
        print(f"  - Access Token: {'✓ 存在' if has_access else '✗ 缺失'}")
        print(f"  - Refresh Token: {'✓ 存在' if has_refresh else '✗ 缺失'}")
        print(f"  - 用户名: {user_name}")
        
        if tokens.get('expires_at'):
            import time
            from datetime import datetime
            
            expires_at = tokens['expires_at']
            try:
                # 尝试解析 ISO 8601 格式
                if isinstance(expires_at, str):
                    # 解析 ISO 8601 时间字符串
                    dt = datetime.fromisoformat(expires_at.replace('Z', '+00:00'))
                    expires_timestamp = dt.timestamp()
                else:
                    # 假设是毫秒时间戳
                    expires_timestamp = int(expires_at) / 1000
                
                expires_in = expires_timestamp - time.time()
                if expires_in > 0:
                    print(f"  - Token 有效期: {expires_in / 3600:.1f} 小时")
                else:
                    print(f"  - Token 状态: ⚠️ 已过期")
            except Exception as e:
                print(f"  - Token 过期时间: {expires_at} (无法解析)")
        
        print("\n" + "=" * 60)
        print("  测试通过！")
        print("=" * 60 + "\n")
        
        return True
        
    except Exception as e:
        print(f"\n[✗] 错误: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        return False


if __name__ == "__main__":
    success = test_trae_auth()
    sys.exit(0 if success else 1)

# -*- coding: utf-8 -*-

"""
Trae Authentication Manager

Handles authentication for Trae API using CLI Token or storage.json file.
"""

import json
import time
from pathlib import Path
from typing import Optional, Dict, Any
from loguru import logger


class TraeAuthManager:
    """
    Trae 认证管理器
    
    支持两种认证方式：
    1. CLI Token（推荐）- 从企业控制台获取
    2. storage.json - 从 Trae CN 的 storage.json 文件中读取
    """
    
    def __init__(self, cli_token: Optional[str] = None, storage_file: Optional[str] = None):
        """
        初始化 Trae 认证管理器
        
        Args:
            cli_token: Trae CLI Token（优先使用）
            storage_file: storage.json 文件路径（备选）
        """
        self.cli_token = cli_token
        self.storage_file = Path(storage_file) if storage_file else None
        self._token_data: Optional[Dict[str, Any]] = None
        self._last_load_time: float = 0
        self._cache_ttl: int = 60  # 缓存 60 秒
        
        if cli_token:
            logger.info(f"Trae Auth Manager initialized with CLI Token")
        elif storage_file:
            logger.info(f"Trae Auth Manager initialized with storage file: {self.storage_file}")
        else:
            logger.warning("Trae Auth Manager initialized without credentials")
    
    def _load_storage_file(self) -> Dict[str, Any]:
        """
        从 storage.json 加载数据
        
        Returns:
            storage.json 的完整内容
            
        Raises:
            FileNotFoundError: 文件不存在
            json.JSONDecodeError: JSON 格式错误
        """
        if not self.storage_file.exists():
            raise FileNotFoundError(
                f"Trae storage file not found: {self.storage_file}\n"
                f"Please make sure Trae CN is installed and you are logged in."
            )
        
        try:
            with open(self.storage_file, 'r', encoding='utf-8') as f:
                data = json.load(f)
            return data
        except json.JSONDecodeError as e:
            raise ValueError(f"Invalid JSON in storage file: {e}")
    
    def _extract_tokens(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """
        从 storage.json 数据中提取 Token 信息
        
        Args:
            data: storage.json 的完整内容
            
        Returns:
            包含 access_token, refresh_token, expires_at 等信息的字典
            
        Raises:
            ValueError: 找不到必需的 Token 字段
        """
        # Trae CN 的 Token 存储在特殊字段中
        auth_key = 'iCubeAuthInfo://icube.cloudide'
        
        if auth_key not in data:
            raise ValueError(
                f"No authentication data found in storage.json (missing '{auth_key}'). "
                "Please make sure you are logged in to Trae CN."
            )
        
        # 解析嵌套的 JSON 字符串
        try:
            auth_data = json.loads(data[auth_key])
        except json.JSONDecodeError as e:
            raise ValueError(f"Invalid JSON in authentication data: {e}")
        
        # 提取 Token（尝试多种可能的字段名）
        access_token = (
            auth_data.get('token') or 
            auth_data.get('accessToken') or 
            auth_data.get('access_token') or
            auth_data.get('jwt')
        )
        
        refresh_token = (
            auth_data.get('refreshToken') or 
            auth_data.get('refresh_token')
        )
        
        expires_at = (
            auth_data.get('expiredAt') or 
            auth_data.get('expiresAt') or
            auth_data.get('expires_at') or
            auth_data.get('expireTime')
        )
        
        if not access_token:
            raise ValueError(
                "No access token found in authentication data. "
                "Please make sure you are logged in to Trae CN."
            )
        
        token_data = {
            'access_token': access_token,
            'refresh_token': refresh_token,
            'expires_at': expires_at,
            'auth_data': auth_data,  # 保留完整的认证数据
            'user': auth_data.get('user', {}),
            'raw_data': data  # 保留原始数据以备后用
        }
        
        # 记录 Token 信息（不记录完整 Token）
        logger.debug(f"Extracted tokens from storage.json")
        if expires_at:
            try:
                # 尝试转换为数字（可能是字符串或数字）
                expires_at_num = int(expires_at) if isinstance(expires_at, str) else expires_at
                expires_in = (expires_at_num / 1000) - time.time()  # 转换为秒
                logger.debug(f"Token expires in {expires_in:.0f} seconds")
            except (ValueError, TypeError):
                logger.debug(f"Could not parse expiration time: {expires_at}")
        
        return token_data
    
    def load_tokens(self, force: bool = False) -> Dict[str, Any]:
        """
        加载 Token（带缓存）
        
        Args:
            force: 是否强制重新加载（忽略缓存）
            
        Returns:
            Token 数据字典
        """
        current_time = time.time()
        
        # 检查缓存
        if not force and self._token_data and (current_time - self._last_load_time) < self._cache_ttl:
            logger.debug("Using cached token data")
            return self._token_data
        
        # 重新加载
        logger.info(f"Loading tokens from {self.storage_file}")
        data = self._load_storage_file()
        self._token_data = self._extract_tokens(data)
        self._last_load_time = current_time
        
        return self._token_data
    
    async def get_access_token(self) -> str:
        """
        获取访问令牌
        
        Returns:
            访问令牌（CLI Token 或从 storage.json 提取的 Token）
        """
        # 优先使用 CLI Token
        if self.cli_token:
            return self.cli_token
        
        # 否则从 storage.json 加载
        token_data = self.load_tokens()
        access_token = token_data['access_token']
        
        # 检查是否过期
        expires_at = token_data.get('expires_at')
        if expires_at:
            try:
                # 处理不同的过期时间格式
                if isinstance(expires_at, str):
                    # 尝试解析 ISO 8601 格式 (e.g., '2026-04-29T08:35:43.248Z')
                    from datetime import datetime
                    try:
                        # 移除 'Z' 并解析
                        dt = datetime.fromisoformat(expires_at.replace('Z', '+00:00'))
                        expires_at_num = dt.timestamp() * 1000  # 转换为毫秒
                    except ValueError:
                        # 尝试作为数字字符串解析
                        expires_at_num = int(expires_at)
                else:
                    expires_at_num = expires_at
                
                current_time = time.time() * 1000  # 转换为毫秒
                
                if current_time >= expires_at_num:
                    logger.warning("Token expired, reloading from storage.json")
                    # 强制重新加载（Trae CN 应该已经刷新了 Token）
                    token_data = self.load_tokens(force=True)
                    access_token = token_data['access_token']
            except (ValueError, TypeError) as e:
                logger.warning(f"Could not check token expiration: {e}")
                # 继续使用当前 Token
        
        return access_token
    
    def get_user_info(self) -> Dict[str, Any]:
        """
        获取用户信息
        
        Returns:
            用户信息字典
        """
        token_data = self.load_tokens()
        return token_data.get('user', {})
    
    @property
    def auth_type(self):
        """认证类型（用于兼容 Kiro AuthManager）"""
        return "TRAE"
    
    @property
    def api_host(self):
        """API 主机（用于兼容 Kiro AuthManager）"""
        # Trae AI Agent 主服务
        # 根据 Trae CN 架构分析，AI 服务使用此域名
        return "https://trae-api-cn.mchost.guru"
    
    @property
    def q_host(self):
        """Q API 主机（用于兼容 Kiro AuthManager）"""
        # Trae 主 API 网关（用于获取模型列表等）
        return "https://api.trae.com.cn"
    
    @property
    def profile_arn(self):
        """Profile ARN（Trae 不需要，返回 None）"""
        return None
    
    @property
    def region(self):
        """区域（Trae 不需要，返回默认值）"""
        return "cn"
    
    @property
    def fingerprint(self):
        """设备指纹（用于兼容 Kiro AuthManager）"""
        # Trae 可能不需要，返回固定值
        return "trae-gateway-fingerprint"


# 用于兼容性的别名
KiroAuthManager = TraeAuthManager

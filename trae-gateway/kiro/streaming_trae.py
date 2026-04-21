# -*- coding: utf-8 -*-

"""
Streaming response handling for Trae API.

This module handles streaming responses from Trae API and converts them
into OpenAI-compatible format.
"""

import json
from typing import AsyncGenerator, Dict, Any

from loguru import logger


async def stream_trae_to_openai(
    client: Any,  # httpx.AsyncClient
    response: Any,  # httpx.Response
    model_id: str,
    model_cache: Any = None,
    auth_manager: Any = None,
    **kwargs
) -> AsyncGenerator[str, None]:
    """
    Convert Trae streaming response to OpenAI streaming format.
    
    Args:
        client: httpx AsyncClient instance
        response: httpx Response instance from Trae API
        model_id: Model ID used in the request
        model_cache: Model cache (not used for Trae)
        auth_manager: Auth manager (not used for Trae)
        **kwargs: Additional parameters
        
    Returns:
        AsyncGenerator: OpenAI-compatible streaming chunks
    """
    # Generate a unique completion ID
    import uuid
    completion_id = f"chatcmpl-{uuid.uuid4().hex[:16]}"
    
    # Initialize response state
    content = ""
    finish_reason = None
    
    async for line in response.aiter_lines():
        line = line.strip()
        
        # Skip empty lines
        if not line:
            continue
        
        # Handle SSE format (data: ...)
        if line.startswith("data: "):
            data_part = line[6:]
            
            # Check for [DONE] message
            if data_part == "[DONE]":
                if content:
                    # Send final chunk with accumulated content
                    chunk = create_openai_chunk(
                        completion_id=completion_id,
                        model_id=model_id,
                        content=content,
                        finish_reason=None
                    )
                    yield chunk
                
                # Send done message
                yield "data: [DONE]\n\n"
                break
            
            try:
                # Parse JSON data
                trae_data = json.loads(data_part)
                
                # Extract content delta
                delta = trae_data.get("choices", [{}])[0].get("delta", {})
                content_delta = delta.get("content", "")
                
                # Extract finish reason
                if "finish_reason" in delta:
                    finish_reason = delta["finish_reason"]
                
                # Update accumulated content
                content += content_delta
                
                # Create OpenAI-compatible chunk
                chunk = create_openai_chunk(
                    completion_id=completion_id,
                    model_id=model_id,
                    content=content_delta,
                    finish_reason=finish_reason
                )
                
                yield chunk
                
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse Trae streaming data: {e}")
                logger.error(f"Raw data: {data_part}")
                continue
        
        # Handle any other line formats
        else:
            logger.debug(f"Unknown Trae streaming line format: {line}")


def create_openai_chunk(
    completion_id: str,
    model_id: str,
    content: str = "",
    finish_reason: Optional[str] = None
) -> str:
    """
    Create an OpenAI-compatible streaming chunk.
    
    Args:
        completion_id: Unique completion ID
        model_id: Model ID
        content: Content delta for this chunk
        finish_reason: Finish reason (if any)
        
    Returns:
        str: Formatted SSE chunk
    """
    # Create the chunk data
    chunk_data = {
        "id": completion_id,
        "object": "chat.completion.chunk",
        "created": int(json.loads(json.dumps({"now": "now"}))["now"]),
        "model": model_id,
        "choices": [
            {
                "index": 0,
                "delta": {
                    "content": content
                },
                "finish_reason": finish_reason
            }
        ]
    }
    
    # If no content and no finish_reason, it's the first chunk with only role
    if not content and not finish_reason:
        chunk_data["choices"][0]["delta"] = {
            "role": "assistant"
        }
    
    # Format as SSE chunk
    chunk_str = json.dumps(chunk_data, ensure_ascii=False)
    return f"data: {chunk_str}\n\n"


async def collect_stream_response(
    client: Any,  # httpx.AsyncClient
    response: Any,  # httpx.Response
    model_id: str,
    model_cache: Any = None,
    auth_manager: Any = None,
    **kwargs
) -> Dict[str, Any]:
    """
    Collect streaming response into a single OpenAI-compatible response.
    
    Args:
        client: httpx AsyncClient instance
        response: httpx Response instance from Trae API
        model_id: Model ID used in the request
        model_cache: Model cache (not used for Trae)
        auth_manager: Auth manager (not used for Trae)
        **kwargs: Additional parameters
        
    Returns:
        Dict: OpenAI-compatible response
    """
    # Generate a unique completion ID
    import uuid
    completion_id = f"chatcmpl-{uuid.uuid4().hex[:16]}"
    
    # Collect all chunks
    full_content = ""
    finish_reason = None
    
    async for line in response.aiter_lines():
        line = line.strip()
        
        if line.startswith("data: "):
            data_part = line[6:]
            
            if data_part == "[DONE]":
                break
            
            try:
                trae_data = json.loads(data_part)
                delta = trae_data.get("choices", [{}])[0].get("delta", {})
                
                # Append content delta
                if "content" in delta:
                    full_content += delta["content"]
                
                # Set finish reason if present
                if "finish_reason" in delta:
                    finish_reason = delta["finish_reason"]
                    break
                    
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse Trae streaming data: {e}")
                logger.error(f"Raw data: {data_part}")
                continue
    
    # Create OpenAI-compatible response
    openai_response = {
        "id": completion_id,
        "object": "chat.completion",
        "created": int(json.loads(json.dumps({"now": "now"}))["now"]),
        "model": model_id,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": full_content
                },
                "finish_reason": finish_reason or "stop"
            }
        ],
        "usage": {
            "prompt_tokens": 0,  # Trae doesn't provide token counts yet
            "completion_tokens": 0,
            "total_tokens": 0
        }
    }
    
    return openai_response

# -*- coding: utf-8 -*-

"""
Converters for transforming OpenAI format to Trae format.

This module converts OpenAI-specific formats to the format used by Trae API.
Contains functions for:
- Converting OpenAI messages to Trae format
- Converting OpenAI tools to Trae format
- Building Trae payload from OpenAI requests
"""

from typing import Any, Dict, List, Optional, Tuple

from loguru import logger

from trae.models_openai import ChatMessage, ChatCompletionRequest, Tool


def convert_openai_to_trae(request: ChatCompletionRequest) -> Dict[str, Any]:
    """
    Convert OpenAI ChatCompletionRequest to Trae API request format.
    
    Args:
        request: OpenAI ChatCompletionRequest object
        
    Returns:
        Dict: Trae API request payload
    """
    # Extract model ID (remove any gateway prefix if present)
    model_id = request.model
    if "/" in model_id:
        model_id = model_id.split("/")[-1]
    
    # Convert messages to Trae format
    trae_messages = []
    for msg in request.messages:
        trae_msg = {
            "role": msg.role,
            "content": msg.content
        }
        
        # Add tool_call if present
        if msg.role == "assistant" and msg.tool_calls:
            trae_msg["tool_calls"] = [
                {
                    "id": tool_call.id,
                    "type": tool_call.type,
                    "function": {
                        "name": tool_call.function.name,
                        "arguments": tool_call.function.arguments
                    }
                }
                for tool_call in msg.tool_calls
            ]
        
        # Add tool_call_id if present
        if msg.role == "tool" and msg.tool_call_id:
            trae_msg["tool_call_id"] = msg.tool_call_id
        
        trae_messages.append(trae_msg)
    
    # Build Trae payload
    trae_payload = {
        "model": model_id,
        "messages": trae_messages,
        "stream": request.stream,
        "temperature": request.temperature,
        "top_p": request.top_p,
        "max_tokens": request.max_tokens,
        "stop": request.stop,
        "frequency_penalty": request.frequency_penalty,
        "presence_penalty": request.presence_penalty,
    }
    
    # Add tools if present
    if request.tools:
        trae_payload["tools"] = [
            {
                "type": "function",
                "function": {
                    "name": tool.function.name,
                    "description": tool.function.description,
                    "parameters": tool.function.parameters
                }
            }
            for tool in request.tools
        ]
    
    return trae_payload

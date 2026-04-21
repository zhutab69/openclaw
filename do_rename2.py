#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script to update all remaining test files in trae-gateway/tests/unit/
"""

import os
from pathlib import Path


def apply_replacements(content: str) -> str:
    """Apply all kiro -> trae replacements to file content."""
    
    # Import replacements (order matters - more specific first)
    content = content.replace('from kiro.', 'from trae.')
    content = content.replace('import kiro.', 'import trae.')
    content = content.replace('from kiro import', 'from trae import')
    content = content.replace("import kiro\n", "import trae\n")
    content = content.replace("import kiro\r\n", "import trae\r\n")
    
    # patch() string references - these are module paths used in unittest.mock.patch()
    content = content.replace("'kiro.", "'trae.")
    content = content.replace('"kiro.', '"trae.')
    
    # Class name replacements
    content = content.replace('KiroAuthManager', 'TraeAuthManager')
    content = content.replace('KiroHttpClient', 'TraeHttpClient')
    content = content.replace('KiroEvent', 'TraeEvent')
    content = content.replace('KiroErrorInfo', 'TraeErrorInfo')
    content = content.replace('KiroErrorReason', 'TraeErrorReason')
    
    # Function name replacements (longer/more specific first)
    content = content.replace('stream_kiro_to_openai_internal', 'stream_trae_to_openai_internal')
    content = content.replace('stream_kiro_to_openai', 'stream_trae_to_openai')
    content = content.replace('get_kiro_headers', 'get_trae_headers')
    content = content.replace('build_kiro_payload', 'build_trae_payload')
    content = content.replace('enhance_kiro_error', 'enhance_trae_error')
    content = content.replace('get_model_id_for_kiro', 'get_model_id_for_trae')
    content = content.replace('get_kiro_refresh_url', 'get_trae_refresh_url')
    content = content.replace('get_kiro_api_host', 'get_trae_api_host')
    content = content.replace('get_kiro_q_host', 'get_trae_q_host')
    content = content.replace('parse_kiro_stream', 'parse_trae_stream')
    
    # Config variable replacements
    content = content.replace('KIRO_CREDS_FILE', 'TRAE_CREDS_FILE')
    content = content.replace('KIRO_CLI_DB_FILE', 'TRAE_CLI_DB_FILE')
    content = content.replace('KIRO_REFRESH_URL_TEMPLATE', 'TRAE_REFRESH_URL_TEMPLATE')
    content = content.replace('KIRO_API_HOST_TEMPLATE', 'TRAE_API_HOST_TEMPLATE')
    content = content.replace('KIRO_Q_HOST_TEMPLATE', 'TRAE_Q_HOST_TEMPLATE')
    content = content.replace('KIRO_CHAT_API_ENDPOINT', 'TRAE_CHAT_API_ENDPOINT')
    
    # Comment/docstring replacements
    content = content.replace('# Kiro Gateway', '# Trae Gateway')
    content = content.replace('Kiro Gateway', 'Trae Gateway')
    content = content.replace('Kiro API', 'Trae API')
    content = content.replace('for Kiro', 'for Trae')
    content = content.replace('https://github.com/jwadow/kiro-gateway', '(Trae Gateway - based on Kiro Gateway)')
    content = content.replace('"Kiro Gateway is running"', '"Trae Gateway is running"')
    content = content.replace('kiro-gateway', 'trae-gateway')
    
    # String literal replacements
    content = content.replace('"kiro_desktop"', '"trae_desktop"')
    content = content.replace("'kiro_desktop'", "'trae_desktop'")
    content = content.replace('x-amzn-kiro-agent-mode', 'x-amzn-trae-agent-mode')
    content = content.replace('KiroIDE', 'TraeIDE')
    
    return content


def main():
    base = Path('trae-gateway')
    tests_unit = base / 'tests' / 'unit'
    
    updated = 0
    for py_file in sorted(tests_unit.glob('*.py')):
        content = py_file.read_text(encoding='utf-8')
        new_content = apply_replacements(content)
        if new_content != content:
            py_file.write_text(new_content, encoding='utf-8')
            print(f"Updated: {py_file}")
            updated += 1
        else:
            print(f"No changes: {py_file}")
    
    # Also update integration tests
    tests_integration = base / 'tests' / 'integration'
    if tests_integration.exists():
        for py_file in sorted(tests_integration.glob('*.py')):
            content = py_file.read_text(encoding='utf-8')
            new_content = apply_replacements(content)
            if new_content != content:
                py_file.write_text(new_content, encoding='utf-8')
                print(f"Updated: {py_file}")
                updated += 1
    
    print(f"\nTotal files updated: {updated}")


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Add AI tab localization keys to Localizable.xcstrings"""

import json
import sys

# AI tab translations
AI_TAB_KEYS = {
    "ai_tab_title": {"en": "AI Gateway", "zh-Hans": "AI 网关"},
    "ai_tab_credentials_section": {"en": "API Key", "zh-Hans": "API 密钥"},
    "ai_tab_api_key_placeholder": {"en": "Paste AI Gateway key", "zh-Hans": "粘贴 AI 网关密钥"},
    "ai_tab_save_key": {"en": "Save Key", "zh-Hans": "保存密钥"},
    "ai_tab_clear_key": {"en": "Clear Key", "zh-Hans": "清除密钥"},
    "ai_tab_enter_key_hint": {"en": "Enter your AI Gateway key to unlock the tools.", "zh-Hans": "输入你的 AI 网关密钥以解锁工具。"},
    "ai_tab_unsaved_changes": {"en": "Unsaved changes", "zh-Hans": "有未保存的更改"},
    "ai_tab_validating": {"en": "Validating...", "zh-Hans": "验证中..."},
    "ai_tab_key_valid": {"en": "Key verified", "zh-Hans": "密钥已验证"},
    "ai_tab_models_section": {"en": "Model Catalog", "zh-Hans": "模型目录"},
    "ai_tab_load_models": {"en": "Load Models", "zh-Hans": "加载模型"},
    "ai_tab_refresh_models": {"en": "Refresh Models", "zh-Hans": "刷新模型"},
    "ai_tab_default_model": {"en": "Default", "zh-Hans": "默认"},
    "ai_tab_set_default": {"en": "Set as Default", "zh-Hans": "设为默认"},
    "ai_tab_tester_section": {"en": "Chat Tester", "zh-Hans": "聊天测试"},
    "ai_tab_system_prompt": {"en": "System prompt", "zh-Hans": "系统提示"},
    "ai_tab_default_system_prompt": {"en": "You are a helpful audiobook assistant.", "zh-Hans": "你是一个有用的有声读物助手。"},
    "ai_tab_prompt_placeholder": {"en": "Ask something to verify the model...", "zh-Hans": "输入问题以验证模型..."},
    "ai_tab_run_test": {"en": "Send Test", "zh-Hans": "发送测试"},
    "ai_tab_response_label": {"en": "Latest response", "zh-Hans": "最新响应"},
    "ai_tab_no_content": {"en": "No content in response.", "zh-Hans": "响应中无内容。"},
    "ai_tab_usage_summary": {"en": "Prompt: %ld | Completion: %ld | Total: %ld | Cost: $%.4f", "zh-Hans": "提示: %ld | 完成: %ld | 总计: %ld | 费用: $%.4f"},
    "ai_tab_generation_tokens": {"en": "Prompt tokens: %ld | Completion tokens: %ld", "zh-Hans": "提示 Token: %ld | 完成 Token: %ld"},
    "ai_tab_generation_latency": {"en": "Latency: %.2fs | Duration: %.2fs", "zh-Hans": "延迟: %.2fs | 持续: %.2fs"},
    "ai_tab_credits_section": {"en": "Credits", "zh-Hans": "额度"},
    "ai_tab_balance_label": {"en": "Balance: %@", "zh-Hans": "余额: %@"},
    "ai_tab_total_used_label": {"en": "Total used: %@", "zh-Hans": "总使用: %@"},
    "ai_tab_pricing_template": {"en": "Input: %@ | Output: %@", "zh-Hans": "输入: %@ | 输出: %@"},
    "ai_tab_model_group_other": {"en": "Other Providers", "zh-Hans": "其他供应商"},
    "ai_tab_selected_model_summary": {"en": "Current default: %@", "zh-Hans": "当前默认: %@"},
    "tts_tab": {"en": "TTS", "zh-Hans": "语音"},
    "tts_tab_title": {"en": "Speech Tools", "zh-Hans": "语音工具"},
    "ai_tab_fetch_credits": {"en": "Fetch Credits", "zh-Hans": "获取额度"},
    "ai_tab_generation_section": {"en": "Generation Lookup", "zh-Hans": "生成查询"},
    "ai_tab_generation_placeholder": {"en": "Enter generation ID", "zh-Hans": "输入生成 ID"},
    "ai_tab_lookup_generation": {"en": "Lookup", "zh-Hans": "查询"},
    "ai_tab_generation_empty": {"en": "Enter a generation ID first.", "zh-Hans": "请先输入生成 ID。"},
    "ai_tab_generation_cost": {"en": "Cost: $%.4f", "zh-Hans": "费用: $%.4f"},
    "ai_tab_missing_key": {"en": "Add an API key first.", "zh-Hans": "请先添加 API 密钥。"},
    "ai_tab_empty_key": {"en": "API key cannot be empty.", "zh-Hans": "API 密钥不能为空。"},
    "ai_tab_refresh": {"en": "Refresh", "zh-Hans": "刷新"},
}

def add_ai_keys(xcstrings_path):
    """Add AI tab keys to the xcstrings file"""
    with open(xcstrings_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    # Add each key
    for key, translations in AI_TAB_KEYS.items():
        data['strings'][key] = {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": translations["en"]
                    }
                },
                "zh-Hans": {
                    "stringUnit": {
                        "state": "translated",
                        "value": translations["zh-Hans"]
                    }
                }
            }
        }

    # Write back
    with open(xcstrings_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    print(f"✅ Added {len(AI_TAB_KEYS)} AI tab keys to {xcstrings_path}")

if __name__ == "__main__":
    xcstrings_path = "AudiobookPlayer/Localizable.xcstrings"
    add_ai_keys(xcstrings_path)

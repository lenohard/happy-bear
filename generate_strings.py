#!/usr/bin/env python3
"""Generate Localizable.xcstrings file for iOS localization."""

import json
from pathlib import Path

# Define all strings with English and Chinese translations
STRINGS = {
    # Tab Navigation
    "library_tab": ("Library", "图书馆"),
    "playing_tab": ("Playing", "播放中"),
    "sources_tab": ("Sources", "来源"),

    # Library View
    "library_title": ("Library", "图书馆"),
    "empty_library_message": ("Add collections to get started", "添加藏书集合以开始"),
    "empty_library_hint": ("Tap \"Import\" to choose a source and add your first audiobook collection.", "点击\"导入\"选择来源并添加您的第一个有声书集合。"),
    "loading_library": ("Loading your library...", "正在加载您的图书馆..."),
    "collections_section": ("Collections", "藏书集合"),
    "import_button": ("Import", "导入"),
    "reload_button": ("Reload", "重新加载"),
    "play_collection_accessibility": ("Play %@", "播放 %@"),

    # Playing View
    "playing_title": ("Playing", "正在播放"),
    "resume_listening": ("Resume Listening", "继续收听"),
    "play_last_position": ("Play from Last Position", "从上次位置播放"),
    "listening_history": ("Listening History", "收听历史"),
    "nothing_playing_yet": ("Nothing playing yet", "还没有播放任何内容"),
    "nothing_playing_message": ("Select an audiobook from your library to start listening. Your most recent progress will appear here.", "从您的图书馆中选择有声书开始收听。您最近的进度将显示在此处。"),
    "open_collection": ("Open Collection", "打开藏书集合"),
    "last_position": ("Last position: %@", "上次位置：%@"),
    "no_listening_progress": ("No listening progress recorded yet.", "尚未记录任何收听进度。"),

    # Sources View
    "sources_title": ("Sources", "来源"),
    "baidu_netdisk": ("Baidu Netdisk", "百度网盘"),
    "local_files_coming_soon": ("Local Files (Coming Soon)", "本地文件（即将推出）"),
    "file_details": ("File Details", "文件详情"),
    "file_details_hint": ("Select \"Close\" and use the toolbar actions in the browser to download or stream once implemented.", "选择\"关闭\"并使用浏览器中的工具栏操作以在实现后下载或流式传输。"),
    "close_button": ("Close", "关闭"),
    "netdisk_file_title": ("Netdisk File", "网盘文件"),
    "browse_baidu_netdisk": ("Browse Baidu Netdisk", "浏览百度网盘"),
    "sign_in_with_baidu": ("Sign in with Baidu", "与百度登录"),
    "sign_out_button": ("Sign Out", "登出"),
    "baidu_auth_section": ("Baidu Cloud Sign-In", "百度云登录"),
    "access_token_acquired": ("Access token acquired.", "获取了访问令牌。"),
    "expires_label": ("Expires %@", "过期时间 %@"),
    "scopes_label": ("Scopes: %@", "作用域：%@"),
    "connect_baidu_message": ("Connect your Baidu Netdisk account to browse and download audiobooks.", "连接您的百度网盘账户以浏览和下载有声书。"),

    # Alerts & Messages
    "connect_baidu_first": ("Connect Baidu First", "先连接百度"),
    "connect_baidu_alert_message": ("Open the Sources tab to sign in with your Baidu account before importing or streaming audio.", "打开\"来源\"标签签入您的百度账户，然后再导入或流媒体音频。"),
    "connect_baidu_before_stream": ("Open the Sources tab to sign in with your Baidu account before streaming audio.", "打开\"来源\"标签签入您的百度账户，然后再流媒体音频。"),
    "duplicate_import_title": ("Already Imported", "已导入"),
    "duplicate_import_message": ("\"%@\" already uses this folder. What would you like to do?", '"%@"已使用此文件夹。您想做什么？'),
    "view_collection_button": ("View Collection", "查看藏书集合"),
    "import_again_button": ("Import Again", "再次导入"),
    "ok_button": ("OK", "确定"),

    # BaiduNetdiskBrowserView
    "current_path_label": ("Current Path", "当前路径"),
    "up_one_level_button": ("Up One Level", "上一级"),
    "refresh_button": ("Refresh", "刷新"),
    "use_this_folder": ("Use This Folder", "使用此文件夹"),
    "use_this_folder_count": ("Use This Folder (%d)", "使用此文件夹（%d）"),
    "folder_empty": ("This folder is empty.", "此文件夹为空。"),
    "no_results_for": ('No results for "%@"', '找不到"%@"的结果'),
    "unable_to_load_directory": ("Unable to load directory", "无法加载目录"),

    # CreateCollectionView
    "scanning_folder": ("Scanning folder...", "正在扫描文件夹..."),
    "preparing": ("Preparing...", "准备中..."),
    "add_to_library": ("Add to Library", "添加到图书馆"),
    "non_audio_files_notice": ("... and %d more", "...还有 %d 个"),
    "more_tracks_notice": ("... and %d more tracks", "...还有 %d 个音轨"),

    # CollectionDetailView
    "collection_not_found": ("Collection Not Found", "未找到藏书集合"),
    "collection_not_found_message": ("This audiobook collection could not be located in your library.", "找不到您的图书馆中的这个有声书集合。"),
    "track_count_and_size": ("%d tracks • %@ total", "%d 个音轨 • 总计 %@"),
    "no_audio_tracks": ("No audio tracks found.", "找不到音频音轨。"),
    "no_search_results": ('No results for "%@".', '找不到"%@"的结果。'),
    "sign_in_on_sources_tab": ("Sign in on the Sources tab before streaming from Baidu Netdisk.", '在"来源"标签中登录，然后从百度网盘流式传输。'),

    # Cache Status
    "fully_cached": ("Fully Cached", "完全缓存"),
    "partially_cached": ("Partially Cached", "部分缓存"),
    "not_cached": ("Not Cached", "未缓存"),
    "local_file": ("Local File", "本地文件"),

    # Cache Tools
    "cache_tools_label": ("Cache Status", "缓存状态"),
    "cache_tools_status_warning": (
        "Seeking outside the cached range will resume streaming.",
        "超出缓存范围的拖动将恢复流式播放。"
    ),
    "cache_tools_retention": ("Retention: %d %@", "保留：%d %@"),
    "cache_tools_day": ("day", "天"),
    "cache_tools_days": ("days", "天"),
    "cache_tools_status_streaming": (
        "Streaming directly from Baidu Netdisk.",
        "正在直接从百度网盘流式播放。"
    ),
    "cache_tools_manage_button": ("Manage Cache", "管理缓存"),

    # Local Files Section
    "local_files_section": ("Local Files", "本地文件"),

    # Collection Detail & Track Management
    "add_tracks_button": ("Add Tracks", "添加曲目"),
    "remove_track_action": ("Remove", "删除"),
    "remove_track_prompt": ("Remove '{{name}}' from this collection?", "从此合集中删除 '{{name}}'？"),
    "search_tracks_prompt": ("Search tracks", "搜索曲目"),
    "collection_not_found": ("Collection Not Found", "找不到合集"),
    "collection_not_found_message": (
        "This collection appears to have been deleted or is no longer available.",
        "此合集似乎已被删除或不再可用。"
    ),
    "no_audio_tracks": ("No audio tracks", "无音频曲目"),
    "no_search_results": ("No results found for \"%@\"", "未找到 \"%@\" 的结果"),
    "track_count_and_size": ("%d tracks • %@", "%d 首曲目 • %@"),

    # Track Picker View
    "track_picker_selected_count": ("%d selected", "已选择 %d"),
    "track_picker_selection_summary": (
        "Selected files will be added to this collection",
        "所选文件将添加到此合集"
    ),
    "track_picker_placeholder_title": ("No Tracks Selected", "未选择曲目"),
    "track_picker_placeholder_message": (
        "Browse Baidu Netdisk to select audio files to add",
        "浏览百度网盘以选择要添加的音频文件"
    ),
    "track_picker_browse_button": ("Browse Netdisk", "浏览网盘"),
    "track_picker_remove_selected": ("Remove from selection", "从选择中移除"),
    "track_picker_add_selected": ("Add Selected", "添加所选"),
    "track_picker_collection_readonly": ("This collection cannot be modified", "无法修改此合集"),

    # Favorites Feature
    "favorite_tracks_title": ("Favorite Tracks", "收藏音轨"),
    "favorite_tracks_empty": ("No favorite tracks yet", "还没有收藏任何音轨"),
    "add_to_favorites": ("Add to Favorites", "添加到收藏"),
    "remove_from_favorites": ("Remove from Favorites", "从收藏中移除"),
    "favorites_section": ("Favorites", "收藏"),
    "rename_action": ("Rename", "重命名"),
    "rename_collection_title": ("Rename Collection", "重命名合集"),
    "rename_track_title": ("Rename Track", "重命名曲目"),
    "name_field_label": ("Name", "名称"),
    "more_options_accessibility": ("More options", "更多选项"),
}

def generate_xcstrings():
    """Generate Localizable.xcstrings JSON structure."""
    xcstrings = {
        "sourceLanguage": "en",
        "strings": {}
    }

    for key, (en_text, zh_text) in STRINGS.items():
        xcstrings["strings"][key] = {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": en_text
                    }
                },
                "zh-Hans": {
                    "stringUnit": {
                        "state": "translated",
                        "value": zh_text
                    }
                }
            }
        }

    return xcstrings

def main():
    project_root = Path(__file__).parent
    audio_player_dir = project_root / "AudiobookPlayer"

    # Create Localizable.xcstrings
    xcstrings = generate_xcstrings()
    xcstrings_path = audio_player_dir / "Localizable.xcstrings"

    with open(xcstrings_path, 'w', encoding='utf-8') as f:
        json.dump(xcstrings, f, indent=2, ensure_ascii=False)

    print(f"✅ Created {xcstrings_path}")
    print(f"   Total strings: {len(STRINGS)}")
    print(f"   Languages: en, zh-Hans")

if __name__ == "__main__":
    main()

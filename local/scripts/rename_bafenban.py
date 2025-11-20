#!/usr/bin/env python3
import os
import re
import argparse
from typing import List, Tuple

NOISE_TOKENS = [
    "完整版", "剪辑版", "剪辑", "官方", "高清", "中字", "中文字幕", "无广告",
    "合集", "重制版", "remastered", "official", "mv", "podcast",
    "八分半播客", "八分半", "b站", "bilibili", "哔哩哔哩", "抖音", "youtube", "yt", "微博",
    "剪片", "片段", "预告", "trailer", "音频版"
]

BRACKET_PAIRS = [
    ('[', ']'), ('(', ')'), ('【', '】'), ('（', '）'), ('{', '}')
]


def natural_key(s: str) -> List:
    parts = re.split(r'(\d+)', s)
    key = []
    for p in parts:
        if p.isdigit():
            key.append(int(p))
        else:
            key.append(p.lower())
    return key


def normalize_spaces(s: str) -> str:
    s = s.replace('\u3000', ' ')
    s = re.sub(r'\s+', ' ', s)
    return s.strip()


def remove_hashtags(s: str) -> str:
    # remove inline hashtags like #词条 或 #多词条
    return re.sub(r'#\S+', ' ', s)


def remove_noise_brackets(s: str) -> str:
    # remove any bracketed segments for defined bracket pairs (NOT including 《》 book title marks)
    for left, right in BRACKET_PAIRS:
        s = re.sub(
            rf'{re.escape(left)}[^{re.escape(right)}]*{re.escape(right)}', '', s)
    return s


def remove_noise_tokens(s: str) -> str:
    out = s
    for t in NOISE_TOKENS:
        # remove tokens regardless of word boundaries to support CJK
        out = re.sub(re.escape(t), '', out, flags=re.IGNORECASE)
    return normalize_spaces(out)


def strip_leading_episode_patterns(s: str) -> str:
    out = s
    # Remove any prefix up to and including "八分半"/"八分半播客" with following separators
    out = re.sub(r'^.*?(?:八分半|八分半播客)\s*[-—_：:]*\s*', '', out)
    # Remove "EP12 -", "E12:", "Episode 12 -"
    out = re.sub(
        r'^(?:episode|ep|e|p)\s*\d+\s*[-—_：:]*\s*', '', out, flags=re.IGNORECASE)
    # Remove "第12期 -", "第十二期:"
    out = re.sub(r'^第[一二三四五六七八九十百千零〇\d]+期\s*[-—_：:]*\s*', '', out)
    # Remove numeric leading like "12 -", "12:", "12. ", and composite "139-75. "
    out = re.sub(r'^\d+\s*[.\-—_：:]\s*\d+\s*[.\-—_：:]*\s*', '', out)  # 139-75.
    out = re.sub(r'^\d+\s*[.\-—_：:]\s*', '', out)  # 12 -, 12:
    # Remove leading "番外" label if present
    out = re.sub(r'^(?:番外)\s*[-—_：:]*\s*', '', out)
    return normalize_spaces(out)


def clean_title_from_filename(name: str) -> str:
    stem = os.path.splitext(name)[0]
    stem = normalize_spaces(stem)
    # remove obvious decorations/noise first
    stem = remove_hashtags(stem)
    stem = remove_noise_brackets(stem)
    # trim common prefixes (series/episode markers)
    stem = strip_leading_episode_patterns(stem)
    # if contains "┃", take the last segment as title
    if "┃" in stem:
        parts = [p.strip() for p in stem.split("┃") if p.strip()]
        if parts:
            stem = parts[-1]
    # final token cleanup (including series words)
    stem = remove_noise_tokens(stem)
    # Collapse duplicate separators and trim trailing hyphens/colons/underscores
    stem = re.sub(r'[-—_：:]+\s*$', '', stem)
    # Normalize spaces
    stem = normalize_spaces(stem)
    return stem


def build_new_name(idx: int, title: str, ext: str) -> str:
    return f"八分半 - {str(idx).zfill(3)} - {title}{ext}"


def list_mp3_files(dir_path: str) -> List[str]:
    return sorted(
        [f for f in os.listdir(dir_path) if f.lower().endswith(
            '.mp3') and not f.startswith('.')],
        key=natural_key
    )


def compute_plan(dir_path: str, start_index: int = 1) -> List[Tuple[str, str]]:
    files = list_mp3_files(dir_path)
    plan = []
    used_targets = set()
    idx = start_index
    for f in files:
        title = clean_title_from_filename(f)
        ext = os.path.splitext(f)[1]
        new_name = build_new_name(idx, title, ext)
        candidate = new_name
        # handle duplicates by appending " (dupN)"
        dup_n = 2
        while candidate in used_targets or os.path.exists(os.path.join(dir_path, candidate)):
            candidate = f"{os.path.splitext(new_name)[0]} (dup{dup_n}){ext}"
            dup_n += 1
        plan.append((f, candidate))
        used_targets.add(candidate)
        idx += 1
    return plan


def print_plan(dir_path: str, plan: List[Tuple[str, str]]) -> None:
    print(f"# 目录: {dir_path}")
    print("# 预览（不执行重命名）：")
    width = max((len(a) for a, _ in plan), default=0)
    for old, new in plan:
        collision = os.path.exists(os.path.join(dir_path, new))
        flag = "  [冲突: 目标已存在]" if collision else ""
        print(f"{old.ljust(width)}  ->  {new}{flag}")
    print(f"\n# 文件数: {len(plan)}")


def apply_plan(dir_path: str, plan: List[Tuple[str, str]], dry_run: bool) -> None:
    if dry_run:
        print_plan(dir_path, plan)
        return
    # actual rename
    for old, new in plan:
        src = os.path.join(dir_path, old)
        dst = os.path.join(dir_path, new)
        if src == dst:
            continue
        if os.path.exists(dst):
            print(f"[跳过] 目标已存在: {dst}")
            continue
        os.rename(src, dst)
        print(f"[重命名] {old} -> {new}")
    print("# 重命名完成")


def main():
    parser = argparse.ArgumentParser(
        description="统一重命名：八分半 - 001 - 标题（标题取自现有文件名，保留中文符号，统一半角空格）")
    parser.add_argument(
        "directory", help="目标目录（例如 /Volumes/clover/八分半/mp3_audio/）")
    parser.add_argument("--start", type=int, default=1, help="编号起始值，默认 1")
    parser.add_argument("--apply", action="store_true",
                        help="执行重命名（不加该参数则仅预览）")
    args = parser.parse_args()

    dir_path = args.directory
    if not os.path.isdir(dir_path):
        print(f"目录不存在或不是目录: {dir_path}")
        return
    plan = compute_plan(dir_path, start_index=args.start)
    apply_plan(dir_path, plan, dry_run=(not args.apply))


if __name__ == "__main__":
    main()

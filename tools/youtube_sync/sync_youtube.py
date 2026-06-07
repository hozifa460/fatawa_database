"""YouTube sync — generates 3 SEPARATE files per channel
(<categoryId>.live.json / .videos.json / .shorts.json) and auto-updates
index.json. Also deletes the OLD single <categoryId>.youtube.json file
(if present) and removes its path from index.json.

Each file matches the RecitationCategory schema (same `id`), so the Dart
cascade merge in `_fetchYouTubeChannels` automatically concatenates the
`items[]` arrays from the 3 files into one in-memory category.

Used by both GitHub Actions (.github/workflows/youtube-sync.yml) and
GitLab CI (radio_islam/.gitlab-ci.yml).

Idempotent: re-runs are safe.
  - If a file already exists, it is overwritten with fresh RSS data.
  - If a path is already in index.json, it is NOT re-added.
  - Old .youtube.json files are removed in the same commit.

Classification (same logic as Dart `parseYouTubeRss`):
  - Shorts: title contains "shorts" / "شورتس" / "شورت" / "#short"
  - Live:   title contains "live" / "بث" / "مباشر" / "لايف" / "on air"
            AND not negated by "not live" / "ليس بث" / "لا بث" / "غير مباشر"
  - Videos: everything else
"""
import sys
import io

if sys.platform == "win32":
    try:
        sys.stdout = io.TextIOWrapper(
            sys.stdout.buffer, encoding="utf-8", errors="replace"
        )
        sys.stderr = io.TextIOWrapper(
            sys.stderr.buffer, encoding="utf-8", errors="replace"
        )
    except Exception:
        pass

import argparse
import json
import re
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Dict, List, Optional

NS = {"atom": "http://www.w3.org/2005/Atom"}


# ══════════════════════════════════════════════════════════
#  Classification helpers (mirror Dart `parseYouTubeRss`)
# ══════════════════════════════════════════════════════════

_SHORTS_RE = re.compile(r"(?:^|#|-\s*)shorts?\b|#short|شورتس|شورت")


def _is_shorts(title: str) -> bool:
    return bool(_SHORTS_RE.search(title.lower()))


_LIVE_NEG_RE = re.compile(r"not\s+live|ليس\s+بث|لا\s+بث|غير\s*مباشر")
# بث ككلمة مستقلة: يطابق "بث طاريء" / "بث عاجل" / "بث مباشر" / "البث" / "بث حي"
# + Arabic broadcast keywords. NOTE: "حوار" (singular) is excluded because
#   it appears in regular short clips (e.g. "حوار بين مسلم ودرزي"). Only
#   plurals + "مع" (with person) + "تحاور" (debate verb) are matched.
_LIVE_RE = re.compile(
    r"\b(live|streaming|live\s*now|live\s*stream|on\s*air|stream)\b"
    r"|\bبث\b"
    r"|ال\s*بث"
    r"|لايف"
    r"|مباشر"
    r"|على\s*الهواء"
    r"|\bحوارات\b"
    r"|\bتحاور\b"
    r"|\bاتصال\b"
    r"|\bاتصالات\b"
    r"|\bلقاء\b"
    r"|\bلقاءات\b"
    r"|\bمكالمة\b"
    r"|\bمكالمات\b"
    r"|حواري\s*مع"
    r"|حوارنا\s*مع"
    r"|حواره\s*مع"
    r"|حوارها\s*مع"
)


def _is_live(title: str) -> bool:
    lower = title.lower()
    if _LIVE_NEG_RE.search(lower):
        return False
    return bool(_LIVE_RE.search(lower))


# ══════════════════════════════════════════════════════════
#  Folder / RSS / entries
# ══════════════════════════════════════════════════════════

def detect_folder(cwd):
    """Detect data folder from CWD. Prefer --folder if given."""
    if (cwd / "radio_database").exists():
        return "radio_database"
    if (cwd / "radio_islam").exists():
        return "radio_islam"
    raise SystemExit(
        "Cannot detect data folder (no radio_database/ or radio_islam/). "
        "Pass --folder explicitly."
    )


def fetch_rss(channel_id):
    url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    rss = urllib.request.urlopen(req, timeout=15).read()
    return ET.fromstring(rss)


def fetch_video_metadata(video_ids: List[str]) -> Dict[str, Dict[str, Any]]:
    """Fetch real YouTube metadata (is_live, live_status, duration) for each
    video using yt-dlp. Returns dict mapping videoId → metadata.

    Falls back to empty dict on import error or fetch failure (CI then uses
    title heuristics as a fallback).
    """
    out: Dict[str, Dict[str, Any]] = {}
    try:
        from yt_dlp import YoutubeDL  # type: ignore
    except ImportError:
        print("[WARN] yt-dlp not installed, falling back to title heuristics")
        return out
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "extract_flat": False,
        "ignoreerrors": True,
    }
    try:
        with YoutubeDL(ydl_opts) as ydl:
            for vid in video_ids:
                url = f"https://www.youtube.com/watch?v={vid}"
                try:
                    info = ydl.extract_info(url, download=False) or {}
                    out[vid] = {
                        "is_live": info.get("is_live", False),
                        "live_status": info.get("live_status"),
                        "duration": info.get("duration"),  # seconds or None
                        "is_short": info.get("is_short", False),
                    }
                except Exception as e:
                    print(f"  [WARN] yt-dlp {vid}: {e}")
    except Exception as e:
        print(f"[WARN] yt-dlp global error: {e}")
    return out


def entries_to_subitems(root, channel_name, limit=15):
    """Return list of subItem dicts (videoId, title, etc.) — unclassified."""
    subitems = []
    for entry in root.findall("atom:entry", NS)[: limit * 3]:
        # Pull `limit*3` so we have enough for each bucket after classification
        vid_el = entry.find("atom:id", NS)
        title_el = entry.find("atom:title", NS)
        if vid_el is None or title_el is None:
            continue
        vid = vid_el.text.split(":")[-1] if vid_el.text else ""
        if not vid:
            continue
        title = title_el.text or ""
        subitems.append({"videoId": vid, "title": title})
    return subitems


def build_subitem(video_id: str, title: str, channel_name: str) -> dict:
    youtube_url = f"https://www.youtube.com/watch?v={video_id}"
    return {
        "title": title,
        "subtitle": channel_name,
        "emoji": "",
        "audioUrl": youtube_url,
        "imageUrl": f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg",
        "videoUrl": youtube_url,
        "videoSource": "youtube",
        "mediaType": "both",
    }


def classify_subitems(raw_items, channel_name, limit, metadata_map=None):
    """Split raw RSS entries into 3 buckets: live / videos / shorts.

    If `metadata_map` is provided (dict: videoId → {is_live, live_status,
    duration, is_short}), uses real YouTube metadata via yt-dlp. Otherwise
    falls back to title heuristics.
    """
    live, videos, shorts = [], [], []
    for entry in raw_items:
        sub = build_subitem(entry["videoId"], entry["title"], channel_name)
        meta = (metadata_map or {}).get(entry["videoId"]) if metadata_map else None
        if meta is not None:
            bucket = classify_bucket_by_metadata(
                title=entry["title"],
                is_live=meta.get("is_live"),
                live_status=meta.get("live_status"),
                duration_sec=meta.get("duration"),
                is_short=meta.get("is_short", False),
            )
        else:
            bucket = classify_bucket_by_metadata(
                title=entry["title"],
                is_live=None,
                live_status=None,
                duration_sec=None,
            )
        if bucket == "shorts" and len(shorts) < limit:
            shorts.append(sub)
        elif bucket == "live" and len(live) < limit:
            live.append(sub)
        elif len(videos) < limit:
            videos.append(sub)
    return live, videos, shorts


def classify_bucket_by_metadata(
    title: str,
    is_live=None,
    live_status=None,
    duration_sec=None,
    is_short: bool = False,
) -> str:
    """Classify a video into 'live' / 'videos' / 'shorts'.

    Priority:
    1. is_live=True or live_status='is_live'/'was_live' → 'live'
    2. is_short=True or shorts in title → 'shorts'
    3. live_status='not_live' with duration > 3600s → 'live' (recorded broadcast)
    4. live_status='not_live' with duration <= 3600s → 'videos'
    5. No metadata: fall back to title heuristic (بث keyword → 'live')
    6. Default → 'videos'
    """
    # 1. Real metadata: live (currently or was)
    if is_live is True or live_status in ("is_live", "was_live"):
        return "live"
    # 2. Real metadata: short
    if is_short:
        return "shorts"
    # 3. Title-based shorts (fallback if no metadata)
    if _is_shorts(title):
        return "shorts"
    # 4. Long video + not_live status = recorded broadcast (likely live)
    if (
        live_status == "not_live"
        and duration_sec is not None
        and duration_sec > 3600
    ):
        return "live"
    # 5. Title-based live (fallback if no metadata)
    if _is_live(title):
        return "live"
    # 6. Default
    return "videos"


# ══════════════════════════════════════════════════════════
#  File builders
# ══════════════════════════════════════════════════════════

def _base_category(category_id, channel_name):
    return {
        "id": category_id,
        "title": channel_name,
        "emoji": "🎥",
        "description": f"فيديوهات قناة {channel_name} على يوتيوب",
        "gradientColors": ["#8B0000", "#FF6347"],
        "imageUrl": "",
    }


def build_live_file(category_id, channel_name, subitems):
    return {
        **_base_category(category_id, channel_name),
        "items": [
            {
                "title": f"بثوث مباشرة — {channel_name}",
                "subtitle": "يوتيوب",
                "emoji": "🔴",
                "imageUrl": "",
                "audioUrl": "",
                "subItems": subitems,
            }
        ],
    }


def build_videos_file(category_id, channel_name, subitems):
    return {
        **_base_category(category_id, channel_name),
        "items": [
            {
                "title": f"فيديوهات {channel_name}",
                "subtitle": "يوتيوب",
                "emoji": "🎙️",
                "imageUrl": "",
                "audioUrl": "",
                "subItems": subitems,
            }
        ],
    }


def build_shorts_file(category_id, channel_name, subitems):
    return {
        **_base_category(category_id, channel_name),
        "items": [
            {
                "title": f"شورتس — {channel_name}",
                "subtitle": "يوتيوب",
                "emoji": "📱",
                "imageUrl": "",
                "audioUrl": "",
                "subItems": subitems,
            }
        ],
    }


# ══════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════

def load_or_init_index(index_path):
    if not index_path.exists():
        return {"files": []}
    return json.loads(index_path.read_text(encoding="utf-8"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--folder", default=None, help="radio_database or radio_islam"
    )
    parser.add_argument(
        "--limit", type=int, default=15, help="Max items per type per channel"
    )
    args = parser.parse_args()

    cwd = Path.cwd()
    folder = args.folder or detect_folder(cwd)
    print(f"[INFO] Data folder: {folder}")

    manifest_path = cwd / folder / "youtube_channels.json"
    if not manifest_path.exists():
        print(f"[ERROR] Manifest not found: {manifest_path}")
        sys.exit(1)

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    channels = manifest.get("channels", [])
    if not channels:
        print("[INFO] No channels in manifest, nothing to do")
        sys.exit(0)

    print(f"[INFO] {len(channels)} channel(s) in manifest")

    index_path = cwd / folder / "index.json"
    index_data = load_or_init_index(index_path)
    existing_files = set(index_data.get("files", []))
    index_changed = False
    files_to_delete = []  # old .youtube.json to remove

    for ch in channels:
        category_id = ch.get("categoryId", "").strip()
        channel_id = ch.get("channelId", "").strip()
        channel_name = ch.get("channelName", category_id).strip()

        if not category_id or not channel_id or "xxxxx" in channel_id:
            print(f"[SKIP] {category_id or '<no id>'}: incomplete config")
            continue

        try:
            root = fetch_rss(channel_id)
            print(f"[OK] {category_id}: RSS fetched")
        except Exception as e:
            print(f"[ERROR] {category_id}: RSS fetch failed: {e}")
            continue

        raw = entries_to_subitems(root, channel_name, limit=args.limit)
        if not raw:
            print(f"[WARN] {category_id}: no entries, skipping")
            continue
        # Fetch real YouTube metadata via yt-dlp for accurate classification
        video_ids = [r["videoId"] for r in raw]
        print(f"  [INFO] fetching yt-dlp metadata for {len(video_ids)} videos...")
        try:
            import yt_dlp  # type: ignore  # noqa: F401
            print(f"  [CI] yt-dlp module loaded: {yt_dlp.version.__version__}")
        except ImportError:
            print("  [CI] yt-dlp NOT installed")
        metadata_map = fetch_video_metadata(video_ids)
        if metadata_map:
            # Show breakdown of metadata quality
            live_meta = sum(
                1 for m in metadata_map.values()
                if m.get("is_live") or m.get("live_status") in ("is_live", "was_live")
            )
            short_meta = sum(
                1 for m in metadata_map.values() if m.get("is_short")
            )
            print(
                f"  [CI] yt-dlp: {len(metadata_map)}/{len(video_ids)} "
                f"succeeded (live={live_meta}, short={short_meta})"
            )
        else:
            print("  [CI] yt-dlp returned empty, using title heuristics")
        live, videos, shorts = classify_subitems(
            raw, channel_name, args.limit, metadata_map=metadata_map
        )
        print(
            f"  [INFO] classified: live={len(live)} "
            f"videos={len(videos)} shorts={len(shorts)}"
        )

        channel_dir = cwd / folder / category_id
        channel_dir.mkdir(parents=True, exist_ok=True)

        # 1) Mark old single .youtube.json for deletion (transition period)
        #    - Always remove the index entry, even if file is already gone
        #    - Delete the file from disk if it still exists
        old_file = channel_dir / f"{category_id}.youtube.json"
        old_rel = f"{category_id}/{category_id}.youtube.json"
        if old_file.exists():
            files_to_delete.append(old_file)
        if old_rel in existing_files:
            existing_files.discard(old_rel)
            index_data["files"] = [
                f for f in index_data.get("files", []) if f != old_rel
            ]
            index_changed = True
            print(f"  [INFO] removed legacy {old_rel} from index.json")

        # 2) Write up to 3 files (only if non-empty)
        buckets = [
            ("live", "🔴", live, build_live_file),
            ("videos", "🎙️", videos, build_videos_file),
            ("shorts", "📱", shorts, build_shorts_file),
        ]
        for kind, emoji, subs, builder in buckets:
            if not subs:
                print(f"  [SKIP] {kind}: empty")
                continue
            file_path = channel_dir / f"{category_id}.{kind}.json"
            payload = builder(category_id, channel_name, subs)
            file_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            rel_path = f"{category_id}/{category_id}.{kind}.json"
            print(
                f"  [OK] {rel_path}: {len(subs)} subItems {emoji}"
            )
            if rel_path in existing_files:
                print(f"  [INFO] index.json: {rel_path} already present")
            else:
                index_data.setdefault("files", []).append(rel_path)
                existing_files.add(rel_path)
                index_changed = True
                print(f"  [OK] index.json: added {rel_path}")

    # 3) Delete old .youtube.json files
    for old in files_to_delete:
        try:
            old.unlink()
            print(f"  [DEL] {old.relative_to(cwd)}")
        except Exception as e:
            print(f"  [WARN] could not delete {old}: {e}")

    # 4) Finalize index.json
    if index_changed:
        index_data["files"] = sorted(set(index_data["files"]))
        index_path.write_text(
            json.dumps(index_data, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(
            f"\n[OK] index.json updated "
            f"({len(index_data['files'])} files)"
        )
    else:
        print("\n[INFO] index.json unchanged")

    print("\n[DONE] Sync complete")


if __name__ == "__main__":
    main()

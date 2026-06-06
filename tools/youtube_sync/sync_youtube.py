"""YouTube sync — generates a SINGLE <categoryId>.youtube.json per channel
(matches the OLD mp3 schema with subItems[]) and auto-updates index.json.

Used by both GitHub Actions (.github/workflows/youtube-sync.yml) and
GitLab CI (radio_islam/.gitlab-ci.yml).

Idempotent: re-runs are safe.
  - If a channel's file already exists, it is overwritten with fresh RSS data.
  - If a path is already in index.json, it is NOT re-added.

Output schema per channel (matches zein_khair_allah.json mp3):
{
  "id": "<categoryId>",
  "title": "<channelName>",
  "emoji": "🎥",
  "items": [
    {
      "title": "...",
      "subtitle": "يوتيوب",
      "subItems": [
        { "title": "...", "subtitle": "<channelName>",
          "audioUrl": "https://www.youtube.com/watch?v=<id>",
          "imageUrl": "https://i.ytimg.com/vi/<id>/hqdefault.jpg",
          "videoUrl": "https://www.youtube.com/watch?v=<id>",
          "videoSource": "youtube", "mediaType": "both" },
        ...
      ]
    }
  ]
}
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
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {"atom": "http://www.w3.org/2005/Atom"}


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


def entries_to_subitems(root, channel_name, limit=15):
    subitems = []
    for entry in root.findall("atom:entry", NS)[:limit]:
        vid_el = entry.find("atom:id", NS)
        title_el = entry.find("atom:title", NS)
        if vid_el is None or title_el is None:
            continue
        vid = vid_el.text.split(":")[-1] if vid_el.text else ""
        if not vid:
            continue
        title = title_el.text or ""
        subitems.append(
            {
                "title": title,
                "subtitle": channel_name,
                "emoji": "",
                "audioUrl": f"https://www.youtube.com/watch?v={vid}",
                "imageUrl": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
                "videoUrl": f"https://www.youtube.com/watch?v={vid}",
                "videoSource": "youtube",
                "mediaType": "both",
            }
        )
    return subitems


def build_category(category_id, channel_name, subitems):
    return {
        "id": category_id,
        "title": channel_name,
        "emoji": "🎥",
        "description": f"فيديوهات قناة {channel_name} على يوتيوب",
        "gradientColors": ["#8B0000", "#FF6347"],
        "imageUrl": "",
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
        "--limit", type=int, default=15, help="Max items per channel"
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

        subitems = entries_to_subitems(root, channel_name, limit=args.limit)
        if not subitems:
            print(f"[WARN] {category_id}: no subItems, skipping")
            continue

        category = build_category(category_id, channel_name, subitems)
        channel_dir = cwd / folder / category_id
        channel_dir.mkdir(parents=True, exist_ok=True)
        file_path = channel_dir / f"{category_id}.youtube.json"
        file_path.write_text(
            json.dumps(category, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(
            f"  [OK] {file_path.relative_to(cwd)}: "
            f"{len(subitems)} subItems"
        )

        rel_path = f"{category_id}/{category_id}.youtube.json"
        if rel_path in existing_files:
            print(f"  [INFO] index.json: {rel_path} already present")
        else:
            index_data.setdefault("files", []).append(rel_path)
            existing_files.add(rel_path)
            index_changed = True
            print(f"  [OK] index.json: added {rel_path}")

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

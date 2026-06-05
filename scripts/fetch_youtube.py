#!/usr/bin/env python3
import json
import sys
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

ATOM_NS = {'atom': 'http://www.w3.org/2005/Atom'}
VIDEO_LIMIT_PER_CHANNEL = 15


def fetch_rss(channel_id: str) -> list:
    url = f'https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}'
    req = urllib.request.Request(
        url,
        headers={'User-Agent': 'Mozilla/5.0 (compatible; YouTubeRSSBot/1.0)'},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            xml_data = resp.read()
    except Exception as e:
        print(f'  ❌ RSS fetch failed for {channel_id}: {e}')
        return []

    videos = []
    try:
        root = ET.fromstring(xml_data)
        for entry in root.findall('atom:entry', ATOM_NS):
            video_id_el = entry.find('atom:id', ATOM_NS)
            title_el = entry.find('atom:title', ATOM_NS)
            published_el = entry.find('atom:published', ATOM_NS)
            if video_id_el is None or title_el is None:
                continue
            video_id = video_id_el.text.split(':')[-1] if video_id_el.text else ''
            if not video_id:
                continue
            videos.append({
                'videoId': video_id,
                'title': title_el.text or '',
                'publishedAt': published_el.text or '' if published_el is not None else '',
            })
            if len(videos) >= VIDEO_LIMIT_PER_CHANNEL:
                break
    except ET.ParseError as e:
        print(f'  ❌ XML parse error for {channel_id}: {e}')
        return []
    return videos


def main():
    if len(sys.argv) < 2:
        print('Usage: python fetch_youtube.py <path_to_youtube_videos.json>')
        sys.exit(1)

    json_path = Path(sys.argv[1])
    if not json_path.exists():
        print(f'❌ File not found: {json_path}')
        sys.exit(1)

    with json_path.open('r', encoding='utf-8') as f:
        data = json.load(f)

    channels = data.get('channels', {})
    if not channels:
        print('⚠️  No channels configured')
        return

    added_total = 0
    for category_id, channel_info in channels.items():
        channel_id = channel_info.get('channelId', '')
        if not channel_id or channel_id.startswith('REPLACE'):
            print(f'⏭️  {category_id}: channelId not set, skipping')
            continue

        blacklist = set(channel_info.get('blacklist', []))
        existing_ids = {v.get('videoId') for v in channel_info.get('videos', [])}
        existing_ids.update({v.get('videoId') for v in channel_info.get('pinned', [])})

        print(f'📡 Fetching {category_id} ({channel_id})...')
        fetched = fetch_rss(channel_id)
        new_videos = []
        for v in fetched:
            if v['videoId'] in blacklist or v['videoId'] in existing_ids:
                continue
            new_videos.append({
                'videoId': v['videoId'],
                'title': v['title'],
                'subtitle': '',
            })

        if new_videos:
            channel_info.setdefault('videos', []).extend(new_videos)
            added_total += len(new_videos)
            print(f'  ✅ Added {len(new_videos)} new videos')
        else:
            print(f'  ℹ️  No new videos')

    if added_total > 0:
        data['lastUpdated'] = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
        with json_path.open('w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(f'\n💾 Saved: {added_total} new videos total')
    else:
        print('\n✅ No changes')


if __name__ == '__main__':
    main()

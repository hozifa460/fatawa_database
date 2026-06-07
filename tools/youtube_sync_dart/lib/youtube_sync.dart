/// YouTube sync — shared library for fetching YouTube RSS feed,
/// fetching real metadata via youtube_explode_dart, classifying
/// into live / videos / shorts buckets, and writing 3 separate
/// JSON files per channel (with same `id` so the Dart cascade
/// merge in the app auto-concatenates items[]).
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

// ══════════════════════════════════════════════════════════
//  Public types
// ══════════════════════════════════════════════════════════

enum Bucket { live, videos, shorts }

class RawEntry {
  final String videoId;
  final String title;
  RawEntry(this.videoId, this.title);
}

class VideoMeta {
  final bool? isLive;
  final String? liveStatus; // 'is_live' | 'was_live' | 'not_live' | 'is_upcoming'
  final Duration? duration;
  final bool isShort;
  VideoMeta({
    this.isLive,
    this.liveStatus,
    this.duration,
    this.isShort = false,
  });
}

class ChannelConfig {
  final String categoryId;
  final String channelId;
  final String channelName;
  ChannelConfig({
    required this.categoryId,
    required this.channelId,
    required this.channelName,
  });
}

class SubItem {
  final String title;
  final String subtitle; // channel name
  final String audioUrl; // YouTube watch URL
  final String imageUrl; // i.ytimg.com/vi/<id>/hqdefault.jpg
  final String videoUrl; // YouTube watch URL
  SubItem({
    required this.title,
    required this.subtitle,
    required this.audioUrl,
    required this.imageUrl,
    required this.videoUrl,
  });
}

class ClassifiedBuckets {
  final List<SubItem> live = [];
  final List<SubItem> videos = [];
  final List<SubItem> shorts = [];
}

// ══════════════════════════════════════════════════════════
//  Classification helpers (mirrors Dart `classifyBucketByMetadata`
//  in lib/screens/radio/data/recitation_categories_data.dart)
// ══════════════════════════════════════════════════════════

final _shortsRe = RegExp(
  r'(?:^|#|-\s*)shorts?\b|#short|شورتس|شورت',
);

final _liveNegRe = RegExp(r'not\s+live|ليس\s+بث|لا\s+بث|غير\s*مباشر');
// بث ككلمة مستقلة + Arabic debate/call-in keywords.
// NOTE: \b does NOT work in Dart for Arabic letters even with unicode: true.
// Use (?<!\p{L}) / (?!\p{L}) lookarounds to bound words by Unicode letters.
final _liveRe = RegExp(
  r'\b(live|streaming|live\s*now|live\s*stream|on\s*air|stream)\b'
  r'|(?<!\p{L})بث(?!\p{L})'
  r'|ال\s*بث'
  r'|لايف'
  r'|مباشر'
  r'|على\s*الهواء'
  r'|(?<!\p{L})حوارات(?!\p{L})'
  r'|(?<!\p{L})تحاور(?!\p{L})'
  r'|(?<!\p{L})اتصال(?!\p{L})'
  r'|(?<!\p{L})اتصالات(?!\p{L})'
  r'|(?<!\p{L})لقاء(?!\p{L})'
  r'|(?<!\p{L})لقاءات(?!\p{L})'
  r'|(?<!\p{L})مكالمة(?!\p{L})'
  r'|(?<!\p{L})مكالمات(?!\p{L})'
  r'|حواري\s*مع'
  r'|حوارنا\s*مع'
  r'|حواره\s*مع'
  r'|حوارها\s*مع',
  unicode: true,
);

bool _isShorts(String title) => _shortsRe.hasMatch(title.toLowerCase());

bool _isLive(String title) {
  final lower = title.toLowerCase();
  if (_liveNegRe.hasMatch(lower)) return false;
  return _liveRe.hasMatch(lower);
}

/// Classify a video into 'live' / 'videos' / 'shorts'.
///
/// Priority:
/// 1. isShort=true or shorts in title → 'shorts' (shorts wins everything)
/// 2. isLive=true or liveStatus='is_live'/'was_live' → 'live'
/// 3. liveStatus='not_live' + duration > 1h → 'live' (recorded broadcast)
/// 4. liveStatus='not_live' + duration ≤ 1h → 'videos'
/// 5. No metadata: fall back to title heuristic
/// 6. Default → 'videos'
String classifyBucketByMetadata({
  required String title,
  bool? isLive,
  String? liveStatus,
  Duration? duration,
  bool isShort = false,
}) {
  // 1. Shorts wins everything (even over isLive metadata)
  if (isShort || _isShorts(title)) return 'shorts';
  // 2. Real metadata: live
  if (isLive == true ||
      (liveStatus != null &&
          (liveStatus == 'is_live' || liveStatus == 'was_live'))) {
    return 'live';
  }
  // 3. Long video + not_live = recorded broadcast
  if (liveStatus == 'not_live' &&
      duration != null &&
      duration.inSeconds > 3600) {
    return 'live';
  }
  // 4. Title-based live (fallback)
  if (_isLive(title)) return 'live';
  // 5. Default
  return 'videos';
}

// ══════════════════════════════════════════════════════════
//  RSS fetch
// ══════════════════════════════════════════════════════════

Future<List<RawEntry>> fetchRss(String channelId) async {
  final url =
      'https://www.youtube.com/feeds/videos.xml?channel_id=$channelId';
  final resp = await http.get(
    Uri.parse(url),
    headers: {'User-Agent': 'Mozilla/5.0'},
  );
  if (resp.statusCode != 200) {
    throw Exception('RSS fetch failed: HTTP ${resp.statusCode}');
  }
  final doc = xml.XmlDocument.parse(resp.body);
  final entries = doc.findAllElements('entry').toList();
  return entries.map((entry) {
    final idEl = entry.findElements('id').firstOrNull;
    final titleEl = entry.findElements('title').firstOrNull;
    final videoId = idEl?.innerText.split(':').last ?? '';
    final title = titleEl?.innerText ?? '';
    return RawEntry(videoId, title);
  }).where((e) => e.videoId.isNotEmpty).toList();
}

// ══════════════════════════════════════════════════════════
//  Metadata fetch via youtube_explode_dart
// ══════════════════════════════════════════════════════════

/// Fetch real YouTube metadata for each video using youtube_explode_dart.
/// This runs on the user's machine (or in CI) and is not subject to
/// cloud IP rate limiting the same way yt-dlp on GitHub Actions is.
Future<Map<String, VideoMeta>> fetchVideoMetadata(
  Iterable<String> videoIds,
) async {
  final yt = YoutubeExplode();
  final out = <String, VideoMeta>{};
  for (final vid in videoIds) {
    try {
      final video = await yt.videos.get(vid);
      out[vid] = VideoMeta(
        isLive: video.isLive,
        // youtube_explode_dart doesn't expose liveStatus directly,
        // but Video.isLive covers currently-live streams. For
        // archived broadcasts, we rely on duration > 1h.
        liveStatus: video.isLive ? 'is_live' : 'not_live',
        duration: video.duration,
        isShort: _looksLikeShort(title: video.title, duration: video.duration),
      );
    } catch (e) {
      // Leave missing — caller will fall back to title heuristic.
    }
  }
  yt.close();
  return out;
}

bool _looksLikeShort({required String title, Duration? duration}) {
  if (_isShorts(title)) return true;
  if (duration != null && duration.inSeconds > 0 && duration.inSeconds <= 60) {
    return true;
  }
  return false;
}

// ══════════════════════════════════════════════════════════
//  Classification + subItem build
// ══════════════════════════════════════════════════════════

SubItem buildSubItem({
  required String videoId,
  required String title,
  required String channelName,
}) {
  final watch = 'https://www.youtube.com/watch?v=$videoId';
  return SubItem(
    title: title,
    subtitle: channelName,
    audioUrl: watch,
    imageUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
    videoUrl: watch,
  );
}

ClassifiedBuckets classifyEntries({
  required List<RawEntry> entries,
  required String channelName,
  required int limit,
  Map<String, VideoMeta>? metadataMap,
}) {
  final out = ClassifiedBuckets();
  for (final e in entries) {
    final meta = metadataMap?[e.videoId];
    final bucketStr = classifyBucketByMetadata(
      title: e.title,
      isLive: meta?.isLive,
      liveStatus: meta?.liveStatus,
      duration: meta?.duration,
      isShort: meta?.isShort ?? false,
    );
    final bucket = Bucket.values.firstWhere((b) => b.name == bucketStr);
    final sub = buildSubItem(
      videoId: e.videoId,
      title: e.title,
      channelName: channelName,
    );
    if (bucket == Bucket.shorts && out.shorts.length < limit) {
      out.shorts.add(sub);
    } else if (bucket == Bucket.live && out.live.length < limit) {
      out.live.add(sub);
    } else if (out.videos.length < limit) {
      out.videos.add(sub);
    }
  }
  return out;
}

// ══════════════════════════════════════════════════════════
//  File writers
// ══════════════════════════════════════════════════════════

Map<String, dynamic> _baseCategory(String id, String name) => {
      'id': id,
      'title': name,
      'emoji': '🎥',
      'description': 'فيديوهات قناة $name على يوتيوب',
      'gradientColors': ['#8B0000', '#FF6347'],
      'imageUrl': '',
    };

Map<String, dynamic> buildLiveFile(
  String id,
  String name,
  List<SubItem> subs,
) =>
    {
      ..._baseCategory(id, name),
      'items': [
        {
          'title': 'بثوث مباشرة — $name',
          'subtitle': 'يوتيوب',
          'emoji': '🔴',
          'imageUrl': '',
          'audioUrl': '',
          'subItems': subs
              .map((s) => {
                    'title': s.title,
                    'subtitle': s.subtitle,
                    'emoji': '',
                    'audioUrl': s.audioUrl,
                    'imageUrl': s.imageUrl,
                    'videoUrl': s.videoUrl,
                    'videoSource': 'youtube',
                    'mediaType': 'both',
                  })
              .toList(),
        },
      ],
    };

Map<String, dynamic> buildVideosFile(
  String id,
  String name,
  List<SubItem> subs,
) =>
    {
      ..._baseCategory(id, name),
      'items': [
        {
          'title': 'فيديوهات $name',
          'subtitle': 'يوتيوب',
          'emoji': '🎙️',
          'imageUrl': '',
          'audioUrl': '',
          'subItems': subs
              .map((s) => {
                    'title': s.title,
                    'subtitle': s.subtitle,
                    'emoji': '',
                    'audioUrl': s.audioUrl,
                    'imageUrl': s.imageUrl,
                    'videoUrl': s.videoUrl,
                    'videoSource': 'youtube',
                    'mediaType': 'both',
                  })
              .toList(),
        },
      ],
    };

Map<String, dynamic> buildShortsFile(
  String id,
  String name,
  List<SubItem> subs,
) =>
    {
      ..._baseCategory(id, name),
      'items': [
        {
          'title': 'شورتس — $name',
          'subtitle': 'يوتيوب',
          'emoji': '📱',
          'imageUrl': '',
          'audioUrl': '',
          'subItems': subs
              .map((s) => {
                    'title': s.title,
                    'subtitle': s.subtitle,
                    'emoji': '',
                    'audioUrl': s.audioUrl,
                    'imageUrl': s.imageUrl,
                    'videoUrl': s.videoUrl,
                    'videoSource': 'youtube',
                    'mediaType': 'both',
                  })
              .toList(),
        },
      ],
    };

Future<void> writeJson(File file, Map<String, dynamic> data) async {
  final encoder = const JsonEncoder.withIndent('  ');
  final txt = encoder.convert(data);
  await file.writeAsString('$txt\n', flush: true);
}

// ══════════════════════════════════════════════════════════
//  Manifest + index
// ══════════════════════════════════════════════════════════

List<ChannelConfig> loadManifest(File manifestFile) {
  final txt = manifestFile.readAsStringSync();
  final data = jsonDecode(txt) as Map<String, dynamic>;
  final channels = (data['channels'] as List?) ?? [];
  return channels
      .whereType<Map<String, dynamic>>()
      .map((c) => ChannelConfig(
            categoryId: (c['categoryId'] ?? '').toString().trim(),
            channelId: (c['channelId'] ?? '').toString().trim(),
            channelName: (c['channelName'] ?? '').toString().trim(),
          ))
      .where((c) =>
          c.categoryId.isNotEmpty &&
          c.channelId.isNotEmpty &&
          !c.channelId.contains('xxxxx'))
      .toList();
}

class IndexData {
  final Set<String> files = {};
  IndexData(List<String> initial) {
    files.addAll(initial);
  }
  bool add(String rel) {
    if (files.contains(rel)) return false;
    files.add(rel);
    return true;
  }
}

Future<void> writeIndex(File indexFile, IndexData idx) async {
  final sorted = idx.files.toList()..sort();
  await writeJson(indexFile, {'files': sorted});
}

IndexData loadIndex(File indexFile) {
  if (!indexFile.existsSync()) return IndexData([]);
  final txt = indexFile.readAsStringSync();
  final data = jsonDecode(txt) as Map<String, dynamic>;
  return IndexData(((data['files'] as List?) ?? []).cast<String>());
}

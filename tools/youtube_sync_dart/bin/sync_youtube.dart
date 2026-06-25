// ════════════════════════════════════════════════════════════════
// sync_youtube.dart — Modified version with Auto-Archive support
//
// IMPORTANT: index.json structure is UNCHANGED — still just { "files": [...] }
// Archive files (e.g. zein_khair_allah.videos.archive.json) are added to
// the SAME "files" array. The streaming platform detects them by the
// ".archive.json" suffix and loads them lazily (only when the user
// clicks "Load older videos").
//
// Changes from original:
//   1. MERGE instead of overwrite — new videos are added on top of
//      existing ones (no more data loss).
//   2. AUTO-ARCHIVE — when a section file exceeds ARCHIVE_THRESHOLD
//      items, the oldest items are moved to a separate .archive.json
//      file. The archive file is added to index.json "files" array
//      (the platform detects it by suffix and lazy-loads it).
//   3. NO LIMIT — the merge keeps all items; archive handles growth.
//   4. SORT — items are sorted newest-first (YouTube RSS already
//      returns newest first, so we just preserve order on merge).
//
// Usage:
//   dart run bin/sync_youtube.dart --folder ../../radio_database
//   dart run bin/sync_youtube.dart --folder ../../radio_database --limit 30
//   dart run bin/sync_youtube.dart --folder ../../radio_database --archive-threshold 3000
//
// Replace the original file at:
//   tools/youtube_sync_dart/bin/sync_youtube.dart
//
// NO CHANGES needed to lib/youtube_sync.dart — the existing
// IndexData class and writeIndex function work as-is because archive
// files are just regular entries in the "files" array.
// ════════════════════════════════════════════════════════════════

/// CLI entry point for the YouTube sync (with auto-archive).
library;

import 'dart:convert';
import 'dart:io';

import 'package:youtube_sync_dart/youtube_sync.dart';

/// Default threshold: when a section file has more than this many items,
/// the oldest items beyond this count are moved to an .archive.json file.
const int defaultArchiveThreshold = 5000;

Future<int> main(List<String> args) async {
  // Force UTF-8 stdout on Windows
  if (Platform.isWindows) {
    try {
      stdout.encoding = utf8;
      stderr.encoding = utf8;
    } catch (_) {}
  }

  final folder = _parseArg(args, '--folder') ?? 'radio_database';
  // limit = how many NEW videos to fetch from RSS per sync (default: 15).
  final limit = int.tryParse(_parseArg(args, '--limit') ?? '') ?? 15;
  // archiveThreshold = max items kept in the main file. Older items are
  // moved to an .archive.json file when this threshold is exceeded.
  final archiveThreshold = int.tryParse(
        _parseArg(args, '--archive-threshold') ?? '',
      ) ??
      defaultArchiveThreshold;

  final cwd = Directory.current;
  final folderDir = Directory('${cwd.path}${Platform.path.separator}$folder');
  if (!folderDir.existsSync()) {
    stderr.writeln('[ERROR] Folder not found: ${folderDir.path}');
    return 1;
  }
  print('[INFO] Data folder: $folder');
  print('[INFO] RSS limit per sync: $limit');
  print('[INFO] Archive threshold: $archiveThreshold');

  final manifestFile = File('${folderDir.path}${Platform.pathSeparator}youtube_channels.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln('[ERROR] Manifest not found: ${manifestFile.path}');
    return 1;
  }

  final channels = loadManifest(manifestFile);
  if (channels.isEmpty) {
    print('[INFO] No channels in manifest, nothing to do');
    return 0;
  }
  print('[INFO] ${channels.length} channel(s) in manifest');

  final indexFile = File('${folderDir.path}${Platform.pathSeparator}index.json');
  final index = loadIndex(indexFile);
  var indexChanged = false;
  final filesToDelete = <File>[];

  for (final ch in channels) {
    print('[OK] ${ch.categoryId}: fetching RSS...');
    List<RawEntry> raw;
    try {
      raw = await fetchRss(ch.channelId);
    } catch (e) {
      print('[ERROR] ${ch.categoryId}: RSS fetch failed: $e');
      continue;
    }
    if (raw.isEmpty) {
      print('[WARN] ${ch.categoryId}: no entries, skipping');
      continue;
    }
    print('  [INFO] RSS returned ${raw.length} entries (limit=$limit)');

    print('  [INFO] fetching live tab playlist (UULV)...');
    final liveIds = await fetchLiveTabVideoIds(ch.channelId);
    print('  [INFO] live tab: ${liveIds.length} videos');

    print('  [INFO] fetching shorts tab playlist (UUSH)...');
    final shortsIds = await fetchShortsTabVideoIds(ch.channelId);
    print('  [INFO] shorts tab: ${shortsIds.length} videos');

    print('  [INFO] fetching youtube_explode_dart metadata (fallback)...');
    final meta = await fetchVideoMetadata(raw.map((e) => e.videoId));
    print('  [INFO] metadata: ${meta.length}/${raw.length} succeeded');

    final buckets = classifyEntries(
      entries: raw,
      channelName: ch.channelName,
      limit: limit,
      metadataMap: meta,
      liveVideoIds: liveIds,
      shortsVideoIds: shortsIds,
    );
    print(
      '  [INFO] classified: live=${buckets.live.length} '
      'videos=${buckets.videos.length} shorts=${buckets.shorts.length}',
    );

    final chDir = Directory('${folderDir.path}${Platform.pathSeparator}${ch.categoryId}');
    if (!chDir.existsSync()) chDir.createSync(recursive: true);

    // 1) Mark old single .youtube.json for deletion
    final oldFile = File('${chDir.path}${Platform.pathSeparator}${ch.categoryId}.youtube.json');
    final oldRel = '${ch.categoryId}/${ch.categoryId}.youtube.json';
    if (oldFile.existsSync()) filesToDelete.add(oldFile);
    if (index.files.remove(oldRel)) {
      indexChanged = true;
      print('  [INFO] removed legacy $oldRel from index.json');
    }

    // 2) For each bucket: MERGE with existing file, then AUTO-ARCHIVE
    //    if the merged count exceeds the threshold.
    Future<void> writeBucketMerged(
      String kind,
      String emoji,
      List<SubItem> newSubs,
      Map<String, dynamic> Function(String, String, List<SubItem>) builder,
    ) async {
      if (newSubs.isEmpty) {
        print('  [SKIP] $kind: no new items');
        return;
      }

      final mainRel = '${ch.categoryId}/${ch.categoryId}.$kind.json';
      final mainFile = File('${chDir.path}${Platform.pathSeparator}${ch.categoryId}.$kind.json');
      final archiveRel = '${ch.categoryId}/${ch.categoryId}.$kind.archive.json';
      final archiveFile = File('${chDir.path}${Platform.pathSeparator}${ch.categoryId}.$kind.archive.json');

      // Load existing main file (if any) → its subItems become "old" candidates.
      final existingMainSubs = <SubItem>[];
      if (mainFile.existsSync()) {
        try {
          final oldJson = jsonDecode(mainFile.readAsStringSync()) as Map<String, dynamic>;
          for (final item in (oldJson['items'] as List?) ?? []) {
            for (final sub in (item['subItems'] as List?) ?? []) {
              final m = sub as Map<String, dynamic>;
              existingMainSubs.add(SubItem(
                title: (m['title'] ?? '').toString(),
                subtitle: (m['subtitle'] ?? '').toString(),
                audioUrl: (m['audioUrl'] ?? '').toString(),
                imageUrl: (m['imageUrl'] ?? '').toString(),
                videoUrl: (m['videoUrl'] ?? '').toString(),
              ));
            }
          }
        } catch (e) {
          print('  [WARN] could not parse existing $mainRel: $e');
        }
      }

      // Load existing archive file (if any) → its subItems are preserved.
      final existingArchiveSubs = <SubItem>[];
      if (archiveFile.existsSync()) {
        try {
          final arcJson = jsonDecode(archiveFile.readAsStringSync()) as Map<String, dynamic>;
          for (final item in (arcJson['items'] as List?) ?? []) {
            for (final sub in (item['subItems'] as List?) ?? []) {
              final m = sub as Map<String, dynamic>;
              existingArchiveSubs.add(SubItem(
                title: (m['title'] ?? '').toString(),
                subtitle: (m['subtitle'] ?? '').toString(),
                audioUrl: (m['audioUrl'] ?? '').toString(),
                imageUrl: (m['imageUrl'] ?? '').toString(),
                videoUrl: (m['videoUrl'] ?? '').toString(),
              ));
            }
          }
        } catch (e) {
          print('  [WARN] could not parse existing $archiveRel: $e');
        }
      }

      // Merge: new items first (newest), then existing main items, then archive.
      // Dedupe by videoUrl so re-running sync doesn't double-insert.
      final merged = <SubItem>[];
      final seenUrls = <String>{};
      void addUnique(SubItem s) {
        final key = s.videoUrl.isNotEmpty ? s.videoUrl : s.audioUrl;
        if (key.isEmpty || seenUrls.add(key)) merged.add(s);
      }

      for (final s in newSubs) addUnique(s);
      for (final s in existingMainSubs) addUnique(s);
      for (final s in existingArchiveSubs) addUnique(s);

      print('  [INFO] $kind: merged ${merged.length} items '
          '(new=${newSubs.length}, existingMain=${existingMainSubs.length}, '
          'existingArchive=${existingArchiveSubs.length})');

      // Auto-archive: if merged count > threshold, split.
      final List<SubItem> mainSubs;
      final List<SubItem> archiveSubs;
      if (merged.length > archiveThreshold) {
        mainSubs = merged.sublist(0, archiveThreshold);
        archiveSubs = merged.sublist(archiveThreshold);
        print('  [ARCHIVE] $kind: main=${mainSubs.length}, archive=${archiveSubs.length}');
      } else {
        mainSubs = merged;
        archiveSubs = const [];
      }

      // Write main file.
      await writeJson(mainFile, builder(ch.categoryId, ch.channelName, mainSubs));
      print('  [OK] $mainRel: ${mainSubs.length} subItems $emoji');
      if (index.add(mainRel)) {
        indexChanged = true;
        print('  [OK] index.json: added $mainRel');
      }

      // Write/Update archive file (only if non-empty).
      // The archive file is added to the SAME "files" array in index.json.
      // The streaming platform detects it by the ".archive.json" suffix and
      // lazy-loads it only when the user requests older items.
      if (archiveSubs.isNotEmpty) {
        await writeJson(archiveFile, builder(ch.categoryId, ch.channelName, archiveSubs));
        print('  [OK] $archiveRel: ${archiveSubs.length} archived subItems 📦');
        if (index.add(archiveRel)) {
          indexChanged = true;
          print('  [OK] index.json: added $archiveRel (archive)');
        }
      } else if (archiveFile.existsSync()) {
        // Archive file exists but is now empty → remove it.
        archiveFile.deleteSync();
        if (index.files.remove(archiveRel)) {
          indexChanged = true;
          print('  [DEL] removed empty $archiveRel');
        }
      }
    }

    await writeBucketMerged('live', '🔴', buckets.live, buildLiveFile);
    await writeBucketMerged('videos', '🎙️', buckets.videos, buildVideosFile);
    await writeBucketMerged('shorts', '📱', buckets.shorts, buildShortsFile);
  }

  // 3) Delete old .youtube.json files
  for (final old in filesToDelete) {
    try {
      old.deleteSync();
      print('  [DEL] ${old.path}');
    } catch (e) {
      print('  [WARN] could not delete ${old.path}: $e');
    }
  }

  // 4) Finalize index.json (structure unchanged — just "files")
  if (indexChanged) {
    await writeIndex(indexFile, index);
    print('\n[OK] index.json updated (${index.files.length} files)');
  } else {
    print('\n[INFO] index.json unchanged');
  }

  print('\n[DONE] Sync complete (with auto-archive)');
  return 0;
}

String? _parseArg(List<String> args, String flag) {
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == flag) return args[i + 1];
  }
  return null;
}

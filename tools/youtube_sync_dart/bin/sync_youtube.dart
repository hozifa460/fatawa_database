/// CLI entry point for the YouTube sync.
/// Usage: dart run bin/sync_youtube.dart --folder radio_database
library;

import 'dart:convert';
import 'dart:io';

import 'package:youtube_sync_dart/youtube_sync.dart';

Future<int> main(List<String> args) async {
  // Force UTF-8 stdout on Windows
  if (Platform.isWindows) {
    try {
      stdout.encoding = utf8;
      stderr.encoding = utf8;
    } catch (_) {}
  }

  final folder = _parseArg(args, '--folder') ?? 'radio_database';
  final limit = int.tryParse(_parseArg(args, '--limit') ?? '') ?? 15;

  final cwd = Directory.current;
  final folderDir = Directory('${cwd.path}${Platform.pathSeparator}$folder');
  if (!folderDir.existsSync()) {
    stderr.writeln('[ERROR] Folder not found: ${folderDir.path}');
    return 1;
  }
  print('[INFO] Data folder: $folder');

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

    // 2) Write up to 3 files (only if non-empty)
    Future<void> writeBucket(
      String kind,
      String emoji,
      List<SubItem> subs,
      Map<String, dynamic> Function(String, String, List<SubItem>) builder,
    ) async {
      if (subs.isEmpty) {
        print('  [SKIP] $kind: empty');
        return;
      }
      final file = File('${chDir.path}${Platform.pathSeparator}${ch.categoryId}.$kind.json');
      await writeJson(file, builder(ch.categoryId, ch.channelName, subs));
      final rel = '${ch.categoryId}/${ch.categoryId}.$kind.json';
      print('  [OK] $rel: ${subs.length} subItems $emoji');
      if (index.add(rel)) {
        indexChanged = true;
        print('  [OK] index.json: added $rel');
      } else {
        print('  [INFO] index.json: $rel already present');
      }
    }

    await writeBucket('live', '🔴', buckets.live, buildLiveFile);
    await writeBucket('videos', '🎙️', buckets.videos, buildVideosFile);
    await writeBucket('shorts', '📱', buckets.shorts, buildShortsFile);
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

  // 4) Finalize index.json
  if (indexChanged) {
    await writeIndex(indexFile, index);
    print('\n[OK] index.json updated (${index.files.length} files)');
  } else {
    print('\n[INFO] index.json unchanged');
  }

  print('\n[DONE] Sync complete');
  return 0;
}

String? _parseArg(List<String> args, String flag) {
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == flag) return args[i + 1];
  }
  return null;
}

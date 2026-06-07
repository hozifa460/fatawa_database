/// Tests for the classification logic.
/// These mirror the Dart tests in
/// test/youtube_refresh_test.dart (`classifyBucketByMetadata` group).
library;

import 'package:test/test.dart';
import 'package:youtube_sync_dart/youtube_sync.dart';

void main() {
  group('classifyBucketByMetadata', () {
    test('isLive=true → live', () {
      expect(
        classifyBucketByMetadata(
          title: 'أي عنوان',
          isLive: true,
        ),
        'live',
      );
    });

    test('liveStatus=is_live → live', () {
      expect(
        classifyBucketByMetadata(
          title: 'حوار مع الضيف',
          liveStatus: 'is_live',
        ),
        'live',
      );
    });

    test('liveStatus=was_live → live', () {
      expect(
        classifyBucketByMetadata(
          title: 'حوار قديم',
          liveStatus: 'was_live',
        ),
        'live',
      );
    });

    test('liveStatus=not_live + duration > 1h → live (recorded broadcast)',
        () {
      expect(
        classifyBucketByMetadata(
          title: 'لقاء مطول',
          liveStatus: 'not_live',
          duration: const Duration(hours: 2),
        ),
        'live',
      );
    });

    test('liveStatus=not_live + duration <= 1h → videos', () {
      expect(
        classifyBucketByMetadata(
          title: 'مقطع قصير',
          liveStatus: 'not_live',
          duration: const Duration(minutes: 30),
        ),
        'videos',
      );
    });

    test('isShort=true → shorts', () {
      expect(
        classifyBucketByMetadata(
          title: 'أي عنوان',
          isShort: true,
        ),
        'shorts',
      );
    });

    test('shorts keyword overrides metadata', () {
      expect(
        classifyBucketByMetadata(
          title: 'مقطع #shorts',
          isLive: true, // would normally be live, but shorts wins
        ),
        'shorts',
      );
    });

    test('title بث standalone → live (no metadata)', () {
      expect(
        classifyBucketByMetadata(
          title: 'بث طاريء: رسالة عاجلة',
        ),
        'live',
      );
    });

    test('title حوارات → live (Arabic debate keyword)', () {
      expect(
        classifyBucketByMetadata(
          title: 'حوارات مع النصارى والملحدين',
        ),
        'live',
      );
    });

    test('title اتصالات → live (call-in keyword)', () {
      expect(
        classifyBucketByMetadata(
          title: 'اتصالات المسلمين',
        ),
        'live',
      );
    });

    test('title حواري مع → live (debate with person)', () {
      expect(
        classifyBucketByMetadata(
          title: 'حواري مع الشيخ الفلاني',
        ),
        'live',
      );
    });

    test('title لقاء → live (meeting keyword)', () {
      expect(
        classifyBucketByMetadata(
          title: 'لقاء مهم مع الضيف',
        ),
        'live',
      );
    });

    test('not live in title → videos (negation wins)', () {
      expect(
        classifyBucketByMetadata(
          title: 'this is not live recording',
        ),
        'videos',
      );
    });

    test('ليس بث → videos (Arabic negation)', () {
      expect(
        classifyBucketByMetadata(
          title: 'هذا ليس بث مباشر',
        ),
        'videos',
      );
    });

    test('no metadata + no live keyword → videos', () {
      expect(
        classifyBucketByMetadata(
          title: 'رضاع الكبير في الإسلام',
        ),
        'videos',
      );
    });

    test('shorts keyword with no metadata → shorts', () {
      expect(
        classifyBucketByMetadata(
          title: 'مقطع #shorts',
        ),
        'shorts',
      );
    });

    test('short Arabic title (شورتس) → shorts', () {
      expect(
        classifyBucketByMetadata(
          title: 'مقطع شورتس قصير',
        ),
        'shorts',
      );
    });
  });

  group('classifyEntries', () {
    test('disjoint buckets — no overlap', () {
      final entries = [
        RawEntry('vid1', 'بث طاريء'),
        RawEntry('vid2', 'حوارات مع النصارى'),
        RawEntry('vid3', 'اتصالات المسلمين'),
        RawEntry('vid4', 'رضاع الكبير'),
        RawEntry('vid5', 'مقطع #shorts'),
      ];
      final buckets = classifyEntries(
        entries: entries,
        channelName: 'Test',
        limit: 15,
        metadataMap: {
          'vid5': VideoMeta(isShort: true),
        },
      );
      // Compute overlap by videoId (encoded in audioUrl)
      final liveIds = buckets.live.map((s) => s.audioUrl).toSet();
      final videoIds = buckets.videos.map((s) => s.audioUrl).toSet();
      final shortIds = buckets.shorts.map((s) => s.audioUrl).toSet();
      expect(liveIds.intersection(videoIds), isEmpty);
      expect(liveIds.intersection(shortIds), isEmpty);
      expect(videoIds.intersection(shortIds), isEmpty);
      expect(buckets.live.length, 3);
      expect(buckets.videos.length, 1);
      expect(buckets.shorts.length, 1);
    });
  });
}

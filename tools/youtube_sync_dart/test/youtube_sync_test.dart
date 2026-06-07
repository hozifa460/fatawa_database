/// Tests for the classification logic.
/// These mirror the Dart tests in
/// test/youtube_refresh_test.dart (`classifyBucketByMetadata` group).
library;

import 'package:test/test.dart';
import 'package:youtube_sync_dart/youtube_sync.dart';

void main() {
  group('classifyBucketByMetadata', () {
    test('UULV playlist contains videoId → live (most authoritative)', () {
      expect(
        classifyBucketByMetadata(
          title: 'random title with no keywords',
          videoId: 'abc12345678',
          liveVideoIds: {'abc12345678'},
        ),
        'live',
      );
    });

    test('UUSH playlist contains videoId → shorts (most authoritative)', () {
      expect(
        classifyBucketByMetadata(
          title: 'random title',
          videoId: 'shortId12345',
          shortsVideoIds: {'shortId12345'},
        ),
        'shorts',
      );
    });

    test('UULV wins over isLive=false (past live broadcast)', () {
      expect(
        classifyBucketByMetadata(
          title: 'حوار قديم',
          videoId: 'pastlive',
          isLive: false,
          liveStatus: 'not_live',
          duration: const Duration(minutes: 20),
          liveVideoIds: {'pastlive'},
        ),
        'live',
      );
    });

    test('UUSH wins over UULV (defensive — should never happen, shorts > live)',
        () {
      expect(
        classifyBucketByMetadata(
          title: 'any',
          videoId: 'inboth',
          liveVideoIds: {'inboth'},
          shortsVideoIds: {'inboth'},
        ),
        'live',
      );
    });

    test('isLive=true → live', () {
      expect(
        classifyBucketByMetadata(
          title: 'أي عنوان',
          videoId: 'vid1',
          isLive: true,
        ),
        'live',
      );
    });

    test('liveStatus=is_live → live', () {
      expect(
        classifyBucketByMetadata(
          title: 'حوار مع الضيف',
          videoId: 'vid2',
          liveStatus: 'is_live',
        ),
        'live',
      );
    });

    test('liveStatus=was_live → live', () {
      expect(
        classifyBucketByMetadata(
          title: 'حوار قديم',
          videoId: 'vid3',
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
          videoId: 'vid4',
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
          videoId: 'vid5',
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
          videoId: 'vid6',
          isShort: true,
        ),
        'shorts',
      );
    });

    test('shorts keyword overrides metadata', () {
      expect(
        classifyBucketByMetadata(
          title: 'مقطع #shorts',
          videoId: 'vid7',
          isLive: true, // would normally be live, but shorts wins
        ),
        'shorts',
      );
    });

    test('title بث standalone → live (no metadata)', () {
      expect(
        classifyBucketByMetadata(
          title: 'بث طاريء: رسالة عاجلة',
          videoId: 'vid8',
        ),
        'live',
      );
    });

    test('title حوارات → live (Arabic debate keyword)', () {
      expect(
        classifyBucketByMetadata(
          title: 'حوارات مع النصارى والملحدين',
          videoId: 'vid9',
        ),
        'live',
      );
    });

    test('title اتصالات → live (call-in keyword)', () {
      expect(
        classifyBucketByMetadata(
          title: 'اتصالات المسلمين',
          videoId: 'vidA',
        ),
        'live',
      );
    });

    test('title حواري مع → live (debate with person)', () {
      expect(
        classifyBucketByMetadata(
          title: 'حواري مع الشيخ الفلاني',
          videoId: 'vidB',
        ),
        'live',
      );
    });

    test('title لقاء → live (meeting keyword)', () {
      expect(
        classifyBucketByMetadata(
          title: 'لقاء مهم مع الضيف',
          videoId: 'vidC',
        ),
        'live',
      );
    });

    test('not live in title → videos (negation wins)', () {
      expect(
        classifyBucketByMetadata(
          title: 'this is not live recording',
          videoId: 'vidD',
        ),
        'videos',
      );
    });

    test('ليس بث → videos (Arabic negation)', () {
      expect(
        classifyBucketByMetadata(
          title: 'هذا ليس بث مباشر',
          videoId: 'vidE',
        ),
        'videos',
      );
    });

    test('no metadata + no live keyword → videos', () {
      expect(
        classifyBucketByMetadata(
          title: 'رضاع الكبير في الإسلام',
          videoId: 'vidF',
        ),
        'videos',
      );
    });

    test('shorts keyword with no metadata → shorts', () {
      expect(
        classifyBucketByMetadata(
          title: 'مقطع #shorts',
          videoId: 'vidG',
        ),
        'shorts',
      );
    });

    test('short Arabic title (شورتس) → shorts', () {
      expect(
        classifyBucketByMetadata(
          title: 'مقطع شورتس قصير',
          videoId: 'vidH',
        ),
        'shorts',
      );
    });
  });

  group('classifyEntries', () {
    test('disjoint buckets — no overlap (legacy: title heuristic)', () {
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

    test('UULV playlist routes past broadcasts → live even with no keywords',
        () {
      // Simulates the HAYTHAM case: "المعجزات" is in UULV but has no
      // live keyword in title. Old heuristic would miss it; new logic
      // catches it from YouTube's own playlist.
      final entries = [
        RawEntry('pastBcast', 'المعجزات واللاكوارث في نظام الطيبات'),
        RawEntry('realVid', 'رضاع الكبير في الإسلام'),
        RawEntry('currentLive', 'بث مباشر الآن'),
      ];
      final buckets = classifyEntries(
        entries: entries,
        channelName: 'Test',
        limit: 15,
        liveVideoIds: {'pastBcast', 'currentLive'},
        metadataMap: {
          'pastBcast': VideoMeta(isLive: false, liveStatus: 'not_live'),
          'realVid': VideoMeta(isLive: false, liveStatus: 'not_live'),
        },
      );
      final liveIds =
          buckets.live.map((s) => s.audioUrl.split('v=').last).toSet();
      final videoIds =
          buckets.videos.map((s) => s.audioUrl.split('v=').last).toSet();
      expect(liveIds.contains('pastBcast'), isTrue);
      expect(liveIds.contains('currentLive'), isTrue);
      expect(videoIds.contains('realVid'), isTrue);
      expect(buckets.live.length, 2);
      expect(buckets.videos.length, 1);
    });
  });
}

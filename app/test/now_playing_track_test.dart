import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/now_playing_track.dart';
import 'package:rill/domain/video_detail.dart';

/// Shapes taken from a real capture (`q_QyaPhykuI`, an 80s mix, 2026-09-25):
/// chapters written "Artist – Song", and cards whose titles carry the asides
/// ("(2016 Remaster)", "(Instrumental)") the uploader left out.
const _mixChapters = [
  Chapter(title: 'a-ha – Take On Me', startSeconds: 0, thumbnailUrl: 'https://f/0.jpg'),
  Chapter(title: 'Michael Jackson – Billie Jean', startSeconds: 222, thumbnailUrl: 'https://f/1.jpg'),
  Chapter(title: 'Wham! – Wake Me Up Before You Go-Go', startSeconds: 515, thumbnailUrl: 'https://f/2.jpg'),
  Chapter(title: 'Technotronic – Pump Up The Jam', startSeconds: 5931, thumbnailUrl: 'https://f/3.jpg'),
];

const _mixMusic = [
  MusicTrack(title: 'Take on Me (2016 Remaster)', artist: 'a-ha', album: 'Hunting High and Low', coverUrl: 'https://c/aha.jpg'),
  MusicTrack(title: 'Billie Jean', artist: 'Michael Jackson', album: 'Thriller', coverUrl: 'https://c/mj.jpg'),
  MusicTrack(title: 'Wake Me Up Before You Go-Go (Instrumental)', artist: 'Wham!', album: 'Make It Big', coverUrl: 'https://c/wham.jpg'),
];

NowPlayingTrack resolve({
  String title = '80s Songs Everyone Knows Mix',
  String channel = 'Some Channel',
  bool music = true,
  List<MusicTrack> credits = _mixMusic,
  List<Chapter> chapters = _mixChapters,
  int? at = 0,
}) => resolveNowPlaying(
  videoTitle: title,
  channelName: channel,
  isMusicVideo: music,
  music: credits,
  chapters: chapters,
  chapterIndex: at,
);

void main() {
  group('chapterIndexAt', () {
    test('is the last chapter that has started', () {
      expect(chapterIndexAt(_mixChapters, Duration.zero), 0);
      expect(chapterIndexAt(_mixChapters, const Duration(seconds: 221)), 0);
      expect(chapterIndexAt(_mixChapters, const Duration(seconds: 222)), 1);
      expect(chapterIndexAt(_mixChapters, const Duration(hours: 5)), 3);
    });

    test('is the first before any has started, and null with none', () {
      const late = [Chapter(title: 'x', startSeconds: 40), Chapter(title: 'y', startSeconds: 90)];
      expect(chapterIndexAt(late, const Duration(seconds: 5)), 0);
      expect(chapterIndexAt(const [], Duration.zero), isNull);
    });
  });

  group('a music mix with chapters', () {
    test('shows the current chapter, with the matching credit\'s cover and album', () {
      final track = resolve(at: 1);
      expect(track.title, 'Billie Jean');
      expect(track.artist, 'Michael Jackson');
      expect(track.album, 'Thriller');
      expect(track.coverUrl, 'https://c/mj.jpg');
      expect(track.backdropUrl, 'https://f/1.jpg');
      expect(track.fromChapter, isTrue);
    });

    test('follows the position across a boundary', () {
      expect(resolve(at: 0).title, 'Take On Me');
      expect(resolve(at: 1).title, 'Billie Jean');
    });

    test('takes the text from the chapter, not from a credit for another version', () {
      // The credit says "(Instrumental)"; the uploader says what they meant.
      final track = resolve(at: 2);
      expect(track.title, 'Wake Me Up Before You Go-Go');
      expect(track.coverUrl, 'https://c/wham.jpg');
    });

    test('a chapter beyond the ten credits has no cover, and still has its text and frame', () {
      final track = resolve(at: 3);
      expect(track.title, 'Pump Up The Jam');
      expect(track.artist, 'Technotronic');
      expect(track.coverUrl, isNull);
      expect(track.album, isNull);
      expect(track.backdropUrl, 'https://f/3.jpg');
    });

    test('reads "Song – Artist" the right way round when the credit knows the artist', () {
      final track = resolve(
        chapters: const [
          Chapter(title: 'Billie Jean – Michael Jackson', startSeconds: 0),
          Chapter(title: 'Take On Me – a-ha', startSeconds: 100),
          Chapter(title: 'Whatever – Nobody', startSeconds: 200),
        ],
        at: 0,
      );
      expect(track.title, 'Billie Jean');
      expect(track.artist, 'Michael Jackson');
    });

    test('a chapter that is only a title shows the channel as its artist', () {
      final track = resolve(
        credits: const [],
        chapters: List.generate(10, (i) => Chapter(title: 'Track $i', startSeconds: i * 100)),
        at: 4,
      );
      expect(track.title, 'Track 4');
      expect(track.artist, 'Some Channel');
    });

    test('a numbered chapter loses its numbering', () {
      final track = resolve(
        credits: const [],
        chapters: const [
          Chapter(title: '01. Daft Punk – One More Time', startSeconds: 0),
          Chapter(title: '02. Daft Punk – Digital Love', startSeconds: 100),
          Chapter(title: '03. Daft Punk – Aerodynamic', startSeconds: 200),
        ],
        at: 1,
      );
      expect(track.title, 'Digital Love');
      expect(track.artist, 'Daft Punk');
    });

    test('an unspaced hyphen is not a separator', () {
      final track = resolve(
        credits: const [],
        chapters: const [
          Chapter(title: 'a-ha', startSeconds: 0),
          Chapter(title: 'Jay-Z', startSeconds: 100),
          Chapter(title: 'Ne-Yo', startSeconds: 200),
        ],
        music: true,
        at: 1,
      );
      // No separator anywhere and no credit: not a tracklist, so the video's own.
      expect(track.fromChapter, isFalse);
    });
  });

  group('when chapters are not songs', () {
    test('a lecture\'s chapters are sections, and are ignored', () {
      final track = resolve(
        title: 'Intro to Physics',
        music: false,
        credits: const [],
        chapters: List.generate(12, (i) => Chapter(title: 'Section $i', startSeconds: i * 60)),
        at: 3,
      );
      expect(track.title, 'Intro to Physics');
      expect(track.fromChapter, isFalse);
      expect(track.backdropUrl, isNull);
    });

    test('a song\'s own sections are not a tracklist', () {
      final track = resolve(
        title: 'Some Band - Some Song (Official Video)',
        credits: const [MusicTrack(title: 'Some Song', artist: 'Some Band')],
        chapters: const [
          Chapter(title: 'Intro', startSeconds: 0),
          Chapter(title: 'Verse', startSeconds: 20),
          Chapter(title: 'Chorus', startSeconds: 50),
        ],
        at: 1,
      );
      expect(track.title, 'Some Song');
      expect(track.fromChapter, isFalse);
    });
  });

  group('a single credit', () {
    const credit = MusicTrack(title: 'Music Title', artist: 'Music Artist', album: 'Album', coverUrl: 'https://c/x.jpg');

    test('is trusted on a music video even when nothing in the text matches', () {
      // Another language, symbols, a stylised title: no shared word at all.
      final track = resolve(title: '夜に駆ける', music: true, credits: const [credit], chapters: const []);
      expect(track.title, 'Music Title');
      expect(track.coverUrl, 'https://c/x.jpg');
    });

    test('is trusted on any video that shares a word with it', () {
      final track = resolve(
        title: 'Music Artist live in concert',
        music: false,
        credits: const [credit],
        chapters: const [],
      );
      expect(track.title, 'Music Title');
    });

    test('is refused on a video that is not music and shares nothing — background music', () {
      final track = resolve(
        title: 'Portal 2 Co-op Walkthrough',
        channel: 'Some Gamer',
        music: false,
        credits: const [credit],
        chapters: const [],
      );
      expect(track.title, 'Portal 2 Co-op Walkthrough');
      expect(track.artist, 'Some Gamer');
      expect(track.coverUrl, isNull);
    });

    test('a Topic channel counts as music', () {
      expect(isTopicChannel('Daft Punk - Topic'), isTrue);
      expect(isTopicChannel('Daft Punk'), isFalse);
    });

    test('shows the channel when the credit names no artist', () {
      final track = resolve(
        title: 'Music Title',
        music: true,
        credits: const [MusicTrack(title: 'Music Title')],
        chapters: const [],
      );
      expect(track.artist, 'Some Channel');
    });
  });

  group('several credits and no chapters', () {
    test('picks the one the video\'s title is about', () {
      final track = resolve(title: 'Michael Jackson - Billie Jean (Official Video)', chapters: const []);
      expect(track.title, 'Billie Jean');
      expect(track.coverUrl, 'https://c/mj.jpg');
    });

    test('guesses nothing when the title is about none of them', () {
      final track = resolve(title: '80s Songs Everyone Knows Mix', chapters: const []);
      expect(track.title, '80s Songs Everyone Knows Mix');
      expect(track.coverUrl, isNull);
    });
  });

  test('nothing at all is the video\'s own title and channel', () {
    final track = resolve(credits: const [], chapters: const [], music: false);
    expect(track.title, '80s Songs Everyone Knows Mix');
    expect(track.artist, 'Some Channel');
  });
}

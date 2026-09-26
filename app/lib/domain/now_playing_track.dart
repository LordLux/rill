import 'video_detail.dart';

/// What the now-playing surfaces show for the current moment of a video —
/// `architecture.md` §2.12.
///
/// **One answer, read by everything**: the audio-only layout, its backdrop and
/// the Windows media flyout. Before this, each read `music.firstOrNull` on its
/// own, so they could disagree, and all of them trusted a credit that was
/// sometimes a game, a background track or one song out of twenty.
class NowPlayingTrack {
  const NowPlayingTrack({
    required this.title,
    required this.artist,
    this.album,
    this.coverUrl,
    this.backdropUrl,
    this.fromChapter = false,
  });

  final String title;

  /// The performer, or the channel when nothing better is known.
  final String? artist;
  final String? album;

  /// A sharp square cover — only ever a song credit's, never a video frame.
  final String? coverUrl;

  /// The current chapter's frame, for the blurred backdrop only. Null when the
  /// chapters are not being read as songs or carry no image.
  final String? backdropUrl;

  /// Whether the chapters, not just the credits, decided this.
  final bool fromChapter;

  @override
  bool operator ==(Object other) =>
      other is NowPlayingTrack &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.coverUrl == coverUrl &&
      other.backdropUrl == backdropUrl &&
      other.fromChapter == fromChapter;

  @override
  int get hashCode => Object.hash(title, artist, album, coverUrl, backdropUrl, fromChapter);

  @override
  String toString() => 'NowPlayingTrack($title / $artist / $album, cover: $coverUrl, backdrop: $backdropUrl)';
}

/// The chapter playing at [position]: the last one that has started, and the
/// first before any has. Null only when there are none.
int? chapterIndexAt(List<Chapter> chapters, Duration position) {
  if (chapters.isEmpty) return null;
  final seconds = position.inSeconds;
  var index = 0;
  for (var i = 0; i < chapters.length; i++) {
    if (chapters[i].startSeconds <= seconds) index = i;
  }
  return index;
}

/// Words that say what kind of upload this is rather than which song. Left out
/// of every comparison so "Official Video" cannot make two songs look alike,
/// nor its absence make one look different.
const _filler = {
  'the', 'a', 'an', 'of', 'and', 'feat', 'ft', 'featuring', 'official', 'video', 'audio', //
  'lyrics', 'lyric', 'music', 'mix', 'hd', 'hq', 'remastered', 'remaster', 'version', 'edit',
};

final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);
final _aside = RegExp(r'\([^)]*\)|\[[^\]]*\]');

/// The words that identify [text], lower-cased, without fillers.
///
/// Unicode-aware, so a title in another script still yields words rather than
/// nothing. Parenthetical asides — "(2016 Remaster)", "[Official Video]" — are
/// dropped first, because they are where a credit and an uploader disagree most;
/// if that leaves nothing the text is read whole.
Set<String> _tokens(String? text) {
  if (text == null) return const {};
  Set<String> read(String s) =>
      _word.allMatches(s.toLowerCase()).map((m) => m.group(0)!).where((w) => !_filler.contains(w)).toSet();
  final stripped = read(text.replaceAll(_aside, ' '));
  return stripped.isNotEmpty ? stripped : read(text);
}

/// How much of [needle] is present in [haystack], 0–1. Empty needle → 0.
double _coverage(Set<String> needle, Set<String> haystack) {
  if (needle.isEmpty) return 0;
  return needle.where(haystack.contains).length / needle.length;
}

final _numbering = RegExp(r'^\s*\d{1,3}[.)]\s+');
final _dash = RegExp(r'\s[-–—]\s');

/// "Artist – Song" → (Artist, Song). Neither side null or the whole thing in
/// [title]. Split on the *first* spaced dash, so "Artist – Song – Live" keeps
/// its tail with the song; an unspaced hyphen ("A-ha") is never a separator.
({String? left, String? right, String whole}) _split(String chapterTitle) {
  final whole = chapterTitle.replaceFirst(_numbering, '').trim();
  final match = _dash.firstMatch(whole);
  if (match == null) return (left: null, right: null, whole: whole);
  final left = whole.substring(0, match.start).trim();
  final right = whole.substring(match.end).trim();
  if (left.isEmpty || right.isEmpty) return (left: null, right: null, whole: whole);
  return (left: left, right: right, whole: whole);
}

/// The credit a chapter's text is about, or null.
///
/// Needs the song's words to be mostly in the chapter and, when the credit names
/// an artist, at least one of the artist's. Both, because a chapter reading
/// "Halo" is not evidence for *any* credit called "Halo".
MusicTrack? _cardForChapter(String chapterTitle, List<MusicTrack> music) {
  final words = _tokens(chapterTitle);
  MusicTrack? best;
  var bestScore = 0.0;
  for (final track in music) {
    final title = _coverage(_tokens(track.title), words);
    if (title < 0.6) continue;
    final artistWords = _tokens(track.artist);
    final artist = _coverage(artistWords, words);
    if (artistWords.isNotEmpty && artist == 0) continue;
    final score = title + artist * 0.5;
    if (score > bestScore) {
      bestScore = score;
      best = track;
    }
  }
  return best;
}

/// Whether [chapters] divide a video into songs, as opposed to sections.
///
/// Two gates. The video has to be music at all — a lecture's chapters would
/// read as song titles — and the chapters have to look like a *tracklist*: a
/// lyric video's "Intro / Verse / Chorus" is music with chapters and is not
/// one. Any of three says tracklist: too many to be sections of one song (nine
/// or more), most of them written "Artist – Song", or most of them naming a
/// credited song.
bool _chaptersAreSongs(
  List<Chapter> chapters,
  List<MusicTrack> music, {
  required bool isMusicVideo,
}) {
  if (chapters.isEmpty || !(isMusicVideo || music.isNotEmpty)) return false;
  if (chapters.length >= 9) return true;
  final half = chapters.length / 2;
  final dashed = chapters.where((c) => _split(c.title).left != null).length;
  if (dashed >= half) return true;
  final credited = chapters.where((c) => _cardForChapter(c.title, music) != null).length;
  return credited >= half;
}

/// Whether a lone credit is believable for this video.
///
/// **Deliberately lenient**: a video's title and its credit legitimately
/// disagree — the artist repeated, symbols, another language, "(Official
/// Video)" — so an exact or near-exact match would reject good credits. Any one
/// signal passes: the video is music (the ♪, an artist channel, a Topic
/// channel), or it shares any word with the credit's song or artist. What is
/// left over is the credit on a video that is not about it — a game's soundtrack
/// under commentary — and that is the case worth refusing.
bool _believable(
  MusicTrack track, {
  required bool isMusicVideo,
  required String videoTitle,
  required String channelName,
}) {
  if (isMusicVideo) return true;
  final around = {..._tokens(videoTitle), ..._tokens(channelName)};
  return _coverage(_tokens(track.title), around) > 0 || _coverage(_tokens(track.artist), around) > 0;
}

/// Whether [channelName] is one of YouTube's auto-generated artist channels.
bool isTopicChannel(String channelName) => channelName.trimRight().endsWith('- Topic');

/// Decide what is playing.
///
/// In order:
///
///  1. **A music video whose chapters are a tracklist** — each chapter is a song,
///     so the current chapter's text is the answer. It is matched to a credit only for the
///     cover and album, because the credit can be another version of the song
///     (`(Instrumental)`) while the uploader's chapter says what they meant.
///  2. **One believable credit** — a credit, when [_believable].
///  3. **Several credits and no chapters** — the one the *video's title* is
///     about, if any. Which of ten is playing is otherwise a guess, and a wrong
///     song is worse than the video's own title.
///  4. **Nothing** — the video's title and channel, which is always right.
///
/// [isMusicVideo] is the ♪ on the tile, an artist-channel badge or a Topic
/// channel — the caller's to compute, since the tile is not in this layer.
NowPlayingTrack resolveNowPlaying({
  required String videoTitle,
  required String channelName,
  required bool isMusicVideo,
  required List<MusicTrack> music,
  required List<Chapter> chapters,
  required int? chapterIndex,
}) {
  final plain = NowPlayingTrack(title: videoTitle, artist: channelName);

  if (_chaptersAreSongs(chapters, music, isMusicVideo: isMusicVideo)) {
    final chapter = chapters[(chapterIndex ?? 0).clamp(0, chapters.length - 1)];
    final parts = _split(chapter.title);
    final card = _cardForChapter(chapter.title, music);

    String title = parts.whole;
    String? artist = parts.left;
    if (parts.left != null && parts.right != null) {
      title = parts.right!;
      final known = _tokens(card?.artist);
      // "Song – Artist" rather than "Artist – Song": the credit knows which.
      if (known.isNotEmpty &&
          _coverage(known, _tokens(parts.right)) > _coverage(known, _tokens(parts.left))) {
        title = parts.left!;
        artist = parts.right;
      }
    }
    return NowPlayingTrack(
      title: title,
      artist: artist ?? card?.artist ?? channelName,
      album: card?.album,
      coverUrl: card?.coverUrl,
      backdropUrl: chapter.thumbnailUrl,
      fromChapter: true,
    );
  }

  if (music.length == 1) {
    final track = music.single;
    if (!_believable(track, isMusicVideo: isMusicVideo, videoTitle: videoTitle, channelName: channelName)) {
      return plain;
    }
    return _fromCredit(track, channelName);
  }

  if (music.length > 1) {
    final about = _cardForChapter(videoTitle, music);
    if (about != null) return _fromCredit(about, channelName);
  }

  return plain;
}

NowPlayingTrack _fromCredit(MusicTrack track, String channelName) => NowPlayingTrack(
      title: track.title,
      artist: track.artist ?? channelName,
      album: track.album,
      coverUrl: track.coverUrl,
    );

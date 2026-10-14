/// What counts as "a pasted link to one video", and to a playlist — the rules the
/// search box uses to open either instead of searching for it (`openSearchOrVideo`).
///
/// **Mutation** run against this file: drop the `shorts` case from
/// `videoIdFromLink` and the first group fails on every `/shorts/` link, which is
/// the one YouTube's own search returns nothing for.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/youtube_link.dart';

void main() {
  group('a link to one video is that video', () {
    const short = 'SbRTk0ca7WY';
    const video = 'q_QyaPhykuI';

    final cases = <String, String>{
      // The link that started this: a Short, as the share button copies it.
      'https://www.youtube.com/shorts/$short?feature=share': short,
      'https://www.youtube.com/shorts/$short': short,
      'https://youtube.com/shorts/$short/': short,
      'https://m.youtube.com/shorts/$short': short,
      'youtube.com/shorts/$short': short,
      'www.youtube.com/shorts/$short?si=abc123': short,
      // The other shapes a video link comes in.
      'https://www.youtube.com/watch?v=$video': video,
      'https://www.youtube.com/watch?v=$video&t=42s': video,
      'https://www.youtube.com/watch?feature=share&v=$video': video,
      'https://m.youtube.com/watch?v=$video': video,
      'https://music.youtube.com/watch?v=$video&si=abc': video,
      'https://youtu.be/$video': video,
      'https://youtu.be/$video?t=10': video,
      'youtu.be/$video': video,
      'https://www.youtube.com/live/$video?si=x': video,
      'https://www.youtube.com/embed/$video': video,
      'https://www.youtube.com/v/$video': video,
      // A mix or playlist link is the video; the list is not opened.
      'https://www.youtube.com/watch?v=$video&list=RD$video': video,
      // Case: the scheme and host are not case-sensitive, the id is.
      'HTTPS://WWW.YOUTUBE.COM/shorts/$short': short,
      // Whatever was pasted around it.
      '  https://youtu.be/$video\n': video,
      // An id is made of letters, digits, '-' and '_'.
      'https://youtu.be/-_-_-_-_-_-': '-_-_-_-_-_-',
    };

    for (final entry in cases.entries) {
      test(entry.key.trim(), () => expect(videoIdFromLink(entry.key), entry.value));
    }
  });

  group('anything else is not', () {
    final cases = <String, String>{
      'nothing': '',
      'only whitespace': '   ',
      'a search': 'lofi hip hop',
      'a sentence with a link in it': 'watch this https://youtu.be/q_QyaPhykuI please',
      'a bare id, which is a search like any other': 'q_QyaPhykuI',
      'a playlist': 'https://www.youtube.com/playlist?list=PLrEnWoR732-BHrPp_Pm8_VleD68f9s14-',
      'a channel': 'https://www.youtube.com/@ado',
      'the home page': 'https://www.youtube.com/',
      'a watch link with no video': 'https://www.youtube.com/watch',
      'a Shorts link with no id': 'https://www.youtube.com/shorts/',
      'an id one character short': 'https://youtu.be/q_QyaPhykuI'.substring(0, 27),
      'an id one character long': 'https://youtu.be/q_QyaPhykuIx',
      'an id with a character it cannot have': 'https://youtu.be/q_QyaPhyku!',
      'another site with the same path': 'https://vimeo.com/shorts/SbRTk0ca7WY',
      'a host that only ends like youtube': 'https://notyoutube.com/watch?v=q_QyaPhykuI',
      'a host that only starts like youtube': 'https://youtube.com.example.org/watch?v=q_QyaPhykuI',
      'youtu.be as a path on another host': 'https://example.org/youtu.be/q_QyaPhykuI',
      'a scheme that is not a web one': 'ftp://youtube.com/shorts/SbRTk0ca7WY',
      'a script': 'javascript://youtube.com/shorts/SbRTk0ca7WY',
    };

    for (final entry in cases.entries) {
      test(entry.key, () => expect(videoIdFromLink(entry.value), isNull));
    }
  });

  group('a link to a playlist is that playlist', () {
    const id = 'PLrEnWoR732-BHrPp_Pm8_VleD68f9s14-';

    final cases = <String, String>{
      'https://www.youtube.com/playlist?list=$id': id,
      'https://youtube.com/playlist?list=$id': id,
      'https://m.youtube.com/playlist?list=$id&si=abc123': id,
      'https://music.youtube.com/playlist?list=OLAK5uy_abc-DEF_123': 'OLAK5uy_abc-DEF_123',
      'youtube.com/playlist?list=$id': id,
      'https://www.youtube.com/playlist/?list=$id': id,
      'HTTPS://WWW.YOUTUBE.COM/playlist?list=$id': id,
      '  https://www.youtube.com/playlist?list=$id\n': id,
      // The viewer's own lists have short ids.
      'https://www.youtube.com/playlist?list=WL': 'WL',
      'https://www.youtube.com/playlist?list=LL': 'LL',
    };

    for (final entry in cases.entries) {
      test(entry.key.trim(), () => expect(playlistIdFromLink(entry.key), entry.value));
    }
  });

  group('anything else is not a playlist', () {
    const id = 'PLrEnWoR732-BHrPp_Pm8_VleD68f9s14-';
    final cases = <String, String>{
      'nothing': '',
      'a search': 'my playlist',
      'a sentence with a link in it': 'see https://www.youtube.com/playlist?list=$id',
      'a bare id': id,
      // The video is what was linked; the list rides along.
      'a video in a playlist': 'https://www.youtube.com/watch?v=q_QyaPhykuI&list=$id',
      'a short link to a video in a playlist': 'https://youtu.be/q_QyaPhykuI?list=$id',
      // A mix has no page of its own.
      'a mix': 'https://www.youtube.com/playlist?list=RDq_QyaPhykuI',
      'a playlist link with no list': 'https://www.youtube.com/playlist',
      'an empty list': 'https://www.youtube.com/playlist?list=',
      'a list with a character it cannot have': 'https://www.youtube.com/playlist?list=PL!abc',
      'a longer path': 'https://www.youtube.com/playlist/more?list=$id',
      'a channel': 'https://www.youtube.com/@ado',
      'another site with the same path': 'https://vimeo.com/playlist?list=$id',
      'a host that only ends like youtube': 'https://notyoutube.com/playlist?list=$id',
      'youtu.be, which has no playlist address': 'https://youtu.be/playlist?list=$id',
      'a scheme that is not a web one': 'ftp://youtube.com/playlist?list=$id',
    };

    for (final entry in cases.entries) {
      test(entry.key, () => expect(playlistIdFromLink(entry.value), isNull));
    }
  });

  test('the placeholder is what a tile would have supplied, and nothing more', () {
    final item = placeholderVideoItem('SbRTk0ca7WY');
    expect(item.id, 'SbRTk0ca7WY');
    expect(item.isLive, isFalse);
    expect(item.thumbnailUrl, isEmpty);
    expect(item.channelName, isEmpty);
  });
}

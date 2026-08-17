class CaptionCue {
  const CaptionCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;

  factory CaptionCue.fromJson(Map<String, dynamic> json) {
    return CaptionCue(
      startMs: json['startMs'] as int,
      endMs: json['endMs'] as int,
      text: json['text'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'startMs': startMs,
    'endMs': endMs,
    'text': text,
  };
}

class VideoCaptionsResult {
  const VideoCaptionsResult({
    required this.cues,
  });

  final List<CaptionCue> cues;

  factory VideoCaptionsResult.fromJson(Map<String, dynamic> json) {
    return VideoCaptionsResult(
      cues: (json['cues'] as List).map((e) => CaptionCue.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'cues': cues.map((e) => e.toJson()).toList(),
  };
}

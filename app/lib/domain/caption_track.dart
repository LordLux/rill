class CaptionTrack {
  const CaptionTrack({
    required this.label,
    required this.languageCode,
    required this.vssId,
    required this.kind,
    required this.url,
  });

  final String label;
  final String languageCode;
  final String vssId;
  final String kind;
  final String url;

  factory CaptionTrack.fromJson(Map<String, dynamic> json) {
    return CaptionTrack(
      label: json['label'] as String? ?? '',
      languageCode: json['languageCode'] as String? ?? '',
      vssId: json['vssId'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    'languageCode': languageCode,
    'vssId': vssId,
    'kind': kind,
    'url': url,
  };
}

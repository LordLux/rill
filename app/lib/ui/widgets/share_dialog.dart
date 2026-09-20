import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/feed_item.dart';

Future<void> showShareDialog(BuildContext context, VideoItem item, {Duration position = Duration.zero}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ShareDialog(item: item, position: position),
  );
}

const Set<String> _launchableSchemes = {'http', 'https', 'mailto'};

void _openInBrowser(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !_launchableSchemes.contains(uri.scheme)) return;
  unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
}

/// The share sheet (mock 4) + OS shows the system sharesheet.
///
/// Drawn **disabled**: we need `IDataTransferManagerInterop::ShowShareUIForWindow(HWND)`
/// WinRT interop through the runner.
class ShareDialog extends StatefulWidget {
  const ShareDialog({super.key, required this.item, required this.position});

  final VideoItem item;

  /// Where the video was when the dialog opened. `Duration.zero` when this is
  /// not the video that is playing, which is what hides "Start at".
  final Duration position;

  @override
  State<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<ShareDialog> {
  bool _startAt = false;

  /// The short form, because it is the one that survives being pasted into a
  /// chat client that eats query strings — and `?t=` is the only parameter
  /// anything here appends.
  String get _link {
    final base = 'https://youtu.be/${widget.item.id}';
    if (!_startAt) return base;
    return '$base?t=${widget.position.inSeconds}';
  }

  String get _embed {
    final start = _startAt ? '?start=${widget.position.inSeconds}' : '';
    return '<iframe width="560" height="315" '
        'src="https://www.youtube.com/embed/${widget.item.id}$start" '
        'title="${htmlEscape.convert(widget.item.title)}" frameborder="0" allowfullscreen></iframe>';
  }

  Future<void> _copy(String value, String said) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
  }

  // ignore: rill_lints/no_color_literals
  final faceBookColor = const Color(0xFF0866FF);
  // ignore: rill_lints/no_color_literals
  final xColor = const Color(0xFF000000);
  // ignore: rill_lints/no_color_literals
  final redditColor = const Color(0xFFFF4500);
  // ignore: rill_lints/no_color_literals
  final messagesColor = const Color(0xFFFFFFFF);
  // ignore: rill_lints/no_color_literals
  final telegramColor = const Color(0xFF0088CC);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = widget.item.title;

    // Six targets at 56 + 12 of gutter fit the 460 the dialog is wide, so there
    // is no scroll and therefore no chevron. Mock 4 has one because YouTube's
    // row genuinely runs off the edge; drawing the affordance over content that
    // never moves would be worse than not drawing it.
    final targets = <Widget>[
      _ShareTarget(
        label: 'Embed',
        icon: Icons.code,
        onTap: () => _copy(_embed, 'Embed code copied'),
      ),
      _ShareTarget(
        label: 'X',
        hoverColor: xColor,
        iconBuilder: (color, _) => SizedBox(
          width: 21,
          height: 21,
          child: SvgPicture.asset(
            'assets/icons/x.svg',
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
        onTap: () => _openInBrowser(
          'https://x.com/intent/post'
          '?url=${Uri.encodeComponent(_link)}&text=${Uri.encodeComponent(title)}',
        ),
      ),
      _ShareTarget(
        label: 'Reddit',
        hoverColor: redditColor,
        iconBuilder: (color, isHovered) => SizedBox(
          width: 31,
          height: 31,
          child: SvgPicture.asset(
            'assets/icons/reddit.svg',
          ),
        ),
        onTap: () => _openInBrowser(
          'https://www.reddit.com/submit'
          '?url=${Uri.encodeComponent(_link)}&title=${Uri.encodeComponent(title)}',
        ),
      ),
      _ShareTarget(
        label: 'Facebook',
        hoverColor: faceBookColor,
        iconBuilder: (color, _) => SizedBox(
          width: 48,
          height: 48,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Transform.scale(
              scale: 1.35,
              child: SvgPicture.asset(
                'assets/icons/facebook.svg',
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
            ),
          ),
        ),
        onTap: () => _openInBrowser(
          'https://www.facebook.com/sharer/sharer.php?u=${Uri.encodeComponent(_link)}',
        ),
      ),
      _ShareTarget(
        label: 'Messages',
        hoverColor: messagesColor,
        iconBuilder: (color, isHovered) => SizedBox(
          width: 48,
          height: 48,
          child: Padding(
            padding: const EdgeInsets.all(10).copyWith(top: 13),
            child: SvgPicture.asset(
              'assets/icons/messages.svg',
            ),
          ),
        ),
        onTap: () => _openInBrowser(
          'https://messages.google.com/web/welcome?redirectUrl=${Uri.encodeComponent("/share?text=${Uri.encodeComponent(_link)}")}',
        ),
      ),
      _ShareTarget(
        label: 'Telegram',
        hoverColor: telegramColor,
        iconBuilder: (color, _) => SizedBox(
          width: 40,
          height: 40,
          child: SvgPicture.asset(
            'assets/icons/telegram.svg',
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
        onTap: () => _openInBrowser(
          'https://t.me/share/url'
          '?url=${Uri.encodeComponent(_link)}&text=${Uri.encodeComponent(title)}',
        ),
      ),
      _ShareTarget(
        label: 'Email',
        icon: Icons.mail_outline,
        onTap: () => _openInBrowser(
          'mailto:?subject=${Uri.encodeComponent(title)}&body=${Uri.encodeComponent(_link)}',
        ),
      ),
    ];

    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 460,
        child: Padding(
          // The gutters live on each section rather than on the whole column:
          // the close button has to sit closer to the edge than the content
          // does, and a single outer padding cannot give it that.
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 12),
                child: Row(
                  children: [
                    const SizedBox(width: 36),
                    Expanded(
                      child: Text(
                        'Share',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: scheme.onSurface),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 20),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Column(
                children: [
                  FilledButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share via Windows…'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Share this video using the OS share sheet.',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  // Not "Share" a second time: the title already said it, and
                  // the label's job here is to separate the row that works from
                  // the button above it that does not yet.
                  'Send to',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SizedBox(
                  height: 70,
                  child: SilkyListView.builder(
                    shrinkWrap: true,
                    itemCount: targets.length,
                    scrollDirection: Axis.horizontal,
                    itemBuilder: (context, index) => Padding(
                      padding: EdgeInsets.only(right: index == targets.length - 1 ? 0 : 6),
                      child: targets[index],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.only(left: 16, right: 6),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _link,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: scheme.onSurface),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // The one white thing in the dialog, same as the mock and
                      // the same role the pills go to when they are on.
                      FilledButton(
                        onPressed: () => _copy(_link, 'Link copied'),
                        style: FilledButton.styleFrom(
                          backgroundColor: scheme.inverseSurface,
                          foregroundColor: scheme.onInverseSurface,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                        ),
                        child: Transform.translate(offset: const Offset(0, -1), child: const Text('Copy')),
                      ),
                    ],
                  ),
                ),
              ),
              // Nothing to start at on a video that has not started, and nothing
              // to offer when the thing being shared is not the thing playing.
              if (widget.position > Duration.zero) ...[
                const SizedBox(height: 10),
                InkWell(
                  borderRadius: BorderRadius.only(bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
                  onTap: () => setState(() => _startAt = !_startAt),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _startAt,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: (next) => setState(() => _startAt = next ?? false),
                        ),
                        const SizedBox(width: 8),
                        Text('Start at', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
                        const SizedBox(width: 8),
                        Text(
                          _formatDuration(widget.position),
                          style: TextStyle(fontSize: 13, color: scheme.primary),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(hours > 0 ? 2 : 1, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

class _ShareTarget extends StatefulWidget {
  const _ShareTarget({
    required this.label,
    this.icon,
    this.iconBuilder,
    this.hoverColor,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final Widget Function(Color color, bool isHovered)? iconBuilder;
  final Color? hoverColor;
  final VoidCallback onTap;

  @override
  State<_ShareTarget> createState() => _ShareTargetState();
}

class _ShareTargetState extends State<_ShareTarget> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isHoverState = _isHovered && widget.hoverColor != null;
    final bg = isHoverState ? widget.hoverColor! : scheme.surfaceContainerHighest;
    // ignore: rill_lints/no_color_literals
    final iconColor = isHoverState ? const Color(0xFFFFFFFF) : scheme.onSurface;

    return SizedBox(
      width: 60,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bg,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onHover: (hovered) => setState(() => _isHovered = hovered),
                onTap: widget.onTap,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: widget.icon != null
                        ? Icon(widget.icon, size: 22, color: iconColor)
                        : widget.iconBuilder != null
                        ? widget.iconBuilder!(iconColor, _isHovered)
                        : Text(
                            widget.label,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: iconColor,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

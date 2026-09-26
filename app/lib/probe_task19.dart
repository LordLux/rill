import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rill/data/playback/engine.dart';
import 'package:rill/domain/playback_source.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final engine = MediaKitEngine();
  runApp(MaterialApp(home: _ProbeApp(engine: engine)));
}

class _ProbeApp extends StatefulWidget {
  final MediaKitEngine engine;
  const _ProbeApp({required this.engine});
  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final out = File('C:\\Users\\LordLux\\Desktop\\probe.txt').openWrite();
    final native = widget.engine.diagnostics;
    // use absolute path to ensure it works
    final url = File('test.mp4').absolute.path;
    
    out.writeln('PROBE START');
    await widget.engine.open(PlaybackVariant(videoUrl: url, height: 720, fps: 30, videoCodec: 'h264', audioCodec: 'aac'));
    
    await Future.delayed(Duration(seconds: 2));
    var cacheAuto = await native.getProperty('demuxer-cache-state');
    out.writeln('PROBE CACHE (AUTO): $cacheAuto');
    
    final t0 = Stopwatch()..start();
    await native.setProperty('vid', 'no');
    out.writeln('PROBE VID=NO TOOK: \${t0.elapsedMilliseconds}ms');
    
    await Future.delayed(Duration(seconds: 2));
    var cacheNo = await native.getProperty('demuxer-cache-state');
    out.writeln('PROBE CACHE (NO): $cacheNo');
    
    t0.reset();
    await native.setProperty('vid', 'auto');
    out.writeln('PROBE VID=AUTO TOOK: \${t0.elapsedMilliseconds}ms');
    
    await Future.delayed(Duration(seconds: 2));
    await out.close();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: widget.engine.videoSurface(),
    );
  }
}

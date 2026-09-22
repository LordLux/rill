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
  
  runApp(MaterialApp(
    home: Scaffold(
      body: FutureBuilder(
        future: _run(engine),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text(snapshot.error.toString());
          return Center(child: Text('Running probe...'));
        },
      ),
    ),
  ));
}

Future<void> _run(MediaKitEngine engine) async {
  final out = File('C:\\Users\\LordLux\\Desktop\\probe.txt').openWrite();
  out.writeln('Probe started');
  
  final native = engine.diagnostics;
  
  final url = 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';
  out.writeln('Opening stream...');
  
  try {
    await engine.open(
      PlaybackVariant(
        videoUrl: url,
        height: 720,
        fps: 30,
        videoCodec: 'h264',
        audioCodec: 'aac',
      ),
      play: true,
    );
    out.writeln('Opened stream successfully');
  } catch (e) {
    out.writeln('Open error: $e');
  }

  await Future.delayed(Duration(seconds: 4));
  var vid = await native.getProperty('vid');
  var cache = await native.getProperty('demuxer-cache-state');
  out.writeln('Playing with video... vid=$vid');
  out.writeln('Cache: $cache');
  
  out.writeln('Setting vid=no...');
  final stopWatch = Stopwatch()..start();
  await native.setProperty('vid', 'no');
  out.writeln('Setting vid=no took \${stopWatch.elapsedMilliseconds}ms');
  
  await Future.delayed(Duration(seconds: 4));
  vid = await native.getProperty('vid');
  cache = await native.getProperty('demuxer-cache-state');
  out.writeln('After vid=no, vid=$vid');
  out.writeln('Cache: $cache');
  
  out.writeln('Setting vid=auto...');
  stopWatch.reset();
  await native.setProperty('vid', 'auto');
  out.writeln('Setting vid=auto took \${stopWatch.elapsedMilliseconds}ms');
  
  await Future.delayed(Duration(seconds: 2));
  await out.close();
  exit(0);
}

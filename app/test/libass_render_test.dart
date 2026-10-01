import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rill/ui/player/libass/ass_binding.dart';
import 'package:rill/ui/player/libass/dll_search.dart';
import 'package:rill/ui/player/libass_layer.dart';

void main() {
  test('LibassLayer renders styled ASS documents correctly', () async {
    final dylib = openLibass();
    final bindings = LibAssBindings(dylib);

    final library = bindings.ass_library_init();
    expect(library, isNot(nullptr));
    
    final renderer = bindings.ass_renderer_init(library);
    expect(renderer, isNot(nullptr));
    bindings.ass_set_frame_size(renderer, 1920, 1080);
    
    final fontsDir = r'C:\Windows\Fonts'.toNativeUtf8();
    bindings.ass_set_fonts(renderer, nullptr, nullptr, 1, fontsDir, 1);
    malloc.free(fontsDir);
    
    final track = bindings.ass_new_track(library);
    expect(track, isNot(nullptr));
    
    final doc = '''[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: RedText,Arial,60,&H000000FF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:05.00,RedText,,0,0,0,,This is a styled test string
''';
    
    final data = doc.toNativeUtf8();
    bindings.ass_process_data(track, data, doc.length);
    malloc.free(data);
    
    final images = LibassLayer.renderIsolateForTesting(
      renderer.address, 
      track.address, 
      2000, 
      0, 
      0
    );
    
    expect(images.length, greaterThan(0), reason: 'Should produce at least one image');
    
    bool anyPositioned = false;
    bool foundRed = false;
    
    for (final img in images) {
      if (img.x != 0 || img.y != 0) anyPositioned = true;
      
      final pixels = img.pixels.materialize().asUint8List();
      for (int i = 0; i < pixels.length; i += 4) {
        if (pixels[i + 3] > 0) { // non-transparent
          if (pixels[i] > 100 && pixels[i + 1] < 50 && pixels[i + 2] < 50) {
            foundRed = true;
          }
        }
      }
    }
    
    expect(anyPositioned, isTrue, reason: 'Images should have a non-origin position due to layout');
    expect(foundRed, isTrue, reason: 'Images should contain styled red pixels, not the default white');
    
    bindings.ass_free_track(track);
    bindings.ass_renderer_done(renderer);
    bindings.ass_library_done(library);
  });
}

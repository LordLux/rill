import 'dart:ffi';
import 'package:ffi/ffi.dart';

// ASS_Library
final class ASS_Library extends Opaque {}

// ASS_Renderer
final class ASS_Renderer extends Opaque {}

// ASS_Track
final class ASS_Track extends Opaque {}

// ASS_Image
final class ASS_Image extends Struct {
  @Int32()
  external int w;

  @Int32()
  external int h;

  @Int32()
  external int stride;

  external Pointer<Uint8> bitmap;

  @Uint32()
  external int color;

  @Int32()
  external int dst_x;

  @Int32()
  external int dst_y;

  external Pointer<ASS_Image> next;

  @Int32()
  external int type;
}

class LibAssBindings {
  final DynamicLibrary _lib;

  LibAssBindings(this._lib) {
    _ass_library_init = _lib.lookupFunction<Pointer<ASS_Library> Function(), Pointer<ASS_Library> Function()>('ass_library_init');
    _ass_library_done = _lib.lookupFunction<Void Function(Pointer<ASS_Library>), void Function(Pointer<ASS_Library>)>('ass_library_done');
    _ass_renderer_init = _lib.lookupFunction<Pointer<ASS_Renderer> Function(Pointer<ASS_Library>), Pointer<ASS_Renderer> Function(Pointer<ASS_Library>)>('ass_renderer_init');
    _ass_renderer_done = _lib.lookupFunction<Void Function(Pointer<ASS_Renderer>), void Function(Pointer<ASS_Renderer>)>('ass_renderer_done');
    _ass_set_frame_size = _lib.lookupFunction<Void Function(Pointer<ASS_Renderer>, Int32, Int32), void Function(Pointer<ASS_Renderer>, int, int)>('ass_set_frame_size');
    _ass_set_margins = _lib.lookupFunction<Void Function(Pointer<ASS_Renderer>, Int32, Int32, Int32, Int32), void Function(Pointer<ASS_Renderer>, int, int, int, int)>('ass_set_margins');
    _ass_set_use_margins = _lib.lookupFunction<Void Function(Pointer<ASS_Renderer>, Int32), void Function(Pointer<ASS_Renderer>, int)>('ass_set_use_margins');
    _ass_set_pixel_aspect = _lib.lookupFunction<Void Function(Pointer<ASS_Renderer>, Double), void Function(Pointer<ASS_Renderer>, double)>('ass_set_pixel_aspect');
    _ass_set_storage_size = _lib.lookupFunction<Void Function(Pointer<ASS_Renderer>, Int32, Int32), void Function(Pointer<ASS_Renderer>, int, int)>('ass_set_storage_size');
    _ass_set_fonts = _lib.lookupFunction<Void Function(Pointer<ASS_Renderer>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Utf8>, Int32), void Function(Pointer<ASS_Renderer>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>, int)>('ass_set_fonts');
    _ass_new_track = _lib.lookupFunction<Pointer<ASS_Track> Function(Pointer<ASS_Library>), Pointer<ASS_Track> Function(Pointer<ASS_Library>)>('ass_new_track');
    _ass_free_track = _lib.lookupFunction<Void Function(Pointer<ASS_Track>), void Function(Pointer<ASS_Track>)>('ass_free_track');
    _ass_process_data = _lib.lookupFunction<Void Function(Pointer<ASS_Track>, Pointer<Utf8>, Int32), void Function(Pointer<ASS_Track>, Pointer<Utf8>, int)>('ass_process_data');
    _ass_render_frame = _lib.lookupFunction<Pointer<ASS_Image> Function(Pointer<ASS_Renderer>, Pointer<ASS_Track>, Int64, Pointer<Int32>), Pointer<ASS_Image> Function(Pointer<ASS_Renderer>, Pointer<ASS_Track>, int, Pointer<Int32>)>('ass_render_frame');
  }

  late final Pointer<ASS_Library> Function() _ass_library_init;
  Pointer<ASS_Library> ass_library_init() => _ass_library_init();

  late final void Function(Pointer<ASS_Library>) _ass_library_done;
  void ass_library_done(Pointer<ASS_Library> priv) => _ass_library_done(priv);

  late final Pointer<ASS_Renderer> Function(Pointer<ASS_Library>) _ass_renderer_init;
  Pointer<ASS_Renderer> ass_renderer_init(Pointer<ASS_Library> priv) => _ass_renderer_init(priv);

  late final void Function(Pointer<ASS_Renderer>) _ass_renderer_done;
  void ass_renderer_done(Pointer<ASS_Renderer> priv) => _ass_renderer_done(priv);

  late final void Function(Pointer<ASS_Renderer>, int, int) _ass_set_frame_size;
  void ass_set_frame_size(Pointer<ASS_Renderer> priv, int w, int h) => _ass_set_frame_size(priv, w, h);

  late final void Function(Pointer<ASS_Renderer>, int, int, int, int) _ass_set_margins;
  void ass_set_margins(Pointer<ASS_Renderer> priv, int t, int b, int l, int r) => _ass_set_margins(priv, t, b, l, r);
  
  late final void Function(Pointer<ASS_Renderer>, int) _ass_set_use_margins;
  void ass_set_use_margins(Pointer<ASS_Renderer> priv, int use) => _ass_set_use_margins(priv, use);

  late final void Function(Pointer<ASS_Renderer>, double) _ass_set_pixel_aspect;
  /// Must be set explicitly once the frame is padded: the frame is no longer an
  /// isotropic scale of the video, so libass' default PAR guess would squash.
  void ass_set_pixel_aspect(Pointer<ASS_Renderer> priv, double par) => _ass_set_pixel_aspect(priv, par);

  late final void Function(Pointer<ASS_Renderer>, int, int) _ass_set_storage_size;
  void ass_set_storage_size(Pointer<ASS_Renderer> priv, int w, int h) => _ass_set_storage_size(priv, w, h);

  late final void Function(Pointer<ASS_Renderer>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>, int) _ass_set_fonts;
  void ass_set_fonts(Pointer<ASS_Renderer> priv, Pointer<Utf8> default_font, Pointer<Utf8> default_family, int dfp, Pointer<Utf8> config, int update) => _ass_set_fonts(priv, default_font, default_family, dfp, config, update);

  late final Pointer<ASS_Track> Function(Pointer<ASS_Library>) _ass_new_track;
  Pointer<ASS_Track> ass_new_track(Pointer<ASS_Library> priv) => _ass_new_track(priv);

  late final void Function(Pointer<ASS_Track>) _ass_free_track;
  void ass_free_track(Pointer<ASS_Track> track) => _ass_free_track(track);

  late final void Function(Pointer<ASS_Track>, Pointer<Utf8>, int) _ass_process_data;
  void ass_process_data(Pointer<ASS_Track> track, Pointer<Utf8> data, int size) => _ass_process_data(track, data, size);

  late final Pointer<ASS_Image> Function(Pointer<ASS_Renderer>, Pointer<ASS_Track>, int, Pointer<Int32>) _ass_render_frame;
  Pointer<ASS_Image> ass_render_frame(Pointer<ASS_Renderer> priv, Pointer<ASS_Track> track, int now, Pointer<Int32> detect_change) => _ass_render_frame(priv, track, now, detect_change);
}

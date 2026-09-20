<!--
Draft of an issue for https://github.com/media-kit/media-kit (docs/todo.md item 36).
Title: [Windows] Crash (0xC0000409) in VideoOutput::Resize: texture id published before its descriptor is inserted
Post everything below this comment as the body. Checked 2026-09-17: main's
video_output.cc was byte-identical to 1.3.1 and the diff applied cleanly.
-->

### Summary

On Windows, `VideoOutput::Resize` publishes a new texture id before that texture's descriptor is in `textures_`. If Flutter's raster thread paints the **old** texture in that window, its populate callback looks up the **member** `texture_id_` (already the new id) with `unordered_map::at`, which throws `std::out_of_range`. The exception cannot cross the engine's `noexcept` boundary, so the process aborts with `0xC0000409` (`FAST_FAIL_FATAL_APP_EXIT`).

Any resize can trigger it, i.e. whenever the decoded video size changes: switching quality, or an adaptive stream changing resolution by itself. In our app it happened in normal use while previews were playing.

### Environment

- media_kit_video **1.3.1**. `windows/video_output.cc` on `main` is byte-identical to 1.3.1, so the latest release has it too.
- media_kit 1.2.6, media_kit_libs_windows_video 1.0.11
- Flutter 3.44.9 (release build), Windows 10 22H2 (19045), hardware rendering (ANGLE / D3D11, NVIDIA)

### Stack (crashing thread, from the crash dump)

```
flutter_windows!abort+0x35
flutter_windows!terminate+0x29
flutter_windows!__C_specific_handler_noexcept+0x4a
ntdll!RtlpExecuteHandlerForException+0xf
ntdll!RtlDispatchException+0x244
ntdll!RtlRaiseException+0x1d7
KERNELBASE!RaiseException+0x69
VCRUNTIME140!_CxxThrowException+0x99
msvcp140!std::_Xout_of_range+0x22
media_kit_video_plugin!MediaKitVideoPluginCApiRegisterWithRegistrar+0xb2fe
media_kit_video_plugin!MediaKitVideoPluginCApiRegisterWithRegistrar+0xd887
flutter_windows!flutter::ExternalTextureD3d::PopulateTexture+0x24
flutter_windows!flutter::FlutterWindowsTextureRegistrar::PopulateTexture+0x84
...
flutter_windows!flutter::EmbedderExternalTextureGL::Paint+0x85
flutter_windows!flutter::TextureLayer::Paint+0xcc
flutter_windows!flutter::ContainerLayer::PaintChildren+0x62
...
```

The plugin DLL has no symbols. Disassembling a build of the same source at `+0xb2fe` shows the H/W `GpuSurfaceTexture` callback: lock `textures_mutex_` → test `texture_id_` → `surface_manager_->Read()` → hash `texture_id_` → lookup miss → throw `"invalid unordered_map<K, T> key"`. `+0xd887` is the `std::function` thunk that calls it.

### Root cause

In `VideoOutput::Resize` (H/W branch; the S/W branch has the same shape):

```cpp
texture_id_ =                                              // 1. new id published, no lock held
    registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
...
std::lock_guard<std::mutex> lock(textures_mutex_);
textures_.emplace(std::make_pair(texture_id_, std::move(texture)));   // 2. only now inserted
```

while the callback of every texture registered by this `VideoOutput` does:

```cpp
[&](auto, auto) {
  std::lock_guard<std::mutex> lock(textures_mutex_);
  if (texture_id_) {                        // the member, not this texture's own id
    surface_manager_->Read();
    return textures_.at(texture_id_).get(); // throws if between 1 and 2
  }
  ...
}
```

The old texture's unregistration is posted to the raster thread, so a frame that is already being rasterized still resolves the old texture and calls its callback. If that happens between steps 1 and 2, `at()` throws.

### Reproduction

The window is short, so it is rare in normal use. Widening it makes it deterministic. Add two sleeps to an unmodified 1.3.1:

- `std::this_thread::sleep_for(20ms)` at the top of the H/W callback, before the lock (keeps a frame in flight, so the old texture's unregistration stays queued behind it);
- `std::this_thread::sleep_for(50ms)` between `RegisterTexture(...)` and the `lock_guard` in `Resize`.

Then play a stream with several qualities and switch quality (each switch resizes the texture).

Result: the unmodified plugin aborted with `0xC0000409` on the **first** switch in **3 of 3** runs, with the stack above each time. With the patch below and the **same** sleeps, **3 of 3** runs completed all 7 switches, each getting a new texture and resuming playback.

### Proposed fix

Publish `texture_id_` only after the descriptor is inserted, under the lock, and look up with `find` so the callback cannot throw on the raster thread (a miss returns `nullptr`, i.e. no frame this time). The old texture keeps being served the *current* descriptor, as today. Handing it its own old descriptor would point it at the surface `SetSize` has already destroyed.

```diff
--- a/media_kit_video/windows/video_output.cc
+++ b/media_kit_video/windows/video_output.cc
@@ -292,6 +292,7 @@
             }
           }
         });
+    std::lock_guard<std::mutex> lock(textures_mutex_);
     texture_id_ = 0;
   }
   // H/W
@@ -313,21 +314,24 @@
             kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, [&](auto, auto) {
               std::lock_guard<std::mutex> lock(textures_mutex_);
               if (texture_id_) {
+                auto it = textures_.find(texture_id_);
+                if (it == textures_.end()) {
+                  return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
+                }
                 surface_manager_->Read();
-                return textures_.at(texture_id_).get();
+                return it->second.get();
               } else {
                 return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
               }
             }));
     // Register new texture.
-    texture_id_ =
+    const int64_t id =
         registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
-    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
-              << std::endl;
+    std::cout << "media_kit: VideoOutput: Create Texture: " << id << std::endl;
     std::lock_guard<std::mutex> lock(textures_mutex_);
-    textures_.emplace(std::make_pair(texture_id_, std::move(texture)));
-    texture_variants_.emplace(
-        std::make_pair(texture_id_, std::move(texture_variant)));
+    textures_.emplace(std::make_pair(id, std::move(texture)));
+    texture_variants_.emplace(std::make_pair(id, std::move(texture_variant)));
+    texture_id_ = id;
     // Notify public texture update callback.
     texture_update_callback_(texture_id_, required_width, required_height);
   }
@@ -343,21 +347,23 @@
         flutter::PixelBufferTexture([&](auto, auto) {
           std::lock_guard<std::mutex> lock(textures_mutex_);
           if (texture_id_) {
-            return pixel_buffer_textures_.at(texture_id_).get();
+            auto it = pixel_buffer_textures_.find(texture_id_);
+            return it == pixel_buffer_textures_.end()
+                       ? (FlutterDesktopPixelBuffer*)nullptr
+                       : it->second.get();
           } else {
             return (FlutterDesktopPixelBuffer*)nullptr;
           }
         }));
     // Register new texture.
-    texture_id_ =
+    const int64_t id =
         registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
-    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
-              << std::endl;
+    std::cout << "media_kit: VideoOutput: Create Texture: " << id << std::endl;
     std::lock_guard<std::mutex> lock(textures_mutex_);
     pixel_buffer_textures_.emplace(
-        std::make_pair(texture_id_, std::move(pixel_buffer_texture)));
-    texture_variants_.emplace(
-        std::make_pair(texture_id_, std::move(texture_variant)));
+        std::make_pair(id, std::move(pixel_buffer_texture)));
+    texture_variants_.emplace(std::make_pair(id, std::move(texture_variant)));
+    texture_id_ = id;
     // Notify public texture update callback.
     texture_update_callback_(texture_id_, required_width, required_height);
   }
```

The patch applies cleanly to `main`. Happy to open a PR with it.

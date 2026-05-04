// Facade for SoundService. Conditionally exports the audioplayers-backed
// impl on iOS / macOS / Android (sound_service_stub.dart) and the
// dart:js_interop / HTML5 Audio impl on web (sound_service_web.dart).
// Existing `import 'services/sound_service.dart'` callers don't need changes.
export 'sound_service_stub.dart'
    if (dart.library.js_interop) 'sound_service_web.dart';

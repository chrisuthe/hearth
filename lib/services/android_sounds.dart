import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/logger.dart';

/// Whether sounds go through the native Android player, as the Pi's do through
/// `gst-launch-1.0`.
bool get playsSoundsOnAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// The native Android player behind `com.hearth/sounds` (`SoundsChannel.kt`).
///
/// A sound that can't play is logged rather than thrown: the card or alarm
/// screen it accompanies must still appear.
class AndroidSounds {
  AndroidSounds._();

  static const _channel = MethodChannel('com.hearth/sounds');

  /// Plays one sine tone on the media volume, completing when it has finished.
  static Future<void> playTone(int hz, Duration duration, double volume) =>
      _invoke('playTone', {
        'hz': hz,
        'durationMs': duration.inMilliseconds,
        'volume': volume,
      });

  /// Loops a bundled tone on the alarm volume until [stopAlarmTone].
  static Future<void> startAlarmTone(String asset, double volume) =>
      _invoke('startAlarmTone', {'asset': asset, 'volume': volume});

  static Future<void> stopAlarmTone() => _invoke('stopAlarmTone');

  static Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (e) {
      Log.w('AndroidSounds', '$method failed: $e');
    }
  }
}

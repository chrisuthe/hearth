import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../utils/logger.dart';
import 'doorbell_support.dart';

/// Dart side of `com.hearth/doorbell` (`DoorbellChannel.kt`).
///
/// [begin] pauses the voice satellite's capture, mutes Sendspin and keeps the
/// screen on for an open call; [end] undoes all three. The satellite's mute
/// setting is never touched. Off Android every method returns at once.
class DoorbellPlatform {
  static const _tag = 'Doorbell';
  static const _channel = MethodChannel('com.hearth/doorbell');

  /// Throws if the hold could not be taken, so the call can fail cleanly.
  Future<void> begin() async {
    if (!doorbellCallSupported) return;
    await _channel.invokeMethod<void>('begin');
  }

  /// Never throws: it runs on every way out of a call.
  Future<void> end() async {
    if (!doorbellCallSupported) return;
    try {
      await _channel.invokeMethod<void>('end');
    } catch (e) {
      Log.e(_tag, 'end failed: $e');
    }
  }

  /// Turns the screen on and brings Hearth forward for a ring. Native posts a
  /// system notification with [title] when Hearth cannot come forward.
  Future<void> summon(String title) async {
    if (!doorbellCallSupported) return;
    try {
      await _channel.invokeMethod<void>('summon', {'title': title});
    } catch (e) {
      Log.w(_tag, 'summon failed: $e');
    }
  }
}

final doorbellPlatformProvider =
    Provider<DoorbellPlatform>((ref) => DoorbellPlatform());

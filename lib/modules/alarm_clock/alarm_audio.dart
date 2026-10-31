import 'dart:async';
import 'dart:io';
import '../../services/android_sounds.dart';
import '../../utils/logger.dart';

/// Plays bundled alarm tones via GStreamer on Linux and the native player on
/// Android, or logs on other platforms.
class AlarmAudioPlayer {
  AlarmAudioPlayer({
    bool? gstreamer,
    Future<Process> Function(String executable, List<String> arguments)?
        startProcess,
    Duration retryDelay = const Duration(seconds: 2),
  })  : _gstreamer = gstreamer ?? Platform.isLinux,
        _startProcess = startProcess ?? Process.start,
        _retryDelay = retryDelay;

  final bool _gstreamer;
  final Future<Process> Function(String, List<String>) _startProcess;
  final Duration _retryDelay;

  Process? _process;

  /// Bumped by every [play] and [stop], so a loop from an earlier ring ends
  /// rather than playing alongside the next one.
  int _generation = 0;

  /// Available builtin tone IDs. Each must have a corresponding OGG file
  /// in `assets/alarm_tones/<id>.ogg`. Adding a new tone = drop the OGG +
  /// add a row here + bump the assets list in pubspec.yaml.
  static const builtinTones = {
    'gentle_morning': 'Gentle Morning',
    'birds': 'Birdsong',
    'classic': 'Classic',
    'bright': 'Bright Day',
  };

  static const _fallbackTone = 'gentle_morning';

  /// Start playing a looping alarm tone. A tone this kiosk doesn't have plays
  /// the default, because a silent alarm is worse than the wrong sound.
  Future<void> play(String toneId, {double volume = 0.7}) async {
    final tone = builtinTones.containsKey(toneId) ? toneId : _fallbackTone;
    if (playsSoundsOnAndroid) {
      await AndroidSounds.startAlarmTone(
          'assets/alarm_tones/$tone.ogg', volume);
    } else if (_gstreamer) {
      stop();
      // The tone files are bundled in the flutter assets directory.
      unawaited(_playLoop(tone, volume, _generation));
    } else {
      Log.i('AlarmAudio', 'Would play tone: $tone at volume $volume');
    }
  }

  Future<void> _playLoop(String toneId, double volume, int generation) async {
    while (generation == _generation) {
      try {
        // Use gst-launch-1.0 for OGG playback with volume control.
        // flutter-pi bundles assets directly under /opt/hearth/bundle/assets/
        // (no `flutter_assets/` prefix that vanilla Flutter desktop uses).
        final process = await _startProcess('gst-launch-1.0', [
          'filesrc',
          'location=/opt/hearth/bundle/assets/alarm_tones/$toneId.ogg',
          '!', 'oggdemux', '!', 'vorbisdec',
          '!', 'volume', 'volume=${volume.toStringAsFixed(2)}',
          '!', 'autoaudiosink',
        ]);
        if (generation != _generation) {
          process.kill();
          break;
        }
        _process = process;
        final exitCode = await process.exitCode;
        if (generation != _generation) break;
        if (exitCode == 0) continue;
        Log.e('AlarmAudio', 'Playback of $toneId exited with $exitCode');
      } catch (e) {
        Log.e('AlarmAudio', 'Playback failed: $e');
      }
      // Audio may just not be ready yet, say at boot. Keep trying, since the
      // alarm's own limit ends this and a silent alarm is the worse failure.
      await Future<void>.delayed(_retryDelay);
    }
  }

  /// Stop playback.
  void stop() {
    _generation++;
    _process?.kill();
    _process = null;
    if (playsSoundsOnAndroid) unawaited(AndroidSounds.stopAlarmTone());
  }
}

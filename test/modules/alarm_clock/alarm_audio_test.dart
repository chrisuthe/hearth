import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/modules/alarm_clock/alarm_audio.dart';

class _FakeProcess implements Process {
  final _exit = Completer<int>();
  int kills = 0;

  void finish(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    finish(-15);
    return true;
  }

  @override
  int get pid => 1;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();
}

void main() {
  group('GStreamer playback', () {
    late List<List<String>> starts;
    late List<_FakeProcess> processes;
    Object? startError;
    late AlarmAudioPlayer player;

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 30));

    setUp(() {
      // Flutter's test mode otherwise reports Android.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      starts = [];
      processes = [];
      startError = null;
      player = AlarmAudioPlayer(
        gstreamer: true,
        retryDelay: const Duration(milliseconds: 5),
        startProcess: (executable, args) async {
          starts.add(args);
          if (startError != null) throw startError!;
          final process = _FakeProcess();
          processes.add(process);
          return process;
        },
      );
    });

    tearDown(() => player.stop());

    test('plays the tone at its volume from the bundle', () async {
      await player.play('birds', volume: 0.4);
      await settle();
      expect(starts.single.join(' '),
          contains('location=/opt/hearth/bundle/assets/alarm_tones/birds.ogg'));
      expect(starts.single, contains('volume=0.40'));
    });

    test('loops when the tone finishes', () async {
      await player.play('birds');
      await settle();
      processes.single.finish(0);
      await settle();
      expect(starts, hasLength(2));
    });

    test('retries after a failed start rather than going silent', () async {
      startError = const OSError('audio not ready');
      await player.play('birds');
      await settle();
      expect(starts.length, greaterThanOrEqualTo(2));

      startError = null;
      await settle();
      expect(processes, isNotEmpty);
    });

    test('retries after gstreamer exits with an error', () async {
      await player.play('birds');
      await settle();
      processes.single.finish(1);
      await settle();
      expect(starts.length, greaterThanOrEqualTo(2));
    });

    test('waits between retries rather than spinning', () async {
      final slow = AlarmAudioPlayer(
        gstreamer: true,
        retryDelay: const Duration(seconds: 30),
        startProcess: (executable, args) async {
          starts.add(args);
          throw const OSError('audio not ready');
        },
      );
      addTearDown(slow.stop);
      await slow.play('birds');
      await settle();
      expect(starts, hasLength(1));
    });

    test('stop kills the tone and does not loop', () async {
      await player.play('birds');
      await settle();
      player.stop();
      await settle();
      expect(processes.single.kills, 1);
      expect(starts, hasLength(1));
    });

    test('stop during a retry wait ends the loop', () async {
      startError = const OSError('audio not ready');
      await player.play('birds');
      await settle();
      player.stop();
      final count = starts.length;
      await settle();
      expect(starts, hasLength(count));
    });

    test('a new tone replaces the old one', () async {
      await player.play('birds');
      await settle();
      await player.play('classic');
      await settle();
      expect(processes.first.kills, 1);
      expect(starts, hasLength(2));
      expect(starts.last.join(' '), contains('classic.ogg'));
    });
  });
}

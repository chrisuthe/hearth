import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/services/audio_coordinator.dart';
import 'package:hearth/services/voice_satellite_bridge.dart';

const _duckLevel = AudioCoordinator.duckFactor;

/// What a live, connected service reports in [state].
VoiceSatelliteStatus _live(String state, {VoiceSatelliteHealth? health}) =>
    VoiceSatelliteStatus(
      running: true,
      state: state,
      connected: true,
      health: health,
    );

void main() {
  late ValueNotifier<double> playback;
  late StreamController<bool> duck;
  late StreamController<VoiceSatelliteStatus> status;
  late AudioCoordinator coordinator;

  setUp(() {
    playback = ValueNotifier<double>(1.0);
    duck = StreamController<bool>(sync: true);
    status = StreamController<VoiceSatelliteStatus>(sync: true);
    coordinator = AudioCoordinator(playback)
      ..start(duck: duck.stream, status: status.stream);
    status.add(_live('idle'));
  });

  tearDown(() {
    coordinator.dispose();
    duck.close();
    status.close();
  });

  // One test per row of the "Echo and ducking" table, in the order a
  // conversation runs through them.
  group('the ducking table', () {
    test('idle: playback normal', () {
      expect(playback.value, 1.0);
      expect(coordinator.ducked, false);
    });

    test('wake word fired, wake sound playing: ducked while still idle', () {
      duck.add(true);
      expect(playback.value, _duckLevel);
      expect(coordinator.ducked, true);
    });

    test('listening: ducked', () {
      duck.add(true);
      status.add(_live('listening'));
      expect(playback.value, _duckLevel);
    });

    test('processing: ducked', () {
      duck.add(true);
      status.add(_live('processing'));
      expect(playback.value, _duckLevel);
    });

    test('responding: ducked', () {
      duck.add(true);
      status.add(_live('responding'));
      expect(playback.value, _duckLevel);
    });

    test('timer ringing: ducked while the state is idle', () {
      duck.add(true);
      status.add(_live('idle'));
      expect(playback.value, _duckLevel);
    });

    test('back to idle: restored exactly', () {
      duck.add(true);
      status.add(_live('responding'));
      // Ava reports idle before it calls unDuck; the duck holds until then.
      status.add(_live('idle'));
      expect(playback.value, _duckLevel);
      duck.add(false);
      expect(playback.value, 1.0);
    });
  });

  test('a pipeline state holds the duck if the duck event was missed', () {
    status.add(_live('listening'));
    expect(playback.value, _duckLevel);
    status.add(_live('idle'));
    expect(playback.value, 1.0);
  });

  test('a repeated duck does not touch playback again', () {
    final changes = <double>[];
    playback.addListener(() => changes.add(playback.value));
    duck.add(true);
    duck.add(true);
    status.add(_live('listening'));
    status.add(_live('processing'));
    expect(changes, [_duckLevel]);
  });

  group('released without unDuck', () {
    test('when the service stops', () {
      duck.add(true);
      status.add(_live('listening'));
      status.add(const VoiceSatelliteStatus(running: false));
      expect(playback.value, 1.0);
    });

    test('when the service crashes and reports health', () {
      duck.add(true);
      status.add(
        _live(
          'idle',
          health: VoiceSatelliteHealth('micOpenFailed', 'gone', DateTime(0)),
        ),
      );
      expect(playback.value, 1.0);
    });

    test('when Home Assistant drops the connection', () {
      duck.add(true);
      status.add(const VoiceSatelliteStatus(running: true, state: 'idle'));
      expect(playback.value, 1.0);
    });

    test('when the coordinator is disposed', () {
      duck.add(true);
      coordinator.dispose();
      expect(playback.value, 1.0);
    });

    test('and a stale health report does not block the next duck', () {
      final health = VoiceSatelliteHealth('modelLoadFailed', 'x', DateTime(0));
      status.add(_live('idle', health: health));
      // The bridge keeps the last health on every later status.
      duck.add(true);
      status.add(_live('idle', health: health));
      expect(playback.value, _duckLevel);
    });
  });

  test('a stopped service ignores a late duck event', () {
    status.add(const VoiceSatelliteStatus(running: false));
    duck.add(true);
    expect(playback.value, 1.0);
  });
  group('doorbell call', () {
    test('call mutes playback', () {
      coordinator.setCallActive(true);
      expect(playback.value, 0.0);
    });

    test('a voice duck during a call stays at 0', () {
      coordinator.setCallActive(true);
      duck.add(true);
      status.add(_live('listening'));
      expect(playback.value, 0.0);
    });

    test('ending the call restores normal playback', () {
      coordinator.setCallActive(true);
      coordinator.setCallActive(false);
      expect(playback.value, 1.0);
    });

    test('ending the call while voice is active ducks', () {
      coordinator.setCallActive(true);
      duck.add(true);
      coordinator.setCallActive(false);
      expect(playback.value, _duckLevel);
    });

    test('dispose restores normal playback', () {
      coordinator.setCallActive(true);
      coordinator.dispose();
      expect(playback.value, 1.0);
    });
  });
}

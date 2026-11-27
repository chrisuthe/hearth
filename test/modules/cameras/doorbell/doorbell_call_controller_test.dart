import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/models/hearth_notification.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_call_controller.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_call_session.dart';
import 'package:hearth/modules/cameras/doorbell/rtc_client.dart';

import 'doorbell_fakes.dart';

HearthNotification _ring({
  String camera = 'FrontDoorbell',
  String tag = 'front_doorbell',
  String title = 'Doorbell rang at Front Door',
  int? timeout = 180,
}) =>
    HearthNotification.fromIngest({
      'tag': tag,
      'title': title,
      'camera': camera,
      'timeout': ?timeout,
      'ring': true,
    })!;

/// One controller over real sessions, with fake media and platform.
class _Rig {
  _Rig(FakeAsync async) : clock = async.getClock(DateTime(2026, 11, 27, 18)) {
    controller = DoorbellCallController(
      createSession: (camera, {onLost, onTalkLost}) {
        final session = DoorbellCallSession(
          signaling: Uri.parse('ws://10.0.2.2:1984/api/ws?src=$camera'),
          rtc: rtc,
          platform: platform,
          muteHearthPlayback: (_) {},
          onLost: onLost,
          onTalkLost: onTalkLost,
        );
        sessions.add(session);
        return session;
      },
      platform: platform,
      isForeground: () => foreground,
      closeFeed: () => feedCloses++,
      fallbackToFeed: fallbacks.add,
      now: () => clock.now() as DateTime,
    );
  }

  // fake_async's Clock; its type is in package:clock, a transitive dep.
  final dynamic clock;
  final log = CallLog();
  late final rtc = FakeRtcClient(log);
  late final platform = FakeDoorbellPlatform(log);
  late final DoorbellCallController controller;
  final sessions = <DoorbellCallSession>[];
  final fallbacks = <String>[];
  var feedCloses = 0;
  var foreground = true;

  DoorbellCall? get call => controller.state;

  /// Every session that is no longer the open one was released exactly once.
  void expectReleased() {
    final open = call == null ? 0 : 1;
    expect(platform.ends, sessions.length - open);
  }
}

void main() {
  test('ring in foreground opens and connects', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();

      expect(rig.feedCloses, 1);
      expect(rig.call?.camera, 'FrontDoorbell');
      expect(rig.call?.connected, isTrue);
      expect(rig.rtc.talks, 0);
    });
  });

  test('connect failure falls back to the RTSP feed', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.rtc.receiveError = const RtcUnavailable('connect timed out');
      rig.controller.ring(_ring());
      async.flushMicrotasks();

      expect(rig.call, isNull);
      expect(rig.fallbacks, ['FrontDoorbell']);
      rig.expectReleased();
    });
  });

  test('receive lost falls back the same way', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.rtc.receiveLinks.single.loseIt();
      async.flushMicrotasks();

      expect(rig.call, isNull);
      expect(rig.fallbacks, ['FrontDoorbell']);
      rig.expectReleased();
    });
  });

  test('quiet view closes at the payload timeout', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.elapse(const Duration(seconds: 179));
      expect(rig.call, isNotNull);
      async.elapse(const Duration(seconds: 2));
      expect(rig.call, isNull);
      rig.expectReleased();
    });
  });

  test('quiet view without a timeout closes at 3 min', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring(timeout: null));
      async.elapse(const Duration(minutes: 3) - const Duration(seconds: 1));
      expect(rig.call, isNotNull);
      async.elapse(const Duration(seconds: 2));
      expect(rig.call, isNull);
    });
  });

  test('talk extends the life to 5 min from opening', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.elapse(const Duration(seconds: 170));
      rig.controller.setTalk(true);
      async.flushMicrotasks();
      expect(rig.call?.talkOn, isTrue);

      async.elapse(const Duration(seconds: 11)); // 181 s
      expect(rig.call, isNotNull);
      async.elapse(const Duration(seconds: 118)); // 299 s
      expect(rig.call, isNotNull);
      async.elapse(const Duration(seconds: 2)); // 301 s
      expect(rig.call, isNull);
      expect(rig.rtc.talkLinks.single.closes, 1);
      rig.expectReleased();
    });
  });

  test('clear closes a quiet view', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.controller.clear('front_doorbell');
      async.flushMicrotasks();
      expect(rig.call, isNull);
      rig.expectReleased();
    });
  });

  test('clear leaves a view where talk was used', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.controller.setTalk(true);
      async.flushMicrotasks();
      rig.controller.setTalk(false);
      async.flushMicrotasks();
      rig.controller.clear('front_doorbell');
      expect(rig.call, isNotNull);
    });
  });

  test('second ring for another camera replaces a quiet view', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.controller.ring(_ring(
          camera: 'GarageDoorbell',
          tag: 'garage_doorbell',
          title: 'Doorbell rang at Garage'));
      async.flushMicrotasks();

      expect(rig.call?.camera, 'GarageDoorbell');
      expect(rig.sessions, hasLength(2));
      rig.expectReleased();
    });
  });

  test('second ring for another camera is ignored while talking', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.controller.setTalk(true);
      async.flushMicrotasks();
      rig.controller.ring(_ring(camera: 'GarageDoorbell', tag: 'garage'));
      async.flushMicrotasks();

      expect(rig.call?.camera, 'FrontDoorbell');
      expect(rig.sessions, hasLength(1));
    });
  });

  test('repeat ring for the same camera keeps the view and its deadline', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.elapse(const Duration(seconds: 100));
      final first = rig.call;
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      expect(rig.call?.session, same(first?.session));

      async.elapse(const Duration(seconds: 81)); // 181 s from opening
      expect(rig.call, isNull);
    });
  });

  test('ring after hang up opens a new view', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.controller.hangUp();
      async.flushMicrotasks();
      expect(rig.call, isNull);

      rig.controller.ring(_ring());
      async.flushMicrotasks();
      expect(rig.call?.connected, isTrue);
      expect(rig.sessions, hasLength(2));
      rig.expectReleased();
    });
  });

  test('going to the background with talk on closes the view', () {
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused]) {
      fakeAsync((async) {
        final rig = _Rig(async);
        rig.controller.ring(_ring());
        async.flushMicrotasks();
        rig.controller.setTalk(true);
        async.flushMicrotasks();

        rig.controller.onLifecycle(state);
        async.flushMicrotasks();

        expect(rig.call, isNull, reason: '$state');
        expect(rig.rtc.talkLinks.single.closes, 1);
        rig.expectReleased();
      });
    }
  });

  test('inactive keeps the view', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.controller.onLifecycle(AppLifecycleState.inactive);
      expect(rig.call, isNotNull);
    });
  });

  test('ring in the background summons and opens on resume', () {
    fakeAsync((async) {
      final rig = _Rig(async)..foreground = false;
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      expect(rig.platform.summons, ['Doorbell rang at Front Door']);
      expect(rig.sessions, isEmpty);

      async.elapse(const Duration(seconds: 10));
      rig.foreground = true;
      rig.controller.onLifecycle(AppLifecycleState.resumed);
      async.flushMicrotasks();
      expect(rig.call?.connected, isTrue);
    });
  });

  test('a summoned ring expires after 15 s', () {
    fakeAsync((async) {
      final rig = _Rig(async)..foreground = false;
      rig.controller.ring(_ring());
      async.elapse(const Duration(seconds: 16));
      rig.foreground = true;
      rig.controller.onLifecycle(AppLifecycleState.resumed);
      async.flushMicrotasks();
      expect(rig.call, isNull);
      expect(rig.sessions, isEmpty);
    });
  });

  test('a ring that cannot open its view never opens the mic', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.elapse(const Duration(seconds: 30));
      expect(rig.rtc.talks, 0);
    });
  });

  test('talk denied shows the permission notice', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.rtc.talkError = const MicDenied();
      rig.controller.setTalk(true);
      async.flushMicrotasks();

      expect(rig.call?.talkOn, isFalse);
      expect(rig.call?.notice, kMicPermissionNeeded);
      async.elapse(kDoorbellNoticeDuration + const Duration(seconds: 1));
      expect(rig.call?.notice, isNull);
    });
  });

  test('talk failed shows Talk unavailable and keeps listening', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.rtc.talkError = const RtcUnavailable('no two-way audio');
      rig.controller.setTalk(true);
      async.flushMicrotasks();

      expect(rig.call?.talkOn, isFalse);
      expect(rig.call?.talkUsed, isFalse);
      expect(rig.call?.notice, kTalkUnavailable);
      expect(rig.call?.connected, isTrue);
    });
  });

  test('talk lost turns the toggle off with Talk unavailable', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.controller.setTalk(true);
      async.flushMicrotasks();
      rig.rtc.talkLinks.single.loseIt();
      async.flushMicrotasks();

      expect(rig.call?.talkOn, isFalse);
      expect(rig.call?.notice, kTalkUnavailable);
    });
  });

  test('dispose releases an open call', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(_ring());
      async.flushMicrotasks();
      rig.controller.dispose();
      async.flushMicrotasks();
      expect(rig.platform.ends, 1);
    });
  });

  test('a ring without a camera is ignored', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.controller.ring(HearthNotification.fromIngest(
          {'tag': 't', 'title': 'x', 'ring': true})!);
      async.flushMicrotasks();
      expect(rig.call, isNull);
      expect(rig.sessions, isEmpty);
    });
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_call_session.dart';
import 'package:hearth/modules/cameras/doorbell/rtc_client.dart';

import 'doorbell_fakes.dart';

void main() {
  late CallLog log;
  late FakeRtcClient rtc;
  late FakeDoorbellPlatform platform;
  late List<bool> mutes;
  late int lost;
  late int talkLost;

  DoorbellCallSession build() => DoorbellCallSession(
        signaling: Uri.parse('ws://10.0.2.2:1984/api/ws?src=FrontDoorbell'),
        rtc: rtc,
        platform: platform,
        muteHearthPlayback: (active) {
          mutes.add(active);
          log.add('mute $active');
        },
        onLost: () => lost++,
        onTalkLost: () => talkLost++,
      );

  setUp(() {
    log = CallLog();
    rtc = FakeRtcClient(log);
    platform = FakeDoorbellPlatform(log);
    mutes = [];
    lost = 0;
    talkLost = 0;
  });

  test('start holds the platform before connecting', () async {
    final session = build();
    expect(await session.start(), isTrue);
    expect(log.entries, ['begin', 'mute true', 'receive']);
    expect(rtc.talks, 0);
    expect(session.media.value, same(rtc.receiveLinks.single));
  });

  test('start failure returns false and dispose still releases', () async {
    rtc.receiveError = const RtcUnavailable('connect timed out');
    final session = build();
    expect(await session.start(), isFalse);
    await session.dispose();
    expect(platform.ends, 1);
    expect(mutes.where((m) => !m), hasLength(1));
  });

  test('begin throwing returns false and dispose still releases', () async {
    platform.beginThrows = true;
    final session = build();
    expect(await session.start(), isFalse);
    expect(rtc.receives, 0);
    await session.dispose();
    expect(platform.ends, 1);
    expect(mutes.last, isFalse);
  });

  test('talk on then off', () async {
    final session = build();
    await session.start();

    expect(await session.setTalk(true), TalkResult.on);
    expect(session.talking.value, isTrue);
    expect(await session.setTalk(false), TalkResult.off);
    expect(session.talking.value, isFalse);

    expect(rtc.talks, 1);
    expect(rtc.talkLinks.single.closes, 1);
    expect(rtc.receiveLinks.single.closes, 0);
  });

  test('double tap opens one send connection', () async {
    final session = build();
    await session.start();
    rtc.pendingTalk = Completer<FakeLink>();

    final first = session.setTalk(true);
    final second = session.setTalk(true);
    rtc.pendingTalk!.complete(FakeLink(log, 'talk'));

    expect(await first, TalkResult.on);
    expect(await second, TalkResult.on);
    expect(rtc.talks, 1);
  });

  test('talk failure turns the toggle back off', () async {
    final session = build();
    await session.start();

    rtc.talkError = const RtcUnavailable('no two-way audio');
    expect(await session.setTalk(true), TalkResult.failed);
    expect(session.talking.value, isFalse);

    rtc.talkError = const MicDenied();
    expect(await session.setTalk(true), TalkResult.micDenied);
    expect(session.talking.value, isFalse);
  });

  test('talk lost after connect', () async {
    final session = build();
    await session.start();
    await session.setTalk(true);

    rtc.talkLinks.single.loseIt();
    await pumpEventQueue();

    expect(session.talking.value, isFalse);
    expect(talkLost, 1);
    expect(rtc.talkLinks.single.closes, 1);
  });

  test('receive lost after connect fires onLost', () async {
    final session = build();
    await session.start();
    rtc.receiveLinks.single.loseIt();
    await pumpEventQueue();
    expect(lost, 1);
  });

  test('dispose while talking closes talk, then receive, then ends',
      () async {
    final session = build();
    await session.start();
    await session.setTalk(true);
    rtc.talkLinks.single.closeThrows = true;

    await session.dispose();
    await session.dispose();

    final tail = log.entries.skipWhile((e) => e != 'close talk').toList();
    expect(tail, ['close talk', 'close receive', 'end', 'mute false']);
    expect(platform.ends, 1);
    expect(session.talking.value, isFalse);
  });

  test('dispose during a pending receive closes the late link', () async {
    rtc.pendingReceive = Completer<FakeLink>();
    final session = build();
    final started = session.start();
    await pumpEventQueue();
    expect(rtc.receives, 1);

    await session.dispose();
    final late = FakeLink(log, 'receive');
    rtc.pendingReceive!.complete(late);

    expect(await started, isFalse);
    expect(late.closes, 1);
    expect(platform.ends, 1);
    expect(session.media.value, isNull);
  });

  test('dispose during begin never leaves playback muted', () async {
    platform.pendingBegin = Completer<void>();
    final session = build();
    final started = session.start();
    await session.dispose();
    platform.pendingBegin!.complete();

    expect(await started, isFalse);
    expect(mutes.last, isFalse);
    expect(rtc.receives, 0);
  });

  test('hang up while talk is connecting aborts it at once', () async {
    final session = build();
    await session.start();
    rtc.pendingTalk = Completer<FakeLink>();
    final talking = session.setTalk(true);
    await pumpEventQueue();

    var aborted = false;
    unawaited(rtc.lastAbort!.then((_) => aborted = true));
    await session.dispose();
    await pumpEventQueue();
    expect(aborted, isTrue);

    rtc.pendingTalk!.completeError(const RtcUnavailable('aborted'));
    expect(await talking, TalkResult.failed);
    expect(session.talking.value, isFalse);
  });

  test('setTalk after dispose never opens the mic', () async {
    final session = build();
    await session.start();
    await session.dispose();
    expect(await session.setTalk(true), TalkResult.off);
    expect(rtc.talks, 0);
  });
}

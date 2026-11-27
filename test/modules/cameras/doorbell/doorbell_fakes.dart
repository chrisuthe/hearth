import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hearth/models/hearth_notification.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_call_controller.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_call_session.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_platform.dart';
import 'package:hearth/modules/cameras/doorbell/rtc_client.dart';

/// Records every call in order, shared by the fakes below so tests can
/// assert on ordering across them.
class CallLog {
  final entries = <String>[];
  void add(String entry) => entries.add(entry);
}

class FakeDoorbellPlatform implements DoorbellPlatform {
  FakeDoorbellPlatform(this.log);
  final CallLog log;
  bool beginThrows = false;
  Completer<void>? pendingBegin;
  int ends = 0;
  final summons = <String>[];

  @override
  Future<void> begin() async {
    log.add('begin');
    if (pendingBegin != null) await pendingBegin!.future;
    if (beginThrows) throw StateError('begin refused');
  }

  @override
  Future<void> end() async {
    ends++;
    log.add('end');
  }

  @override
  Future<void> summon(String title) async {
    summons.add(title);
    log.add('summon');
  }
}

class FakeLink implements RtcReceiveLink, RtcTalkLink {
  FakeLink(this.log, this.name);
  final CallLog log;
  final String name;
  final _lost = StreamController<void>.broadcast();
  int closes = 0;
  bool closeThrows = false;

  void loseIt() => _lost.add(null);

  @override
  Widget buildView() => const SizedBox(key: Key('fake-video'));

  @override
  Stream<void> get lost => _lost.stream;

  @override
  Future<void> close() async {
    closes++;
    log.add('close $name');
    if (closeThrows) throw StateError('close failed');
  }
}

/// Each call returns a pending future the test completes, or completes at
/// once with [receiveError]/[talkError] or a fresh link.
class FakeRtcClient implements RtcClient {
  FakeRtcClient(this.log);
  final CallLog log;

  Object? receiveError;
  Object? talkError;

  /// When set, receive/talk wait for the test to complete these.
  Completer<FakeLink>? pendingReceive;
  Completer<FakeLink>? pendingTalk;

  int receives = 0;
  int talks = 0;
  final receiveLinks = <FakeLink>[];
  final talkLinks = <FakeLink>[];

  @override
  Future<RtcReceiveLink> receive(Uri signaling,
      {required Duration timeout}) async {
    receives++;
    log.add('receive');
    if (pendingReceive != null) return pendingReceive!.future;
    if (receiveError != null) throw receiveError!;
    final link = FakeLink(log, 'receive');
    receiveLinks.add(link);
    return link;
  }

  @override
  Future<RtcTalkLink> talk(Uri signaling, {required Duration timeout}) async {
    talks++;
    log.add('talk');
    if (pendingTalk != null) return pendingTalk!.future;
    if (talkError != null) throw talkError!;
    final link = FakeLink(log, 'talk');
    talkLinks.add(link);
    return link;
  }
}

/// A controller over real sessions with fake media and platform, for widget
/// tests. [foreground] is always true.
class FakeDoorbellRig {
  FakeDoorbellRig() {
    controller = DoorbellCallController(
      createSession: (camera, {onLost, onTalkLost}) => DoorbellCallSession(
        signaling: Uri.parse('ws://10.0.2.2:1984/api/ws?src=$camera'),
        rtc: rtc,
        platform: platform,
        muteHearthPlayback: (_) {},
        onLost: onLost,
        onTalkLost: onTalkLost,
      ),
      platform: platform,
      isForeground: () => true,
      closeFeed: () {},
      fallbackToFeed: (_) {},
    );
  }

  final log = CallLog();
  late final rtc = FakeRtcClient(log);
  late final platform = FakeDoorbellPlatform(log);
  late final DoorbellCallController controller;

  /// Opens a call for [camera] as a ring would.
  void ring({String camera = 'FrontDoorbell'}) => controller.ring(
        HearthNotification.fromIngest({
          'tag': 'front_doorbell',
          'title': 'Doorbell rang at Front Door',
          'camera': camera,
          'timeout': 180,
          'ring': true,
        })!,
      );
}

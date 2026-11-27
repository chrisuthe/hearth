import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/app/idle_controller.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_call_controller.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_call_overlay.dart';
import 'package:hearth/modules/cameras/doorbell/rtc_client.dart';

import '../../../portrait/portrait_harness.dart';
import 'doorbell_fakes.dart';

void main() {
  late FakeDoorbellRig rig;
  late int wakes;
  final containers = <ProviderContainer>[];

  /// Ends the call and lets every timer it armed run out, so none is
  /// pending when the test ends.
  Future<void> finish(WidgetTester tester) async {
    rig.controller.hangUp();
    await tester.pumpWidget(const SizedBox.shrink());
    for (final c in containers) {
      c.dispose();
    }
    containers.clear();
    await tester.pump(const Duration(minutes: 6));
  }

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      doorbellCallProvider.overrideWith((ref) => rig.controller),
    ]);
    containers.add(container);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: hostScreen(Stack(children: [
        DoorbellCallOverlay(onWake: () => wakes++),
      ])),
    ));
    return container;
  }

  setUp(() {
    rig = FakeDoorbellRig();
    wakes = 0;
  });

  testWidgets('renders nothing without a call', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('doorbell-talk')), findsNothing);
    expect(wakes, 0);
    await finish(tester);
  });

  testWidgets('shows the camera and Connecting until connected',
      (tester) async {
    rig.rtc.pendingReceive = Completer<FakeLink>();
    await pump(tester);
    rig.ring();
    await tester.pump();

    expect(find.text('FrontDoorbell'), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(wakes, greaterThan(0));

    rig.rtc.pendingReceive!.complete(FakeLink(rig.log, 'receive'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Connecting…'), findsNothing);
    expect(find.byKey(const Key('fake-video')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Talk turns the mic on and reads Talking', (tester) async {
    await pump(tester);
    rig.ring();
    await tester.pump();
    await tester.pump();

    expect(find.text('Talk'), findsOneWidget);
    await tester.tap(find.byKey(const Key('doorbell-talk')));
    await tester.pump();
    await tester.pump();

    expect(rig.rtc.talks, 1);
    expect(find.text('Talking'), findsOneWidget);

    await tester.tap(find.byKey(const Key('doorbell-talk')));
    await tester.pump();
    await tester.pump();
    expect(rig.rtc.talkLinks.single.closes, 1);
    expect(find.text('Talk'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Hang up closes the call and releases the hold',
      (tester) async {
    final container = await pump(tester);
    rig.ring();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('doorbell-hangup')));
    await tester.pump();
    await tester.pump();

    expect(container.read(doorbellCallProvider), isNull);
    expect(rig.platform.ends, 1);
    expect(find.byKey(const Key('doorbell-talk')), findsNothing);
    await finish(tester);
  });

  testWidgets('tapping the video does not close the call', (tester) async {
    final container = await pump(tester);
    rig.ring();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('fake-video')));
    await tester.pump();
    expect(container.read(doorbellCallProvider), isNotNull);
    await finish(tester);
  });

  testWidgets('a notice shows in the view', (tester) async {
    await pump(tester);
    rig.ring();
    await tester.pump();
    await tester.pump();
    rig.rtc.talkError = const MicDenied();

    await tester.tap(find.byKey(const Key('doorbell-talk')));
    await tester.pump();
    await tester.pump();
    expect(find.text(kMicPermissionNeeded), findsOneWidget);
    await tester.pump(kDoorbellNoticeDuration + const Duration(seconds: 1));
    await finish(tester);
  });

  testWidgets('idle is suppressed while the view is open', (tester) async {
    final container = await pump(tester);
    rig.ring();
    await tester.pump();
    await tester.pump();
    expect(container.read(idleControllerProvider).isSuppressed, isTrue);

    rig.controller.hangUp();
    await tester.pump();
    await tester.pump();
    expect(container.read(idleControllerProvider).isSuppressed, isFalse);
    await finish(tester);
  });
}

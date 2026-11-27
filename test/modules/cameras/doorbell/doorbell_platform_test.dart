import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_platform.dart';
import 'package:hearth/modules/cameras/doorbell/doorbell_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.hearth/doorbell');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  Object? throwing;

  setUp(() {
    calls = [];
    throwing = null;
    debugDoorbellCallSupportedOverride = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (throwing != null) throw throwing!;
      return null;
    });
  });

  tearDown(() {
    debugDoorbellCallSupportedOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('begin, end and summon reach the channel', () async {
    final platform = DoorbellPlatform();
    await platform.begin();
    await platform.end();
    await platform.summon('Doorbell rang at Front Door');

    expect(calls.map((c) => c.method), ['begin', 'end', 'summon']);
    expect(calls.last.arguments, {'title': 'Doorbell rang at Front Door'});
  });

  test('end and summon swallow channel errors', () async {
    throwing = PlatformException(code: 'boom');
    final platform = DoorbellPlatform();
    await platform.end();
    await platform.summon('x');
    expect(calls, hasLength(2));
  });

  test('begin rethrows channel errors', () async {
    throwing = PlatformException(code: 'boom');
    await expectLater(DoorbellPlatform().begin(), throwsA(isA<PlatformException>()));
  });

  test('nothing reaches the channel off Android', () async {
    debugDoorbellCallSupportedOverride = false;
    final platform = DoorbellPlatform();
    await platform.begin();
    await platform.end();
    await platform.summon('x');
    expect(calls, isEmpty);
  });
}

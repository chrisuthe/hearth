import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/models/hearth_notification.dart';
import 'package:hearth/services/notification_service.dart';

void main() {
  // A notification factory with sensible defaults for tests.
  HearthNotification make({
    String id = 'n1',
    NotificationSource source = NotificationSource.ha,
    NotificationPriority priority = NotificationPriority.info,
    bool sticky = true,
    bool muted = false,
    VoidCallback? onDismiss,
    String? tag,
    Duration? timeout,
    String? title,
    DateTime? timestamp,
  }) {
    return HearthNotification(
      id: tag != null ? HearthNotification.idForTag(tag) : id,
      tag: tag,
      timeout: timeout,
      source: source,
      sourceLabel: defaultSourceLabel(source),
      priority: priority,
      title: title ?? 'Title $id',
      body: 'Body $id',
      sticky: sticky,
      muted: muted,
      timestamp: timestamp ?? DateTime(2026, 1, 1, 9, 30),
      onDismiss: onDismiss,
    );
  }

  group('NotificationService', () {
    late List<HearthNotification> chimed;
    late NotificationService service;

    NotificationService build({
      bool suppressed = false,
      Duration transientLifetime = const Duration(milliseconds: 20),
    }) {
      chimed = [];
      return NotificationService(
        playChime: (n) async => chimed.add(n),
        isChimeSuppressed: () => suppressed,
        transientLifetime: transientLifetime,
      );
    }

    setUp(() => service = build());
    tearDown(() => service.dispose());

    test('starts empty', () {
      expect(service.notifications, isEmpty);
      expect(service.hasActive, false);
    });

    test('ingest adds a card', () {
      service.ingest(make());
      expect(service.notifications, hasLength(1));
      expect(service.hasActive, true);
      expect(service.notifications.first.title, 'Title n1');
    });

    test('ingest keeps oldest first, newest last', () {
      service.ingest(make(id: 'a'));
      service.ingest(make(id: 'b'));
      service.ingest(make(id: 'c'));
      expect(service.notifications.map((n) => n.id), ['a', 'b', 'c']);
    });

    test('ingest plays the chime for a normal card', () {
      service.ingest(make(priority: NotificationPriority.alert));
      expect(chimed, hasLength(1));
      expect(chimed.first.chimeLabel, 'Ember Alert');
    });

    test('ingest does not chime when the card is muted', () {
      service.ingest(make(muted: true));
      expect(chimed, isEmpty);
    });

    test('ingest does not chime when suppressed (night mode)', () {
      service = build(suppressed: true);
      service.ingest(make());
      expect(chimed, isEmpty);
    });

    test('ingest does not chime for timer-sourced cards', () {
      // TimerService owns the looping fired-timer beep.
      service.ingest(make(source: NotificationSource.timer));
      expect(chimed, isEmpty);
    });

    test('re-ingesting the same id replaces rather than stacks', () {
      service.ingest(make(id: 'x', sticky: false));
      service.ingest(make(id: 'x'));
      expect(service.notifications, hasLength(1));
      expect(service.notifications.first.sticky, true);
    });

    test('dismiss removes one card', () {
      service.ingest(make(id: 'a'));
      service.ingest(make(id: 'b'));
      service.dismiss('a');
      expect(service.notifications.map((n) => n.id), ['b']);
    });

    test('dismiss is idempotent for an unknown id', () {
      service.ingest(make(id: 'a'));
      service.dismiss('nope');
      service.dismiss('a');
      service.dismiss('a');
      expect(service.notifications, isEmpty);
    });

    test('dismiss invokes the card onDismiss callback', () {
      var called = 0;
      service.ingest(make(id: 'a', onDismiss: () => called++));
      service.dismiss('a');
      expect(called, 1);
    });

    test('clearAll empties the deck and fires each onDismiss once', () {
      var called = 0;
      service.ingest(make(id: 'a', onDismiss: () => called++));
      service.ingest(make(id: 'b', onDismiss: () => called++));
      service.clearAll();
      expect(service.notifications, isEmpty);
      expect(called, 2);
    });

    test('sticky cards persist (no auto-dismiss)', () async {
      service.ingest(make(id: 'a', sticky: true));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.notifications, hasLength(1));
    });

    test('transient cards auto-dismiss after their lifetime', () async {
      service.ingest(make(id: 'a', sticky: false));
      expect(service.notifications, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.notifications, isEmpty);
    });

    test('dismissing a transient card cancels its auto-dismiss timer', () async {
      var called = 0;
      service.ingest(make(id: 'a', sticky: false, onDismiss: () => called++));
      service.dismiss('a');
      // Wait past the lifetime — onDismiss must not fire a second time.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(called, 1);
    });

    group('tags', () {
      const shortTimeout = Duration(milliseconds: 40);
      Future<void> wait(int ms) =>
          Future<void>.delayed(Duration(milliseconds: ms));

      test('same tag updates in place with no second chime', () {
        service.ingest(make(id: 'a'));
        service.ingest(make(tag: 'door', title: 'First'));
        service.ingest(make(id: 'b'));
        service.ingest(make(tag: 'door', title: 'Second'));
        expect(service.notifications.map((n) => n.id),
            ['a', 'tag-door', 'b']);
        expect(service.notifications[1].title, 'Second');
        expect(chimed, hasLength(3));
      });

      test('same-tag update keeps the original timestamp', () {
        final first = DateTime(2026, 1, 1, 9, 30);
        service.ingest(make(tag: 'door', timestamp: first));
        service.ingest(make(tag: 'door', timestamp: DateTime(2026, 1, 1, 9, 31)));
        expect(service.notifications.single.timestamp, first);
      });

      test('same-tag update keeps the original onDismiss', () {
        var called = 0;
        service.ingest(make(tag: 'door', onDismiss: () => called++));
        service.ingest(make(tag: 'door'));
        service.dismiss('tag-door');
        expect(called, 1);
      });

      test('timeout closes the card and restarts on update', () async {
        service.ingest(make(tag: 'door', timeout: shortTimeout));
        await wait(25);
        service.ingest(make(tag: 'door', timeout: shortTimeout));
        await wait(25);
        expect(service.notifications, hasLength(1),
            reason: 'the update should have restarted the timeout');
        await wait(40);
        expect(service.notifications, isEmpty);
      });

      test('timeout applies to an untagged card', () async {
        service.ingest(make(id: 'a', timeout: shortTimeout));
        await wait(70);
        expect(service.notifications, isEmpty);
      });

      test('clear removes the card and is idempotent', () {
        var called = 0;
        service.ingest(make(tag: 'door', onDismiss: () => called++));
        service.clear('door');
        service.clear('door');
        service.clear('never-seen');
        expect(service.notifications, isEmpty);
        expect(called, 1);
      });

      test('dismissed tag ignores updates without notifying', () {
        service.ingest(make(tag: 'door', timeout: const Duration(seconds: 5)));
        service.dismiss('tag-door');
        var notifyCount = 0;
        service.addListener(() => notifyCount++);

        service.ingest(make(tag: 'door', timeout: const Duration(seconds: 5)));

        expect(service.notifications, isEmpty);
        expect(notifyCount, 0);
        expect(chimed, hasLength(1));
      });

      test('clear forgets a dismissed tag', () {
        service.ingest(make(tag: 'door', timeout: const Duration(seconds: 5)));
        service.dismiss('tag-door');
        service.clear('door');

        service.ingest(make(tag: 'door', timeout: const Duration(seconds: 5)));

        expect(service.notifications, hasLength(1));
        expect(chimed, hasLength(2));
      });

      test('timeout forgets a dismissed tag', () async {
        service.ingest(make(tag: 'door', timeout: shortTimeout));
        service.dismiss('tag-door');
        await wait(70);

        service.ingest(make(tag: 'door', timeout: shortTimeout));

        expect(service.notifications, hasLength(1));
        expect(chimed, hasLength(2));
      });

      test('an update restarts the dismissed-tag timeout', () async {
        service.ingest(make(tag: 'door', timeout: shortTimeout));
        service.dismiss('tag-door');
        await wait(25);
        service.ingest(make(tag: 'door', timeout: shortTimeout));
        await wait(25);

        service.ingest(make(tag: 'door', timeout: shortTimeout));

        expect(service.notifications, isEmpty,
            reason: 'the heartbeats should have kept the tag remembered');
      });

      test('a tag with no timeout is not remembered after dismiss', () {
        service.ingest(make(tag: 'door'));
        service.dismiss('tag-door');

        service.ingest(make(tag: 'door'));

        expect(service.notifications, hasLength(1));
        expect(chimed, hasLength(2));
      });

      test('a card closed by timeout is not remembered', () async {
        service.ingest(make(tag: 'door', timeout: shortTimeout));
        await wait(70);
        expect(service.notifications, isEmpty);

        service.ingest(make(tag: 'door', timeout: shortTimeout));

        expect(service.notifications, hasLength(1));
        expect(chimed, hasLength(2));
      });
    });

    group('ingestPayload', () {
      test('adds a card and returns its id', () {
        final id = service.ingestPayload({'title': 'x', 'tag': 'door'});
        expect(id, 'tag-door');
        expect(service.notifications.single.title, 'x');
      });

      test('with clear and tag clears', () {
        service.ingestPayload({'title': 'x', 'tag': 'door'});
        final id = service.ingestPayload({'tag': 'door', 'clear': true});
        expect(id, 'tag-door');
        expect(service.notifications, isEmpty);
      });

      test('with clear and no tag returns null', () {
        service.ingestPayload({'title': 'x', 'tag': 'door'});
        expect(service.ingestPayload({'clear': true}), isNull);
        expect(service.ingestPayload({'title': 'y', 'clear': true}), isNull);
        expect(service.notifications.map((n) => n.title), ['x']);
      });

      test('a clear value other than true is ignored', () {
        final id = service
            .ingestPayload({'title': 'x', 'tag': 'door', 'clear': 'yes'});
        expect(id, 'tag-door');
        expect(service.notifications, hasLength(1));
      });

      test('with no title or message returns null', () {
        expect(service.ingestPayload({'priority': 'alert'}), isNull);
        expect(service.notifications, isEmpty);
      });
    });
  });
}

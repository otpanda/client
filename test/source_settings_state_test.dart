import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/source_settings.dart';

import 'package:otpanda_client/gmail_source.dart';
import 'package:otpanda_client/browser_session_contract.dart' show RuleBridge;

import 'gmail_source_test.dart' as gmail;

import 'browser_account_test.dart' show Bridge;

class SourceBridge extends Bridge {
  Completer<SessionResponse>? gate;
  int response = 200;
  int sourceReads = 0;
  SourceBridge() {
    status = 'restored';
  }
  @override
  Future<SessionResponse> read(String path) async {
    readPaths.add(path);
    sourceReads++;
    if (gate != null) return gate!.future;
    return SessionResponse(response, jsonEncode({'sources': sources}));
  }
}

class SourceGmailBridge extends SourceBridge
    implements GmailSourceBridge, RuleBridge {
  final gmailBridge = gmail.Bridge();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<SessionResponse> gmailSourceStatus() =>
      gmailBridge.gmailSourceStatus();
  @override
  Future<void> connectGmail() => gmailBridge.connectGmail();
  @override
  Future<String> takeGmailResult() => gmailBridge.takeGmailResult();
  @override
  Future<String> rulesCapabilities() => gmailBridge.rulesCapabilities();
  @override
  Future<GmailDisconnectResult> disconnectGmail(
    String id, {
    String rules = 'keep',
  }) async {
    sources = [];
    return gmailBridge.disconnectGmail(id, rules: rules);
  }
}

Future<void> page(WidgetTester t, ReadWorkspaceController c) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: otpandaTheme(),
      home: RepaintBoundary(
        key: const Key('source-proof'),
        child: Scaffold(
          appBar: AppBar(title: const Text('Sources')),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SourceSettings(controller: c),
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

void main() {
  testWidgets(
    'pending first read, failure, recovery, confirmed empty and retained error',
    (t) async {
      final b = SourceBridge()..gate = Completer<SessionResponse>();
      final c = ReadWorkspaceController(bridge: b)..suspend(preserve: true);
      await page(t, c);
      expect(find.textContaining('No sources connected'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'Loading sources',
        ),
        findsOneWidget,
      );
      expect(b.readPaths, ['/v1/manage/sources']);
      expect(b.contentHint, isNull);
      b.gate!.complete(const SessionResponse(503, '{}'));
      b.gate = null;
      await t.pump();
      await t.pump();
      expect(find.textContaining('Could not load sources'), findsOneWidget);
      expect(find.textContaining('No sources connected'), findsNothing);
      await t.pump(const Duration(seconds: 15));
      await t.pump();
      expect(b.sourceReads, 2);
      expect(c.suspended, isTrue);
      expect(find.textContaining('No sources connected'), findsOneWidget);
      await t.pump(const Duration(seconds: 60));
      expect(b.sourceReads, 2, reason: 'success starts no polling');
      b.response = 503;
      await c.refreshSources();
      await t.pump();
      expect(find.textContaining('No sources connected'), findsNothing);
      b.response = 200;
      b.sources = [
        {'source_id': 'phone', 'kind': 'sms', 'label': 'Fictional phone'},
      ];
      await c.refreshSources();
      await t.pump();
      b.response = 503;
      await c.refreshSources();
      await t.pump();
      expect(find.text('Fictional phone'), findsOneWidget);
      expect(find.textContaining('Could not load sources'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      final reads = b.sourceReads;
      await t.pump(const Duration(minutes: 5));
      expect(b.sourceReads, reads);
      c.dispose();
    },
  );

  testWidgets('navigation away rejects late read and cancels retries', (
    t,
  ) async {
    final b = SourceBridge()..gate = Completer<SessionResponse>();
    final gate = b.gate!;
    final c = ReadWorkspaceController(bridge: b)..suspend(preserve: true);
    await page(t, c);
    await t.pumpWidget(const SizedBox());
    gate.complete(
      const SessionResponse(
        200,
        '{"sources":[{"source_id":"old","kind":"sms","label":"Old phone"}]}',
      ),
    );
    await t.pump();
    expect(c.sourcesLoaded, isFalse);
    await t.pump(const Duration(minutes: 5));
    expect(b.sourceReads, 1);
    c.dispose();
  });

  testWidgets('background cancels read and resume rechecks without socket', (
    t,
  ) async {
    final b = SourceBridge()..gate = Completer<SessionResponse>();
    final gate = b.gate!;
    final c = ReadWorkspaceController(bridge: b)..suspend(preserve: true);
    await page(t, c);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    gate.complete(const SessionResponse(200, '{"sources":[]}'));
    await t.pump();
    expect(c.sourcesLoaded, isFalse);
    b.gate = null;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(c.sourcesLoaded, isTrue);
    expect(b.sourceReads, 2);
    expect(b.contentHint, isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  test('reset and account change reject previous identity response', () async {
    final b = SourceBridge()..gate = Completer<SessionResponse>();
    final old = b.gate!;
    final c = ReadWorkspaceController(bridge: b)..suspend(preserve: true);
    c.showSources();
    c.resetSession();
    b.gate = null;
    b.sources = [
      {'source_id': 'new', 'kind': 'sms', 'label': 'New phone'},
    ];
    c.showSources();
    await Future<void>.delayed(Duration.zero);
    old.complete(
      const SessionResponse(
        200,
        '{"sources":[{"source_id":"old","kind":"sms","label":"Old phone"}]}',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(c.settingsSources.single.id, 'new');
    c.clear();
    b.status = 'idle';
    expect(c.settingsSources, isEmpty);
    expect(c.sourcesLoaded, isFalse);
    c.dispose();
  });

  test('401 clears source snapshot and ends session', () async {
    final b = SourceBridge()..response = 401;
    final c = ReadWorkspaceController(bridge: b)..suspend(preserve: true);
    c.showSources();
    await Future<void>.delayed(Duration.zero);
    expect(c.sessionEnded, isTrue);
    expect(b.status, 'idle');
    expect(c.settingsSources, isEmpty);
    c.dispose();
  });
  testWidgets(
    '429 respects Retry-After and malformed response retains snapshot',
    (t) async {
      final b = SourceBridge()..gate = Completer<SessionResponse>();
      final gate = b.gate!;
      final c = ReadWorkspaceController(bridge: b)..suspend(preserve: true);
      await page(t, c);
      gate.complete(const SessionResponse(429, '{}', retryAfterSeconds: 45));
      b.gate = null;
      await t.pump();
      await t.pump(const Duration(seconds: 44));
      expect(b.sourceReads, 1);
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      expect(b.sourceReads, 2);
      expect(c.sourcesLoaded, isTrue);
      b.gate = Completer<SessionResponse>();
      final pending = c.refreshSources();
      b.gate!.complete(
        const SessionResponse(
          200,
          '{"sources":[{"source_id":"x","kind":"sms","label":"X"},{"source_id":"x","kind":"sms","label":"Y"}]}',
        ),
      );
      await pending;
      await t.pump();
      expect(c.settingsSources, isEmpty);
      expect(c.sourcesLoaded, isTrue);
      expect(c.sourcesMessage, contains('Could not load sources'));
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'actual disconnect completion queues one fresh read after old in-flight snapshot',
    (t) async {
      final b = SourceGmailBridge()
        ..sources = [
          {'source_id': 'gmail', 'kind': 'gmail', 'label': 'Fictional mailbox'},
        ];
      final c = ReadWorkspaceController(bridge: b)..suspend(preserve: true);
      await page(t, c);
      await t.pumpAndSettle();
      expect(find.text('Fictional mailbox'), findsOneWidget);
      b.gate = Completer<SessionResponse>();
      final old = b.gate!;
      final pending = c.refreshSources();
      await t.pump();
      await t.tap(find.text('Disconnect Gmail'));
      await t.pumpAndSettle();
      await t.tap(find.text('Verify and disconnect'));
      await t.pumpAndSettle();
      await t.tap(find.text('Keep paused'));
      await t.pumpAndSettle();
      expect(find.text('Gmail disconnected'), findsOneWidget);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      b.gate = null;
      old.complete(
        const SessionResponse(
          200,
          '{"sources":[{"source_id":"gmail","kind":"gmail","label":"Fictional mailbox"}]}',
        ),
      );
      await pending;
      await t.pumpAndSettle();
      expect(b.sourceReads, 3);
      expect(find.text('Fictional mailbox'), findsNothing);
      expect(find.textContaining('No sources connected'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'Gmail connect is disabled until source snapshot confirmed and after failure',
    (t) async {
      final b = SourceGmailBridge()..gate = Completer<SessionResponse>();
      b.gmailBridge.ready = true;
      final c = ReadWorkspaceController(bridge: b)..suspend(preserve: true);
      await page(t, c);
      await t.pumpAndSettle();
      FilledButton button() => t.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Connect Gmail'),
      );
      expect(button().onPressed, isNull);
      expect(b.gmailBridge.connects, 0);
      b.gate!.complete(const SessionResponse(503, '{}'));
      b.gate = null;
      await t.pumpAndSettle();
      expect(button().onPressed, isNull);
      await t.pump(const Duration(seconds: 15));
      await t.pumpAndSettle();
      expect(button().onPressed, isNotNull);
      b.response = 503;
      await c.refreshSources();
      await t.pumpAndSettle();
      expect(button().onPressed, isNull);
      expect(b.gmailBridge.connects, 0);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'open connect confirmation cannot continue after sources become unknown',
    (t) async {
      final b = SourceGmailBridge();
      b.gmailBridge.ready = true;
      final c = ReadWorkspaceController(bridge: b)..suspend(preserve: true);
      await page(t, c);
      await t.pumpAndSettle();
      await t.tap(find.text('Connect Gmail'));
      await t.pumpAndSettle();
      expect(find.text('Verify and continue'), findsOneWidget);
      b.gate = Completer<SessionResponse>();
      final gate = b.gate!;
      final pending = c.refreshSources();
      await t.pump();
      await t.tap(find.text('Verify and continue'));
      await t.pumpAndSettle();
      expect(b.gmailBridge.connects, 0);
      gate.complete(const SessionResponse(200, '{"sources":[]}'));
      await pending;
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

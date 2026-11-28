import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/source_settings.dart';

import 'settings_hub_test.dart' show CountingBridge, pump;

class HeldSources extends CountingBridge {
  final sourceGate = Completer<SessionResponse>();
  @override
  Future<SessionResponse> read(String path) {
    if (path == '/v1/manage/sources') {
      paths.add(path);
      return sourceGate.future;
    }
    return super.read(path);
  }
}

class ReloginSources extends CountingBridge {
  int sourceStatus = 401;
  @override
  Future<void> passkey() async {
    status = 'restored';
  }

  @override
  Future<void> start(String mode) async {
    status = 'restored';
  }

  @override
  Future<SessionResponse> read(String path) {
    if (path == '/v1/manage/sources' && sourceStatus == 401) {
      paths.add(path);
      return Future.value(const SessionResponse(401, '{}'));
    }
    return super.read(path);
  }
}

void main() {
  testWidgets('cold sources route reads sources before claiming none', (
    t,
  ) async {
    final b = CountingBridge()
      ..status = 'restored'
      ..clockNow = 100000;
    await pump(t, b, navigation: 'settings/sources', workspace: true);
    expect(b.paths.where((p) => p == '/v1/manage/sources'), hasLength(1));
    expect(b.paths.where((p) => p == '/v1/manage/active-codes'), isEmpty);
    expect(b.paths.where((p) => p == '/v1/manage/unassigned'), isEmpty);
  });
  testWidgets(
    'real parent cold source route keeps pending distinct from empty',
    (t) async {
      final b = HeldSources()
        ..status = 'restored'
        ..clockNow = 100000;
      await pump(
        t,
        b,
        navigation: 'settings/sources',
        workspace: true,
        size: const Size(390, 844),
      );
      expect(find.textContaining('No sources connected'), findsNothing);
      expect(b.paths.where((p) => p == '/v1/manage/sources'), hasLength(1));
      b.sourceGate.complete(const SessionResponse(200, '{"sources":[]}'));
      await t.pumpAndSettle();
      expect(find.textContaining('No sources connected'), findsOneWidget);
      expect(b.paths.where((p) => p == '/v1/manage/active-codes'), isEmpty);
      expect(b.paths.where((p) => p == '/v1/manage/unassigned'), isEmpty);
      expect(b.contentHint, isNull);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('real parent navigation away discards source response', (
    t,
  ) async {
    final b = HeldSources()
      ..status = 'restored'
      ..clockNow = 100000;
    Widget host(String route) => MaterialApp(
      home: BrowserAccountPage(
        bridge: b,
        workspaceEnabled: true,
        loginEnabled: true,
        accountOnly: true,
        clock: () => 100000,
        navigation: route,
      ),
    );
    await t.pumpWidget(host('settings/sources'));
    await t.pumpAndSettle();
    expect(b.paths.where((p) => p == '/v1/manage/sources'), hasLength(1));
    await t.pumpWidget(host('settings/about'));
    await t.pumpAndSettle();
    b.sourceGate.complete(
      const SessionResponse(
        200,
        '{"sources":[{"source_id":"old","kind":"sms","label":"Old phone"}]}',
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Old phone'), findsNothing);
    final reads = b.paths.length;
    await t.pump(const Duration(seconds: 20));
    expect(b.paths.length, reads);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('real parent 401 tears down Sources and re-signin loads fresh', (
    t,
  ) async {
    final b = ReloginSources()
      ..status = 'restored'
      ..clockNow = 100000;
    await pump(t, b, navigation: 'settings/sources', workspace: true);
    expect(find.byType(SourceSettings), findsNothing);
    expect(b.status, 'idle');
    b.sourceStatus = 200;
    b.sources = [
      {'source_id': 'new', 'kind': 'sms', 'label': 'New sign-in phone'},
    ];
    await t.tap(find.text('Sign in with a passkey'));
    await t.pumpAndSettle();
    expect(find.byType(SourceSettings), findsOneWidget);
    expect(find.text('New sign-in phone'), findsOneWidget);
    expect(find.textContaining('No sources connected'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}

import 'dart:async';
import 'dart:convert';

import 'unassigned_context.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'browser_session_contract.dart';
import 'session_contract.dart';

class _BrowserReadTransport implements SessionTransport {
  final BrowserSessionBridge bridge;
  final bool Function()? active;
  const _BrowserReadTransport(this.bridge, [this.active]);
  @override
  Future<SessionResponse> getManagement(String path) => active?.call() == false
      ? Future.value(const SessionResponse(503, '{}'))
      : bridge.read(path);
  @override
  Future<void> close() async {}
}

/// No credentials or persistence. One bounded refresh reads five endpoints.
/// A view owns resume/background events and the visible-code clock.
class ReadWorkspaceController extends ChangeNotifier {
  final BrowserSessionBridge bridge;
  final int Function() clock;
  late CodeStore store = CodeStore(_BrowserReadTransport(bridge));
  bool loading = false, suspended = false, _disposed = false;
  String message = '';
  bool rateLimited = false, sessionEnded = false, hasLoaded = false;
  int publishedRevision = 0;
  List<UnassignedContext> contexts = const [];
  bool _transportLost = false, _readLost = false;
  bool get connectionLost => _transportLost || _readLost;
  int _readFailures = 0;
  Timer? _readRetryTimer, _readLossTimer;
  int _epoch = 0, _nextRefreshAt = 0;
  void Function()? _unsubscribeRealtime;
  Timer? _hintTimer;
  bool _hintPending = false;
  bool mutationUpdating = false;
  int _mutationRevision = 0;
  ReadWorkspaceController({required this.bridge, int Function()? clock})
    : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  // A Sources settings read stays separate from the suspended code workspace.
  // No socket or code/inbox reads are started by this view.
  List<PrivateSource>? _settingsSources;
  bool _sourcesUseWorkspace = true;
  List<PrivateSource> get settingsSources =>
      _settingsSources ?? (_sourcesUseWorkspace ? store.sources : const []);
  bool get sourcesLoaded =>
      _settingsSources != null || (_sourcesUseWorkspace && hasLoaded);
  bool sourcesLoading = false;
  String sourcesMessage = '';
  bool _sourcesActive = false, _sourcesAgain = false;
  int _sourcesEpoch = 0, _sourcesFailures = 0;
  Timer? _sourcesRetry;

  void showSources() {
    if (_disposed || _sourcesActive) return;
    _sourcesActive = true;
    unawaited(refreshSources());
  }

  void hideSources() {
    _sourcesActive = false;
    ++_sourcesEpoch;
    sourcesLoading = false;
    _sourcesAgain = false;
    _sourcesRetry?.cancel();
    _sourcesRetry = null;
  }

  Future<void> refreshSources() async {
    if (_disposed || !_sourcesActive || !signedIn) return;
    if (sourcesLoading) {
      _sourcesAgain = true;
      return;
    }
    _sourcesRetry?.cancel();
    _sourcesRetry = null;
    final epoch = ++_sourcesEpoch;
    sourcesLoading = true;
    sourcesMessage = '';
    _notify();
    bool current() => !_disposed && _sourcesActive && epoch == _sourcesEpoch;
    try {
      final response = await bridge.read('/v1/manage/sources');
      if (!current()) return;
      if (!signedIn) {
        clear();
        return;
      }
      if (response.status != 200) {
        throw ClientFailure(response.status, response.retryAfterSeconds);
      }
      final body = jsonDecode(response.body);
      final rows = body is Map<String, dynamic> ? body['sources'] : null;
      if (rows is! List || rows.length > 100) {
        throw const FormatException('Invalid sources');
      }
      final sources = rows
          .map((row) {
            if (row is! Map<String, dynamic>) {
              throw const FormatException('Invalid source');
            }
            return row;
          })
          .where((row) => row['revoked_at'] == null)
          .map(PrivateSource.fromJson)
          .toList();
      if (sources.map((source) => source.id).toSet().length != sources.length) {
        throw const FormatException('Duplicate source');
      }
      if (_sourcesAgain) return;
      _settingsSources = List.unmodifiable(sources);
      _sourcesFailures = 0;
    } catch (error) {
      if (!current()) return;
      if (error is ClientFailure && error.signedOut) {
        clear();
        sessionEnded = true;
        bridge.clear();
        _notify();
        return;
      }
      if (_sourcesAgain) return;
      sourcesMessage = error is ClientFailure && error.status == 429
          ? 'Too many requests. Sources will retry automatically.'
          : 'Could not load sources. Updates will retry automatically.';
      // Same failed-read backoff as the workspace: 15s, 30s, then 60s,
      // respecting Retry-After up to five minutes. Only while this view is active.
      _sourcesFailures++;
      final delay = 15000 * (1 << (_sourcesFailures - 1).clamp(0, 2));
      final header = error is ClientFailure
          ? (error.retryAfterSeconds ?? 0).clamp(0, 300) * 1000
          : 0;
      _sourcesRetry = Timer(
        Duration(milliseconds: header > delay ? header : delay),
        () {
          _sourcesRetry = null;
          if (current()) unawaited(refreshSources());
        },
      );
    } finally {
      if (current()) {
        sourcesLoading = false;
        _notify();
        if (_sourcesAgain) {
          _sourcesAgain = false;
          unawaited(refreshSources());
        }
      }
    }
  }

  /// Discard only the settings snapshot when the parent confirms a new identity.
  void resetSources() {
    hideSources();
    _sourcesUseWorkspace = false;
    _settingsSources = null;
    sourcesMessage = '';
    _sourcesFailures = 0;
  }

  /// Shared best-effort duplicate keys from the current owned TOTP snapshot.
  Set<(String?, String)> get importDuplicateKeys => {
    for (final e in store.entries)
      if (e.manage && e.totp) (e.issuer, e.account),
  };

  bool get signedIn =>
      !sessionEnded &&
      ['restored', 'session-paused', 'restoring'].contains(bridge.status);
  bool get canRefresh =>
      !loading && !suspended && signedIn && clock() >= _nextRefreshAt;
  int get refreshWaitMs => (_nextRefreshAt - clock()).clamp(0, 60000);

  /// Subscribes to content-free realtime hints while signed in and visible.
  /// Idempotent. A hint only asks for the ordinary refresh, so every existing
  /// rule (refresh gate, epoch guard, 401 handling) still applies.
  void _ensureRealtime() {
    if (_unsubscribeRealtime != null || _disposed || suspended || !signedIn) {
      return;
    }
    if (bridge is! RealtimeBridge) return;
    _unsubscribeRealtime = (bridge as RealtimeBridge).realtimeSubscribe(
      _onHint,
    );
  }

  void _stopRealtime() {
    _transportLost = false;
    final stop = _unsubscribeRealtime;
    _unsubscribeRealtime = null;
    _hintTimer?.cancel();
    _hintTimer = null;
    _hintPending = false;
    stop?.call();
  }

  void _onHint(String reason) {
    if (_disposed || suspended || !signedIn) return;
    if (reason == 'connection-lost' || reason == 'connection-restored') {
      _transportLost = reason == 'connection-lost';
      _notify();
      return;
    }
    if (reason != 'connect' && reason != 'changed') return;
    _hintPending = true;
    _drainHint();
  }

  /// One trailing refresh: runs now if the gate is open, otherwise once when
  /// it opens. Many hints collapse into one request.
  void _drainHint() {
    if (!_hintPending || _disposed) return;
    if (suspended || !signedIn) {
      _hintPending = false;
      return;
    }
    if (loading) return; // refresh() drains again when it finishes
    final wait = _nextRefreshAt - clock();
    if (wait <= 0) {
      _hintPending = false;
      refresh();
    } else {
      _hintTimer ??= Timer(Duration(milliseconds: wait), () {
        _hintTimer = null;
        _drainHint();
      });
    }
  }

  void _cancelReadRetry({bool reset = true}) {
    _readRetryTimer?.cancel();
    _readRetryTimer = null;
    _readLossTimer?.cancel();
    _readLossTimer = null;
    if (reset) {
      _readFailures = 0;
      _readLost = false;
    }
  }

  void _retryFailedRead([int? retryAfterSeconds]) {
    if (_disposed || suspended || !signedIn) return;
    _readFailures++;
    final delay = (15000 * (1 << (_readFailures - 1).clamp(0, 2))).clamp(
      15000,
      60000,
    );
    final headerDelay = retryAfterSeconds == null
        ? 0
        : retryAfterSeconds.clamp(0, 300) * 1000;
    final next = clock() + (headerDelay > delay ? headerDelay : delay);
    if (_nextRefreshAt < next) _nextRefreshAt = next;
    _readLossTimer ??= Timer(const Duration(seconds: 120), () {
      _readLossTimer = null;
      if (_disposed || suspended || !signedIn || _readFailures == 0) return;
      _readLost = true;
      _notify();
    });
    _readRetryTimer?.cancel();
    _readRetryTimer = Timer(
      Duration(milliseconds: (_nextRefreshAt - clock()).clamp(0, 2147483647)),
      () {
        _readRetryTimer = null;
        if (_disposed || suspended || !signedIn) return;
        refresh();
      },
    );
  }

  // Server-confirmed entry edits not yet seen in a read that started after them.
  // A read already in flight can still return the old label; the edit is laid
  // over it so the list never goes back.
  final Map<String, ({String? service, String? account})> _confirmed = {};
  int _confirmedCount = 0;

  /// The server confirmed this rename and/or account change: show it now.
  /// No request is made here. A normal refresh still follows and reconciles.
  void applyEntryEdit(String id, {String? service, String? account}) {
    if (_disposed || !hasLoaded) return;
    final prior = _confirmed[id];
    _confirmed[id] = (
      service: service ?? prior?.service,
      account: account ?? prior?.account,
    );
    _confirmedCount++;
    store.replaceEntry(id, service: service, account: account);
    publishedRevision++;
    _notify();
  }

  /// Explicit local mutation invalidation, coalesced behind the existing gate.
  void refreshAfterMutation({bool showUpdating = false}) {
    if (_disposed || suspended || !signedIn) return;
    if (showUpdating) {
      _mutationRevision++;
      mutationUpdating = true;
      _notify();
    }
    _hintPending = true;
    _drainHint();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    if (!canRefresh || _disposed) return;
    _readRetryTimer?.cancel();
    _readRetryTimer = null;
    final mutationRevision = _mutationRevision;
    final epoch = ++_epoch;
    _nextRefreshAt = clock() + 15000;
    loading = true;
    message = '';
    rateLimited = false;
    final confirmedAtStart = _confirmedCount;
    final staged = CodeStore(
      _BrowserReadTransport(bridge, () => !_disposed && epoch == _epoch),
    );
    _notify();
    try {
      await staged.load(clock, includePrivateInbox: true);
      if (_disposed || epoch != _epoch) return;
      List<UnassignedContext> reviews = const [];
      try {
        final response = await bridge.read('/v1/manage/unassigned-context');
        if (response.status == 401) throw const ClientFailure(401);
        if (response.status == 200) {
          final rows =
              (jsonDecode(response.body) as Map<String, dynamic>)['contexts'];
          if (rows is! List || rows.length > 200) {
            throw const FormatException('Invalid context list');
          }
          reviews = rows
              .map((v) => UnassignedContext.fromJson(v as Map<String, dynamic>))
              .toList();
        }
      } on ClientFailure {
        rethrow;
      } catch (_) {
        /* Optional context never blocks usable codes. No raw fallback. */
      }
      if (_disposed || epoch != _epoch) return;
      if (!signedIn) {
        store.clear();
      } else {
        if (bridge is SessionContinuityBridge) {
          staged.updateSessionExpiry(
            (bridge as SessionContinuityBridge).accessExpiresAt,
            clock(),
          );
        }
        // A read that began after the last confirmed edit already carries it.
        // An older one may predate it, so the edits are laid over it.
        if (confirmedAtStart == _confirmedCount) {
          _confirmed.clear();
        } else {
          _confirmed.forEach(
            (id, v) =>
                staged.replaceEntry(id, service: v.service, account: v.account),
          );
        }
        contexts = List.unmodifiable(reviews);
        store = staged;
        publishedRevision++;
        hasLoaded = true;
        _sourcesUseWorkspace = true;
        _cancelReadRetry();
      }
    } on ClientFailure catch (error) {
      if (_disposed || epoch != _epoch) return;
      if (error.signedOut) {
        store.clear();
        contexts = const [];
        hasLoaded = false;
        sessionEnded = true;
        _stopRealtime();
        _cancelReadRetry();
        bridge.clear();
      }
      rateLimited = error.status == 429;
      if (rateLimited) _nextRefreshAt = clock() + 60000;
      message = error.toString();
      if (!error.signedOut) _retryFailedRead(error.retryAfterSeconds);
    } catch (_) {
      if (_disposed || epoch != _epoch) return;
      message =
          'Waiting for your connection. Updates will retry automatically.';
      _retryFailedRead();
    } finally {
      if (!_disposed && epoch == _epoch) {
        loading = false;
        if (mutationRevision == _mutationRevision) mutationUpdating = false;
        _notify();
        _drainHint();
      }
    }
  }

  void tick() {
    if (_disposed || suspended) return;
    if (bridge is SessionContinuityBridge) {
      store.updateSessionExpiry(
        (bridge as SessionContinuityBridge).accessExpiresAt,
        clock(),
      );
      // Expired access hides records through CodeStore's clock, but is not
      // proof that the separate refresh session has ended.
      if (store.sessionExpired(clock())) {
        _notify();
        return;
      }
    }
    if (store.sessionExpired(clock())) {
      sessionEnded = true;
      _stopRealtime();
      bridge.clear();
      clear();
      message = 'Your session ended. Sign in again.';
    }
    _ensureRealtime();
    _notify();
  }

  void clear() {
    resetSources();
    mutationUpdating = false;
    ++_epoch;
    loading = false;
    hasLoaded = false;
    _transportLost = false;
    _confirmed.clear();
    _cancelReadRetry();
    store.clear();
    contexts = const [];
    _notify();
  }

  void suspend({bool preserve = false}) {
    suspended = true;
    _cancelReadRetry();
    _stopRealtime();
    if (preserve) {
      ++_epoch;
      loading = false;
      _notify();
    } else {
      clear();
    }
  }

  void resetSession() {
    clear();
    sessionEnded = false;
    suspended = false;
    message = '';
    _nextRefreshAt = 0;
  }

  void resume() {
    hideSources();
    _settingsSources = null;
    if (_disposed) return;
    suspended = false;
    if (bridge is SessionContinuityBridge) {
      store.updateSessionExpiry(
        (bridge as SessionContinuityBridge).accessExpiresAt,
        clock(),
      );
    }
    if (!signedIn) clear();
    _ensureRealtime();
    if (mutationUpdating) {
      _hintPending = true;
      _drainHint();
    }
    _notify();
  }

  bool canCopyAssigned(ReceivedCode code) =>
      !suspended && signedIn && store.visibleCodes(clock()).contains(code);
  bool canCopyPrivate(UnassignedCode code) =>
      !suspended && signedIn && store.visibleUnassigned(clock()).contains(code);

  Future<void> copyAssigned(ReceivedCode code) async {
    if (canCopyAssigned(code)) {
      await Clipboard.setData(ClipboardData(text: code.value));
    }
  }

  Future<void> copyPrivate(UnassignedCode code) async {
    if (canCopyPrivate(code)) {
      await Clipboard.setData(ClipboardData(text: code.value));
    }
  }

  @override
  void dispose() {
    hideSources();
    _stopRealtime();
    _cancelReadRetry();
    _disposed = true;
    ++_epoch;
    store.clear();
    super.dispose();
  }
}

import 'sharing_transport.dart';
import 'management_contract.dart' show MutationUnconfirmed;
import 'sharing_contract.dart';
import 'sharing_page.dart';
import 'sharing_accept_page.dart';
import 'transfer/import_review.dart';
import 'branding.dart';
import 'display_settings.dart';
import 'source_settings.dart';
import 'tile_display_preference.dart';
import 'tile_display_store.dart';
import 'about_page.dart';
import 'auth_entry.dart';
import 'product_shell.dart';
import 'detail_routes.dart';
import 'totp_batch_contract.dart';
import 'read_workspace_controller.dart';
import 'main.dart' show ClientHome;

import 'dart:async';
import 'dart:convert';

import 'assignment_dialog.dart';

import 'organization_contract.dart';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

import 'browser_session.dart';
import 'browser_session_contract.dart';
import 'extension_connect.dart';
import 'extension_popup.dart';
import 'google_link.dart';
import 'lost_access_page.dart';
import 'recovery_contract.dart';
import 'recovery_panel.dart';
import 'profile_cache.dart';
import 'session_contract.dart';
import 'settings_hub.dart';

const _verificationCopy = [
  'New devices need a passkey. Approval from another enrolled device is not available yet.',
  'Google sign-in alone is enough. Turn this on for another check on new devices.',
];

class _ReadTransport implements SessionTransport {
  final BrowserSessionBridge bridge;
  const _ReadTransport(this.bridge);
  @override
  Future<SessionResponse> getManagement(String path) => bridge.read(path);
  @override
  Future<void> close() async {}
}

/// Separate from fictional preview. Read-only data and browser signout only.
class BrowserAccountPage extends StatefulWidget {
  final BrowserSessionBridge? bridge;
  final bool loginEnabled;

  /// Separately expose sign-out for an already authenticated native host.
  /// Does not enable browser-only sign-in or account settings actions.
  final bool? signOutEnabled;
  final bool assignmentEnabled;
  final bool entryEditEnabled;
  final bool entryDomainsEnabled;
  final bool accountOnly;
  final bool workspaceEnabled;
  final int Function()? clock;
  final Widget? localSecuritySetting;
  final SharingClient? sharingClient;
  final Object? sharingIdentity;
  final Widget? transferPage;
  final Widget Function(
    Set<(String?, String)> existing,
    Future<void> Function() refresh,
  )?
  transferPageBuilder;
  final ImportSaver? importSaver;

  /// Unified codes or an allowed settings/recovery route. Unknown routes go home.
  final String? navigation;

  /// Called with a route id when the person navigates inside the page. It is
  /// never called for a change that came from [navigation].
  final ValueChanged<String>? onNavigate;
  const BrowserAccountPage({
    super.key,
    this.bridge,
    this.loginEnabled = false,
    this.signOutEnabled,
    this.assignmentEnabled = false,
    this.entryEditEnabled = false,
    this.entryDomainsEnabled = false,
    this.accountOnly = false,
    this.workspaceEnabled = false,
    this.clock,
    this.localSecuritySetting,
    this.sharingClient,
    this.sharingIdentity,
    this.transferPage,
    this.transferPageBuilder,
    this.importSaver,
    this.navigation,
    this.onNavigate,
  });
  @override
  State<BrowserAccountPage> createState() => _BrowserAccountPageState();
}

class _BrowserAccountPageState extends State<BrowserAccountPage>
    with WidgetsBindingObserver {
  late final BrowserSessionBridge bridge;
  late final CodeStore store;
  late final ReadWorkspaceController workspace;
  SharingClient? get sharingClient {
    if (widget.sharingClient != null) return widget.sharingClient;
    if (!const bool.fromEnvironment('SHARING_ENABLED') ||
        bridge is! SharingManagementBridge) {
      return null;
    }
    final host = bridge as SharingManagementBridge;
    if (!host.sharingAvailable || status != 'restored') return null;
    final epoch = host.sharingEpoch;
    return SharingClient(
      BoundSharingTransport(
        current: () async =>
            host.sharingAvailable &&
            host.sharingEpoch == epoch &&
            bridge.status == 'restored',
        send: (p, b) => host.sharingPost(p, b, epoch),
      ),
    );
  }

  Object? get sharingIdentity =>
      widget.sharingIdentity ??
      (
        sessionOwner,
        sessionKey,
        bridge is SharingManagementBridge
            ? (bridge as SharingManagementBridge).sharingEpoch
            : null,
      );
  bool accountOpen = false;
  SettingsCategory? settingsCategory;
  bool passkeysOpen = false;
  bool securityRequested = false;
  bool securityLoading = false;
  bool securityFailed = false;
  // Live updates for the security status: one shared-socket subscription while an
  // Account & security page is shown. A hint carries no data; it only asks for the
  // ordinary authenticated status read, coalesced to one in flight plus one trailing.
  void Function()? securityUnsubscribe;
  bool securityTrailing = false;
  Timer? securitySpacing;
  bool securityCooling = false;
  int securityTicks = 0;

  /// Selects what [id] names without telling the router. Unknown ids do
  /// nothing. [direct] sets state only, for use before the first load.
  void applyRoute(String? id, {bool direct = false}) {
    if (id == null) return;
    if (settingsCategoryForRoute(id) != SettingsCategory.account ||
        id == settingsPasskeysRoute) {
      overviewPreparedRevision = null;
    }
    if (id == 'codes' || parseDetailRoute(id) != null) {
      if (!widget.workspaceEnabled) return;
      settingsCategory = null;
      passkeysOpen = false;
      if (accountOpen) {
        accountOpen = false;
        if (!direct) {
          workspace.resume();

          unawaited(workspace.refresh());
        }
      } else if (!direct) {}
      return;
    }
    if (!isSettingsRoute(id)) {
      applyRoute('codes', direct: direct);
      return;
    }
    passkeysOpen = id == settingsPasskeysRoute;
    settingsCategory = passkeysOpen
        ? SettingsCategory.account
        : settingsCategoryForRoute(id);
    if (!accountOpen && widget.workspaceEnabled) {
      accountOpen = true;
      if (!direct) {
        workspace.suspend(preserve: true);
        // The restored workspace already holds session/header identity.
        // Each category owns its reads when shown; the hub needs none.
      }
    }
  }

  @override
  void didUpdateWidget(BrowserAccountPage old) {
    super.didUpdateWidget(old);
    if (widget.navigation != null &&
        widget.navigation != old.navigation &&
        status == 'restored') {
      setState(() => applyRoute(widget.navigation));
    }
  }

  void navigated(String id) => widget.onNavigate?.call(id);
  void openSettings() {
    overviewPreparedRevision = null;
    workspace.suspend(preserve: true);
    setState(() {
      accountOpen = true;
      settingsCategory = null;
      passkeysOpen = false;
    });
    navigated(settingsHubRoute);
  }

  void leaveSettings() {
    overviewPreparedRevision = null;
    workspace.resume();
    setState(() {
      accountOpen = false;
      settingsCategory = null;
      passkeysOpen = false;
    });
    navigated('codes');
    workspace.refresh();
  }

  bool busy = true;
  String status = 'loading', message = '';
  int revision = 0;
  int? accountExpiresAt;
  Map<String, dynamic>? overview, securityInfo;

  /// Static identity from this sign-in's cache (see ProfileCacheBridge). It only
  /// feeds the header; passkeys, Google status and the rest always come from the
  /// live overview.
  CachedProfile? cachedProfile;
  String? sessionOwner, sessionKey;
  bool overviewLoading = false, overviewAttempted = false;
  // The held overview could not be refreshed: say so instead of implying it
  // was just verified.
  bool overviewStale = false;
  // When the held overview was read. The Account page appearing right after
  // that read (the open itself) does not read it a second time.
  DateTime? overviewFetchedAt;
  int overviewInFlightRevision = -1;
  int accountPagesShown = 0;
  int? overviewPreparedRevision;
  String? settingChange;
  bool securityOpen = false;
  final organization = OrganizationStore();
  bool organizationReady = false, organizationBusy = false;
  int organizationEpoch = 0, organizationSnapshot = 0, organizationRequest = 0;
  bool maintaining = false;
  Future<void> maintainSession() async {
    if (maintaining ||
        busy ||
        bridge is! SessionContinuityBridge ||
        !['restored', 'session-paused', 'restoring'].contains(status)) {
      return;
    }
    maintaining = true;
    try {
      await (bridge as SessionContinuityBridge).maintain();
      if (!mounted) return;
      if (bridge.status == 'sign-in-required') {
        workspace.clear();
        store.clear();
        clearOrganization();
        setState(() => status = 'sign-in-required');
        return;
      }
      final expiry = (bridge as SessionContinuityBridge).accessExpiresAt;
      store.updateSessionExpiry(expiry, now());
      if (accountExpiresAt != null && expiry > now()) accountExpiresAt = expiry;
      if (bridge.status == 'restored' && status == 'session-paused') {
        status = 'restored';
      }
      if (['session-paused', 'restoring'].contains(bridge.status)) {
        status = bridge.status;
      }
    } catch (_) {
      /* The existing session remains authoritative. */
    } finally {
      maintaining = false;
    }
  }

  final tileDisplay = TileDisplayPreference(createTileDisplayStore());
  int automaticTicks = 0;
  Timer? expiryTick;
  int now() => widget.clock?.call() ?? DateTime.now().millisecondsSinceEpoch;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      tileDisplay.load().then((_) {
        if (mounted) setState(() {});
      }),
    );
    bridge = widget.bridge ?? createBrowserSession();
    store = CodeStore(_ReadTransport(bridge));
    workspace = ReadWorkspaceController(bridge: bridge, clock: now);
    workspace.addListener(workspaceChanged);
    final Object cacheBridge = bridge;
    if (cacheBridge is ProfileCacheBridge) {
      cacheBridge.onProfileRevoked(() {
        if (!mounted) return;
        // Another tab ended this sign-in: show the skeleton, and make any
        // overview request already in flight land nowhere.
        revision++;
        workspace.resetSources();
        setState(() {
          resetIdentity();
          securityInfo = null;
          busy = false;
          message = '';
        });
        // Converge on the truth: still signed in reloads the account, ended
        // goes to sign-in through the usual paths.
        if (status == 'restored') unawaited(refresh());
      });
    }
    expiryTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && status == 'authenticating' && bridge.status != status) {
        setState(() => status = bridge.status);
      }
      if (mounted) unawaited(maintainSession());
      if (mounted &&
          status == 'restored' &&
          securityRequested &&
          !busy &&
          ++securityTicks >= 30) {
        securityTicks = 0;
        unawaited(refreshSecurity());
      }
      if (mounted && status == 'restored' && !busy && ++automaticTicks >= 30) {
        automaticTicks = 0;
        if (!widget.workspaceEnabled ||
            (accountOpen &&
                !organizationReady &&
                !organizationBusy &&
                widget.navigation == null)) {
          unawaited(refresh());
        }
      }
      // Local state check, no network: subscribe once the page is restored and
      // an account page is showing; drop the subscription when it is not.
      if (mounted && status == 'restored' && accountPagesShown > 0) {
        listenSecurity();
      } else if (securityUnsubscribe != null) {
        stopSecurityListening();
      }
      if (mounted && status == 'restored') {
        // The extension popup owns its single live socket; the hidden workspace
        // controller must not open a second one.
        if (widget.workspaceEnabled && !isExtensionPopup(bridge)) {
          workspace.tick();
        }
        if (bridge is! SessionContinuityBridge &&
            ((widget.accountOnly &&
                    accountExpiresAt != null &&
                    now() >= accountExpiresAt!) ||
                store.sessionExpired(now()))) {
          clearOrganization();
          store.clear();
          status = 'sign-in-required';
          message = 'Browser access expired. Sign in again.';
        }
        setState(() {});
      }
    });
    initialize();
  }

  Future<void> initialize() async {
    try {
      await bridge.ready;
      if (!mounted) return;
      setState(() => status = bridge.status);
      if (status == 'restored') {
        accountOpen = false;
        applyRoute(widget.navigation, direct: true);
        if (accountOpen) workspace.suspend(preserve: true);
        // A Google connect that just returned may have changed the picture
        // while the sign-in stayed the same. Read the notice first, drop the
        // static copy, and make the live overview load before judging it.
        if (bridge is GoogleConnectBridge) {
          pendingLinkResult = (bridge as GoogleConnectBridge)
              .takeGoogleLinkResult();
          if (pendingLinkResult.isNotEmpty) {
            forceOverview = true;
            dropStaticProfile();
          }
        }
        await refresh();
        if (mounted) setState(showGoogleLinkResult);
        // A browser extension waiting for approval gets one explicit
        // confirmation. The bridge sends nothing until the user presses Connect.
        if (mounted && bridge is ExtensionConnectBridge) {
          unawaited(
            showExtensionConnectDialog(
              context,
              bridge as ExtensionConnectBridge,
            ),
          );
        }
      }
    } catch (_) {
      message = 'Could not check this browser session.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void workspaceChanged() {
    if (!mounted) return;
    if (workspace.sessionEnded) {
      status = 'sign-in-required';
    } else if (!workspace.signedIn) {
      status = bridge.status;
    }
    if (workspace.hasLoaded &&
        status == 'restored' &&
        !organizationReady &&
        !organizationBusy) {
      unawaited(loadOrganizationSection());
    }
    setState(() {});
  }

  Future<void> run(
    Future<void> Function() action, {
    bool loadAfter = true,
  }) async {
    final attempt = ++revision;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await action();
      if (!mounted || attempt != revision) return;
      if (loadAfter && bridge.status == 'restored' && workspace.sessionEnded) {
        workspace.resetSession();
      }
      status = workspace.sessionEnded ? 'sign-in-required' : bridge.status;
      if (status == 'restored' && loadAfter) {
        await loadAccount(attempt);
      } else if (status == 'sign-in-required') {
        message =
            'Sign-in did not finish. Start again when sign-in is available.';
      }
    } catch (_) {
      if (!mounted || attempt != revision) return;
      clearOrganization();
      store.clear();
      status = bridge.status;
      message = 'Could not complete that request. Try again.';
    } finally {
      if (mounted && attempt == revision) {
        setState(() => busy = false);
        // A hint that landed while this action ran gets one catch-up read.
        if (overviewAgain) {
          overviewAgain = false;
          unawaited(refreshOverviewQuietly());
        }
      }
    }
  }

  /// Signed-in connect: no sign-out, no login screen. The browser goes to
  /// Google and comes back to this page with the session restored.
  Future<void> connectGoogle() async {
    final b = bridge as GoogleConnectBridge;
    final attempt = ++revision;
    setState(() {
      busy = true;
      message = '';
    });
    var left = false;
    try {
      final reason = await b.connectGoogle();
      if (!mounted || attempt != revision) return;
      left = reason.isEmpty;
      if (!left) {
        setState(
          () => message = switch (reason) {
            'already_linked' => 'Google is already connected.',
            'no_passkey' => 'Add a passkey first, then you can connect Google.',
            'retry' => 'Too many tries. Wait a little and try again.',
            'signin' => 'Browser access expired. Sign in again.',
            _ => 'Could not start Google. Try again.',
          },
        );
      }
    } catch (_) {
      if (mounted && attempt == revision) {
        setState(() => message = 'Could not start Google. Try again.');
      }
    } finally {
      // While the browser is leaving, keep the button busy.
      if (mounted && attempt == revision && !left) {
        setState(() => busy = false);
      }
    }
  }

  void showGoogleLinkResult() {
    final result = pendingLinkResult;
    pendingLinkResult = '';
    final text = switch (result) {
      // The account overview owns whether Google is connected. The notice
      // only reports, so it never claims more than the overview shows.
      'connected' =>
        overview?['google'] == true
            // The Passkeys screen has nothing to do with Google.
            ? (passkeysOpen ? '' : 'Google connected.')
            : 'Could not confirm that Google is connected. Check below.',
      'restart' => 'Google was not connected. Try again.',
      'mismatch' => 'That Google account does not use this account\'s email, so it was not connected.',
      _ => '',
    };
    if (text.isNotEmpty) message = text;
  }

  Future<void> refresh() => run(() async {
    await loadAccount(revision);
  }, loadAfter: false);
  Future<void> fetchOverview(int attempt) async {
    if (overviewInFlightRevision == attempt) return;
    overviewInFlightRevision = attempt;
    overviewAttempted = true;
    final SessionResponse info;
    try {
      info = await bridge.read('/v1/manage/account');
    } finally {
      if (overviewInFlightRevision == attempt) overviewInFlightRevision = -1;
    }
    if (!mounted || attempt != revision || status != 'restored') return;
    if (info.status == 401) {
      workspace.clear();
      bridge.clear();
      clearOrganization();
      store.clear();
      status = 'sign-in-required';
      message = 'Browser access expired. Sign in again.';
      return;
    }
    if (info.status != 200) {
      if (overview != null) overviewStale = true;
      return;
    }
    final v = jsonDecode(info.body);
    if (v is Map<String, dynamic> &&
        v['email'] is String &&
        v['passkeys'] is int &&
        v['google'] is bool &&
        v['recoveryDevices'] is int) {
      overview = v;
      overviewStale = false;
      overviewFetchedAt = DateTime.now();
      final owner = sessionOwner, key = sessionKey;
      if (bridge is ProfileCacheBridge &&
          owner != null &&
          key != null &&
          bridge.status == 'restored') {
        (bridge as ProfileCacheBridge).profileWrite(
          owner,
          key,
          v['email'] as String,
          v['picture'] is String ? v['picture'] as String : null,
        );
      }
    } else if (overview != null) {
      // A 200 with the wrong shape is a failed refresh, not a new status.
      overviewStale = true;
    }
  }

  /// The account page just appeared without an overview (its header came from
  /// the cache): fetch it once.
  Future<void> ensureOverview() async {
    // Restoration may have fetched for this exact appearance before the
    // page mounted. Consume that attempt once, including a failed attempt.
    // Never carry it into a later appearance or use a time-based throttle.
    final prepared = overviewPreparedRevision == revision;
    overviewPreparedRevision = null;
    if (prepared && overview != null) return;
    if (overview != null && status == 'restored' && mounted) {
      // Already held but possibly old: the Account page shows security
      // status, so read it again without the loading bar.
      if (overviewInFlightRevision == revision) return;
      overviewFetchedAt = null;
      final attempt = revision;
      try {
        await fetchOverview(attempt);
      } catch (_) {
        if (mounted && attempt == revision) overviewStale = true;
      }
      overviewFetchedAt = null;
      if (mounted) setState(() {});
      drainOverviewAgain(attempt);
      return;
    }
    if (overview != null ||
        overviewLoading ||
        overviewInFlightRevision == revision ||
        overviewAttempted ||
        !mounted ||
        status != 'restored' ||
        sessionOwner == null) {
      return;
    }
    final attempt = revision;
    setState(() => overviewLoading = true);
    try {
      await fetchOverview(attempt);
    } catch (_) {
    } finally {
      if (mounted) setState(() => overviewLoading = false);
      drainOverviewAgain(attempt);
    }
  }

  Future<void> loadAccount(int attempt) async {
    if (widget.workspaceEnabled && !accountOpen) {
      await workspace.refresh();
      if (workspace.sessionEnded) {
        status = 'sign-in-required';
        resetIdentity();
        return;
      }
    }
    if (!mounted || attempt != revision || bridge.status != 'restored') return;
    final response = await bridge.read('/v1/manage/session');
    if (!mounted || attempt != revision) return;
    if (response.status == 401) {
      bridge.clear();
      status = 'sign-in-required';
      return;
    }
    if (response.status != 200) {
      if (widget.workspaceEnabled && !accountOpen) return;
      throw const ClientFailure();
    }
    final value = jsonDecode(response.body);
    if (value is! Map<String, dynamic> ||
        value.keys.length != 2 ||
        value['ownerId'] is! String ||
        (value['ownerId'] as String).isEmpty ||
        (value['ownerId'] as String).length > 256 ||
        value['expiresAt'] is! int ||
        (value['expiresAt'] as int) <= now()) {
      throw const FormatException('Invalid session metadata');
    }
    accountExpiresAt = value['expiresAt'] as int;
    final cache = bridge is ProfileCacheBridge
        ? bridge as ProfileCacheBridge
        : null;
    final owner = value['ownerId'] as String;
    // The opt-in identity view. Any failure (old API, 400, bad shape, another
    // owner) means no cache; the account page works without it.
    String? sid;
    if (cache != null) {
      try {
        final r = await bridge.read('/v1/manage/session?view=cache-v1');
        if (!mounted || attempt != revision || status != 'restored') return;
        final v = r.status == 200 ? jsonDecode(r.body) : null;
        if (v is Map<String, dynamic> &&
            v.keys.length == 3 &&
            v['ownerId'] == owner &&
            v['expiresAt'] is int &&
            v['sessionId'] is String &&
            sessionIdPattern.hasMatch(v['sessionId'] as String)) {
          sid = v['sessionId'] as String;
        }
      } catch (_) {}
    }
    if (sessionOwner != owner || sessionKey != sid) {
      // Another account or another sign-in: nothing from before may show.
      workspace.resetSources();
      cachedProfile = null;
      overview = null;
      overviewAttempted = false;
    }
    sessionOwner = owner;
    sessionKey = sid;
    if (cache != null && sessionKey != null && cachedProfile == null) {
      cachedProfile = cache.profileRevoked
          ? null
          : parseCachedProfile(cache.profileRead(owner, sessionKey!));
      if (mounted && attempt == revision && cachedProfile != null) {
        setState(() {});
      }
    }
    // The overview is only needed where the account page shows, or to refresh
    // a copy older than a day. A fresh cached header needs no request.
    // Security status (passkeys, Google, recovery) is read live whenever the
    // Account page shows, so a copy already held needs no read on open.
    final categoryDoesNotNeedOverview =
        widget.navigation != null &&
        (accountOpen || !widget.workspaceEnabled) &&
        settingsCategory != SettingsCategory.account;
    final skip =
        !forceOverview &&
        (categoryDoesNotNeedOverview ||
            accountPagesShown == 0 &&
                (overview != null ||
                    cachedProfile?.isFresh(
                          DateTime.now().millisecondsSinceEpoch,
                        ) ==
                        true));
    if (!skip) {
      if (widget.workspaceEnabled && !accountOpen) {
        try {
          await fetchOverview(attempt);
        } catch (_) {
          // The avatar is optional; keep the usable workspace on read failure.
        }
      } else {
        await fetchOverview(attempt);
        if (mounted &&
            attempt == revision &&
            accountPagesShown == 0 &&
            settingsCategory == SettingsCategory.account &&
            !passkeysOpen) {
          overviewPreparedRevision = overview != null && !overviewStale
              ? attempt
              : null;
        }
      }
    }
    if (!skip) forceOverview = false;
    if (!mounted || attempt != revision || status != 'restored') return;
  }

  /// Live organization feeding the unified workspace. Never edit a stale copy
  /// while a reload is about to replace it.
  Future<void> loadOrganizationSection([int? attempt]) async {
    final mine = attempt ?? revision;
    if (!mounted || status != 'restored' || organizationBusy) return;
    // No editable copy while the live one loads: edits made on a copy that
    // is about to be replaced would be lost.
    setState(() {
      organizationBusy = true;
      organizationReady = false;
    });
    try {
      if (!widget.workspaceEnabled) {
        await store.load(now, includePrivateInbox: true);
      }
      if (mounted && mine == revision && bridge.status == 'restored') {
        await loadOrganization();
      }
    } catch (_) {
      organizationReady = false;
    } finally {
      if (mounted) setState(() => organizationBusy = false);
    }
  }

  void listenSecurity({bool catchUp = true}) {
    if (securityUnsubscribe != null ||
        !mounted ||
        status != 'restored' ||
        bridge is! AuthEntryBridge ||
        bridge is! RealtimeBridge) {
      return;
    }
    securityUnsubscribe = (bridge as RealtimeBridge).realtimeSubscribe(
      onSecurityHint,
    );
    // An already-open socket sends no new 'connect', so close the gap between
    // the entry read and this subscription with one coalesced catch-up.
    if (catchUp && (securityLoading || securityInfo != null)) {
      securityTrailing = true;
      drainSecurityHint();
    }
  }

  void stopSecurityListening() {
    final stop = securityUnsubscribe;
    securityUnsubscribe = null;
    securitySpacing?.cancel();
    securitySpacing = null;
    securityCooling = false;
    securityTrailing = false;
    stop?.call();
  }

  /// 'connect' (after every socket open) closes the gap while disconnected;
  /// 'changed' is a server hint. Nothing is fetched on a timer.
  void onSecurityHint(String reason) {
    if (!mounted || accountPagesShown <= 0 || status != 'restored') return;
    if (reason != 'connect' && reason != 'changed') return;
    securityTrailing = true;
    drainSecurityHint();
  }

  bool overviewAgain = false;

  void drainOverviewAgain(int attempt) {
    if (!mounted ||
        attempt != revision ||
        status != 'restored' ||
        busy ||
        overviewInFlightRevision != -1 ||
        !overviewAgain) {
      return;
    }
    overviewAgain = false;
    unawaited(refreshOverviewQuietly());
  }

  /// Hint-driven overview read. It never sets busy and never overlaps a user
  /// action (run() reloads the account itself) or another overview read; a hint
  /// that lands meanwhile earns one trailing read.
  Future<void> refreshOverviewQuietly() async {
    if (!mounted || status != 'restored') return;
    if (busy || overviewInFlightRevision != -1) {
      overviewAgain = true;
      return;
    }
    try {
      await fetchOverview(revision);
      if (mounted) setState(() {});
    } catch (_) {
      // Keep the last view; the next hint or entry retries.
    }
    if (overviewAgain && mounted && !busy) {
      overviewAgain = false;
      unawaited(refreshOverviewQuietly());
    }
  }

  void drainSecurityHint() {
    if (!securityTrailing || !mounted) return;
    if (accountPagesShown <= 0 || status != 'restored') {
      securityTrailing = false;
      return;
    }
    if (securityLoading) return; // loadSecurity drains again when it finishes
    if (securityCooling) return; // the spacing timer drains again
    securityCooling = true;
    securitySpacing = Timer(const Duration(seconds: 1), () {
      securitySpacing = null;
      securityCooling = false;
      drainSecurityHint();
    });
    securityTrailing = false;
    // A hint also means the overview or organization may have changed. The
    // overview reload is quiet: no busy state, no disabled controls.
    unawaited(refreshOverviewQuietly());
    if (accountOpen &&
        !organizationReady &&
        !organizationBusy &&
        widget.navigation == null) {
      unawaited(loadOrganizationSection());
    }
    unawaited(refreshSecurity().then((_) => drainSecurityHint()));
  }

  /// Rows of the security status that have not reached their own expiresAt. The
  /// server writes nothing at expiry, so the page hides them by the clock.
  List<Map> liveSecurityRows(String key) => [
    for (final raw in (securityInfo?[key] as List? ?? const []))
      if (raw is Map &&
          (raw['expiresAt'] is! int || (raw['expiresAt'] as int) > now()))
        raw,
  ];

  Future<void> refreshSecurity() async {
    try {
      await loadSecurity();
    } catch (_) {
      // Keep the last view; the next automatic check retries without changing
      // account settings or approving a request.
    }
  }

  Future<void> loadSecurity() async {
    if (bridge is! AuthEntryBridge || securityLoading || status != 'restored') {
      return;
    }
    final epoch = organizationEpoch;
    // The very first read subscribes before it starts, so a hint during it is
    // not lost and the later entry subscription needs no duplicate catch-up.
    if (securityInfo == null || accountPagesShown > 0) {
      listenSecurity(catchUp: false);
    }
    securityLoading = true;
    securityFailed = false;
    try {
      final value = jsonDecode(
        await (bridge as AuthEntryBridge).security('status'),
      );
      if (!mounted ||
          epoch != organizationEpoch ||
          bridge.status != 'restored') {
        return;
      }
      if (value is! Map<String, dynamic> ||
          value['enabled'] is! bool ||
          value['pending'] is! List ||
          value['changes'] is! List) {
        throw const FormatException('Invalid security state');
      }
      setState(() {
        securityInfo = value;
        securityFailed = false;
        securityOpen = true;
      });
    } catch (_) {
      if (mounted && epoch == organizationEpoch && status == 'restored') {
        setState(() => securityFailed = true);
      }
      rethrow;
    } finally {
      securityLoading = false;
      if (securityTrailing) drainSecurityHint();
    }
  }

  bool get clientApprovalAvailable =>
      bridge is RecoveryBridge &&
      (bridge as RecoveryBridge).enrolledClientApprovalAvailable;

  Future<void> changeSecurity(bool enabled, bool otherClient) async {
    if (otherClient && !clientApprovalAvailable) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        constraints: settingsDialogConstraints,
        title: Text(
          enabled
              ? 'Require extra verification?'
              : 'Turn off extra verification?',
        ),
        content: Text(
          enabled
              ? 'On new devices, Google alone will no longer be enough. You will need a passkey. Losing every passkey can lock you out. Approval from another enrolled device is not available yet. Remembered devices do not need this extra step.'
              : 'Google alone will be enough on new devices again. Verify this change with your passkey.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(enabled ? 'Continue' : 'Turn off'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await run(() async {
      final b = bridge as AuthEntryBridge;
      if (otherClient) {
        final value = jsonDecode(await b.security('request-change', enabled));
        settingChange = value['changeId'] as String;
        message = 'Open Security on your other device to approve this exact change, then check here.';
      } else {
        await b.security('toggle', enabled);
      }
      await loadSecurity();
    });
  }

  /// Forgets everything identity-related held in this tab.
  /// Throws away the static identity (memory and stored copy) and the overview,
  /// so nothing stale shows while a Google change is checked against the server.
  void dropStaticProfile() {
    cachedProfile = null;
    overview = null;
    overviewAttempted = false;
    final Object b = bridge;
    if (b is ProfileCacheBridge) b.profileClear();
  }

  String pendingLinkResult = '';
  bool forceOverview = false;

  void resetIdentity() {
    overviewAgain = false;
    overviewPreparedRevision = null;
    cachedProfile = null;
    overview = null;
    sessionOwner = null;
    sessionKey = null;
    overviewAttempted = false;
    overviewStale = false;
    overviewFetchedAt = null;
  }

  void clearOrganization() {
    accountExpiresAt = null;
    resetIdentity();
    securityInfo = null;
    securityRequested = false;
    securityFailed = false;
    stopSecurityListening();
    settingChange = null;
    organizationEpoch++;
    organizationRequest++;
    organization.clear();
    organizationReady = false;
    organizationBusy = false;
  }

  Future<void> loadOrganization() async {
    final epoch = organizationEpoch;
    final request = ++organizationRequest;
    final response = await bridge.organize('GET', '');
    if (!mounted ||
        epoch != organizationEpoch ||
        request != organizationRequest) {
      return;
    }
    if (response.status == 401) {
      workspace.clear();
      bridge.clear();
      clearOrganization();
      store.clear();
      status = 'sign-in-required';
      return;
    }
    if (response.status != 200) {
      organizationReady = false;
      return;
    }
    try {
      final document = jsonDecode(response.body) as Map<String, dynamic>;
      // Keep preferences for ids absent from the current entry snapshot.
      // A partial view must never become a destructive replacement PUT.
      final retained = (document['entries'] as List)
          .whereType<Map>()
          .map((e) => e['entryId'])
          .whereType<String>();
      organization.restore(document, {
        ...(widget.workspaceEnabled ? workspace.store : store).entries.map(
          (e) => e.id,
        ),
        ...retained,
      });
      organizationSnapshot++;
      organizationReady = true;
    } catch (_) {
      organizationReady = false;
    }
  }

  Future<bool> saveOrganization() async {
    if (!organizationReady || organizationBusy || status != 'restored') {
      return false;
    }
    final epoch = organizationEpoch;
    setState(() => organizationBusy = true);
    try {
      final response = await bridge.organize(
        'PUT',
        jsonEncode({
          'revision': organization.revision,
          'document': organization.document(),
        }),
      );
      if (!mounted || epoch != organizationEpoch) return false;
      if (response.status != 200) message = 'Organization was not saved. Checking your saved choices automatically.';
      await loadOrganization();
      return response.status == 200 && organizationReady;
    } catch (_) {
      if (!mounted || epoch != organizationEpoch) return false;
      organizationReady = false;
      message = 'Could not confirm tags. Reopen Codes to check your saved tags before editing again.';
      rethrow;
    } finally {
      if (mounted && epoch == organizationEpoch) {
        setState(() => organizationBusy = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (widget.workspaceEnabled && !accountOpen) {
        workspace.resume();
        unawaited(workspace.refresh());
      }
      unawaited(maintainSession());
      if (securityRequested && accountPagesShown > 0 && status == 'restored') {
        unawaited(refreshSecurity());
      }
    }
    // Focus changes do not end the session or discard valid records. Per-code
    // expiry is still enforced by the live clock and before copying.
  }

  @override
  void dispose() {
    revision++;
    workspace.removeListener(workspaceChanged);
    workspace.dispose();
    expiryTick?.cancel();
    stopSecurityListening();
    clearOrganization();
    store.clear();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> assignPrivate(UnassignedCode code) async {
    if (!widget.assignmentEnabled ||
        bridge is! AssignmentBridge ||
        status != 'restored' ||
        !code.active(now())) {
      return;
    }
    final assignment = bridge as AssignmentBridge;
    if ([
      'unknown',
      'pending',
      'submitting',
    ].contains(assignment.assignmentState)) {
      final assigned = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AssignmentDialog(
          bridge: assignment,
          sourceId: '',
          eventId: '',
          entryId: '',
        ),
      );
      if (mounted && assigned == true) workspace.refreshAfterMutation();
      return;
    }
    final epoch = revision;
    final owned = store.entries.where((entry) => entry.manage).toList();
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        constraints: const BoxConstraints(maxWidth: 400),
        title: const Text('Choose an owned entry'),
        children: [
          for (final entry in owned)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.id),
              child: Text(
                '${entry.service}${entry.account.isEmpty ? '' : ' · ${entry.account}'}',
              ),
            ),
        ],
      ),
    );
    if (!mounted ||
        target == null ||
        epoch != revision ||
        status != 'restored' ||
        !code.active(now()) ||
        !store.visibleUnassigned(now()).contains(code) ||
        !store.entries.any((entry) => entry.id == target && entry.manage)) {
      return;
    }
    final assigned = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AssignmentDialog(
        bridge: bridge as AssignmentBridge,
        sourceId: code.sourceId,
        eventId: code.eventId,
        entryId: target,
      ),
    );
    if (mounted && assigned == true) workspace.refreshAfterMutation();
  }

  Future<void> copyPrivate(UnassignedCode code) async {
    if (status != 'restored' ||
        !code.active(now()) ||
        !store.visibleUnassigned(now()).contains(code)) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: code.value));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Code copied. Other apps may retain clipboard contents.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not copy code.')));
      }
    }
  }

  Future<void> copyAssigned(ReceivedCode code) async {
    final epoch = organizationEpoch;
    if (status != 'restored' || !store.visibleCodes(now()).contains(code)) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: code.value));
      if (mounted &&
          epoch == organizationEpoch &&
          status == 'restored' &&
          store.visibleCodes(now()).contains(code)) {
        try {
          await bridge.copied(code.entryId, now());
          if (mounted && epoch == organizationEpoch) {
            await loadOrganization();
            if (mounted && epoch == organizationEpoch) setState(() {});
          }
        } catch (_) {
          /* Clipboard success does not depend on ranking sync. */
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Code copied. Other apps may retain clipboard contents.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not copy code.')));
      }
    }
  }

  void signOutBrowser() {
    revision++;
    clearOrganization();
    workspace.clear();
    store.clear();
    try {
      bridge.logout();
      message = 'Signing out...';
    } catch (_) {
      message = 'Could not open signout. Local access is cleared but the saved browser session is not revoked.';
    }
    setState(() {
      status = bridge.status;
      busy = false;
    });
  }

  Widget sectionTitle(String t) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Text(
      t,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    ),
  );

  /// Cards size to their content. Loading rows show a skeleton in place of
  /// each value, so the height does not depend on whether data has arrived.
  Widget stableSettingsCard(String title, List<Widget> children) =>
      settingsCard(title, children);

  bool get _canFirstPasskey =>
      overview?['passkeys'] == 0 &&
      bridge is FirstPasskeyBridge &&
      (bridge as FirstPasskeyBridge).firstPasskeyAvailable;

  bool get _canAddPasskey =>
      overview != null &&
      (_canFirstPasskey ||
          ((overview!['passkeys'] as int) > 0 &&
              bridge is AdditionalPasskeyBridge));

  Future<void> addPasskey() => run(() async {
    if (_canFirstPasskey) {
      await (bridge as FirstPasskeyBridge).firstPasskey();
    } else {
      await (bridge as AdditionalPasskeyBridge).addPasskey();
    }
    await loadAccount(revision);
  });

  bool get _hasPasskey {
    final n = overview?['passkeys'];
    return n is int && n >= 1;
  }

  bool get _canDisconnectGoogle =>
      bridge is GoogleLinkBridge &&
      (bridge as GoogleLinkBridge).googleDisconnectAvailable;

  Future<void> disconnectGoogle() async {
    final passkeys = overview?['passkeys'];
    if (passkeys is! int) return;
    // Never offered without a passkey (the button is disabled); a stale tap
    // does nothing either. The server enforces the same rule.
    if (passkeys < 1) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        constraints: settingsDialogConstraints,
        title: const Text('Disconnect Google?'),
        content: const Text(
          'Devices signed in with Google are signed out, including this one if you signed in with Google. Sign-ins with a passkey stay signed in, and your Gmail connections are not affected. You can connect Google again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    var result = 'Google disconnected. You sign in with your passkeys.';
    var refused = false;
    try {
      await (bridge as GoogleLinkBridge).disconnectGoogle();
    } on RecoveryRefused {
      refused = true;
    } catch (_) {
      // Anything else could have committed. Never claim it did not.
      result = 'We could not confirm that. Google may have been disconnected. Check below before trying again.';
    }
    if (!mounted) return;
    // The picture may be gone: forget the static copy before the fresh read.
    setState(dropStaticProfile);
    await refresh();
    if (!mounted) return;
    if (refused) {
      // A refusal is generic (a cancelled passkey check, a stale change, or
      // nothing left to disconnect). The fresh account state says which.
      result = overview?['google'] != true
          ? 'Google is already disconnected.'
          : !_hasPasskey
          ? 'Add a passkey first, then you can disconnect Google.'
          : 'Google was not disconnected. Try again if you still want to.';
    }
    setState(() => message = result);
  }

  Widget signInMethods() {
    final o = overview;
    final loading = o == null;
    final google = o?['google'];
    final passkeys = o?['passkeys'];
    return stableSettingsCard('Sign-in methods', [
      ListTile(
        key: const Key('settings-passkeys-row'),
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Passkeys',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: loading
            ? const RedactedText('0 registered')
            : Text('$passkeys registered'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          setState(() {
            passkeysOpen = true;
            message = '';
          });
          navigated(settingsPasskeysRoute);
        },
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Google',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: context.pal.ink,
                    ),
                  ),
                  loading
                      ? const RedactedText('Connected')
                      : Text(
                          google != true
                              ? 'Not connected'
                              : _hasPasskey
                              ? 'Connected'
                              : 'Connected. Add a passkey to disconnect.',
                          style: TextStyle(color: context.pal.muted),
                        ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (loading)
              // Invisible, but as tall as the real button, so the row does
              // not change height when the status arrives.
              ExcludeSemantics(
                child: Opacity(
                  opacity: 0,
                  child: OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect'),
                  ),
                ),
              )
            else if (google == true)
              if (_canDisconnectGoogle)
                OutlinedButton.icon(
                  onPressed: busy || !_hasPasskey ? null : disconnectGoogle,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                )
              else
                const SizedBox(height: 40)
            else if (bridge is GoogleConnectBridge &&
                (bridge as GoogleConnectBridge).googleConnectAvailable)
              OutlinedButton.icon(
                onPressed: busy ? null : connectGoogle,
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              )
            else
              // A signed-in bridge without the signed-in connect never falls
              // back to the signed-out Google sign-in, which would log out.
              ExcludeSemantics(
                child: Opacity(
                  opacity: 0,
                  child: OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect'),
                  ),
                ),
              ),
          ],
        ),
      ),
      if (!loading &&
          passkeys == 0 &&
          google == true &&
          (bridge is! FirstPasskeyBridge ||
              !(bridge as FirstPasskeyBridge).firstPasskeyAvailable))
        OutlinedButton.icon(
          onPressed: busy ? null : () => run(() => bridge.start('google')),
          icon: const Icon(Icons.login),
          label: const Text('Sign in with Google again to add a passkey'),
        ),
    ]);
  }

  List<Widget> protectionItems() {
    if (bridge is! AuthEntryBridge) return const [];
    return [
      if (securityInfo == null && securityFailed)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Extra verification on new devices'),
          subtitle: const Text('Verification settings could not load.'),
          trailing: TextButton(
            onPressed: securityLoading ? null : refreshSecurity,
            child: const Text('Retry'),
          ),
        )
      else if (securityInfo == null)
        const SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Extra verification on new devices'),
          subtitle: StableText(shown: null, versions: _verificationCopy),
          value: false,
          onChanged: null,
        )
      else ...[
        if (securityFailed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Verification settings could not refresh.'),
            subtitle: const Text('The last checked state is shown.'),
            trailing: TextButton(
              onPressed: securityLoading ? null : refreshSecurity,
              child: const Text('Retry'),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Extra verification on new devices'),
          subtitle: StableText(
            shown: securityInfo!['enabled'] == true
                ? _verificationCopy[0]
                : _verificationCopy[1],
            versions: _verificationCopy,
          ),
          value: securityInfo!['enabled'] as bool,
          onChanged: busy ? null : (enabled) => changeSecurity(enabled, false),
        ),
        if (clientApprovalAvailable)
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () =>
                      changeSecurity(!(securityInfo!['enabled'] as bool), true),
            icon: const Icon(Icons.devices),
            label: const Text('Verify change with another signed-in device'),
          ),
        if (clientApprovalAvailable && settingChange != null)
          OutlinedButton(
            onPressed: busy
                ? null
                : () => run(() async {
                    await (bridge as AuthEntryBridge).security(
                      'consume-change',
                      false,
                      settingChange!,
                    );
                    settingChange = null;
                    await loadSecurity();
                  }),
            child: const Text('Check approval for security change'),
          ),
        for (final raw in liveSecurityRows('pending'))
          if (raw['pendingId'] is String)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('New-device sign-in request'),
                    Text(
                      'Match code: ${(raw['pendingId'] as String).substring(0, (raw['pendingId'] as String).length < 6 ? (raw['pendingId'] as String).length : 6).toUpperCase()}',
                    ),
                    Text(
                      'Requested at ${DateTime.fromMillisecondsSinceEpoch(raw['createdAt'] as int).toLocal()}',
                    ),
                    const Text(
                      'Approve with a passkey on the device where you started this sign-in. Approval here from an enrolled device is not available yet.',
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
                        if (clientApprovalAvailable)
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => run(() async {
                                    await (bridge as AuthEntryBridge).security(
                                      'approve',
                                      false,
                                      raw['pendingId'] as String,
                                    );
                                    await loadSecurity();
                                  }),
                            icon: const Icon(Icons.check),
                            label: const Text('Approve sign-in'),
                          ),
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () => run(() async {
                                  await (bridge as AuthEntryBridge).security(
                                    'deny',
                                    false,
                                    raw['pendingId'] as String,
                                  );
                                  await loadSecurity();
                                }),
                          icon: const Icon(Icons.close),
                          label: const Text('Deny'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        if (clientApprovalAvailable)
          for (final raw in liveSecurityRows('changes'))
            if (raw['changeId'] is String)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        raw['enabled'] == true
                            ? 'Turn extra verification ON?'
                            : 'Turn extra verification OFF?',
                      ),
                      const Text(
                        'Approve only if you requested this exact change on your other device.',
                      ),
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await (bridge as AuthEntryBridge).security(
                                  'approve-change',
                                  false,
                                  raw['changeId'] as String,
                                );
                                await loadSecurity();
                              }),
                        icon: const Icon(Icons.verified_user_outlined),
                        label: const Text('Approve security change'),
                      ),
                    ],
                  ),
                ),
              ),
      ],
    ];
  }

  RecoveryBridge? get _recovery =>
      bridge is RecoveryBridge && (bridge as RecoveryBridge).recoveryAvailable
      ? bridge as RecoveryBridge
      : null;

  Widget accountSecurityPage() {
    final r = _recovery;
    final items = protectionItems();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (overviewStale && overview != null)
          const Padding(
            key: Key('overview-stale'),
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Could not refresh. What is shown may be out of date.'),
          ),
        signInMethods(),
        if (r != null)
          RecoveryPanel(
            bridge: r,
            sections: const {RecoverySection.emailRecovery},
            beforeEmailRecovery: items.isEmpty ? null : Column(children: items),
            sectionCard: stableSettingsCard,
          )
        else if (items.isNotEmpty)
          stableSettingsCard('Protection', items),
      ],
    );
  }

  Widget passkeysPage() {
    final r = _recovery;
    return r == null
        ? settingsCard('Passkeys', const [
            Text('Passkeys could not load here.'),
          ])
        : RecoveryPanel(
            bridge: r,
            sections: const {RecoverySection.passkeys},
            sectionCard: (title, children) => Padding(
              padding: const EdgeInsets.only(bottom: 72),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          );
  }

  /// The signed-in devices as a plain list that fills the screen and
  /// scrolls. Sign out lives at the bottom of the main settings list.
  Widget devicesPage() {
    final r = _recovery;
    if (r == null) return const SizedBox.shrink();
    return RecoveryPanel(
      bridge: r,
      sections: const {RecoverySection.devices},
      sectionCard: (title, children) => Expanded(
        child: ListView(
          key: const Key('devices-list'),
          padding: EdgeInsets.zero,
          children: children,
        ),
      ),
    );
  }

  Widget? settingsFooter() {
    if (status == 'unsupported' ||
        !(widget.signOutEnabled ?? widget.loginEnabled)) {
      return null;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: OutlinedButton.icon(
        key: const Key('browser-sign-out'),
        onPressed: busy ? null : signOutBrowser,
        icon: const Icon(Icons.logout),
        label: const Text('Sign out'),
      ),
    );
  }

  Widget settingsScaffold() {
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > settingsWideBreakpoint;
        final inCategory = !wide && settingsCategory != null;
        return Scaffold(
          floatingActionButton: passkeysOpen && _canAddPasskey
              ? FloatingActionButton.extended(
                  key: const Key('add-passkey-fab'),
                  onPressed: busy ? null : addPasskey,
                  icon: const Icon(Icons.add),
                  label: const Text('Add passkey'),
                )
              : null,
          appBar: AppBar(
            leading: passkeysOpen
                ? IconButton(
                    tooltip: 'Back to account and security',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      setState(() => passkeysOpen = false);
                      navigated(SettingsCategory.account.route);
                    },
                  )
                : inCategory
                ? IconButton(
                    tooltip: 'Back to settings',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      setState(() => settingsCategory = null);
                      navigated(settingsHubRoute);
                    },
                  )
                : widget.workspaceEnabled
                ? IconButton(
                    tooltip: 'Back to codes',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: leaveSettings,
                  )
                : null,
            title: Text(
              passkeysOpen
                  ? 'Passkeys'
                  : inCategory
                  ? settingsCategory!.title
                  : 'Settings',
            ),
          ),
          body: Column(
            children: [
              // Always 4px tall, so content does not shift when it appears.
              SizedBox(
                height: 4,
                child: busy ? const LinearProgressIndicator() : null,
              ),
              if (message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(message),
                ),
              Expanded(
                child: SettingsHub(
                  fillPages: const {
                    SettingsCategory.devices,
                    SettingsCategory.sharing,
                    SettingsCategory.transfer,
                  },
                  footer: settingsFooter(),
                  email: overview?['email'] as String? ?? cachedProfile?.email,
                  emailLoading:
                      overview == null &&
                      cachedProfile == null &&
                      (busy || overviewLoading),
                  googlePicture: overview != null
                      ? (overview!['picture'] is String
                            ? overview!['picture'] as String
                            : null)
                      : cachedProfile?.picture,
                  selected: settingsCategory,
                  onSelect: (c) {
                    setState(() {
                      settingsCategory = c;
                      passkeysOpen = false;
                    });
                    navigated(c.route);
                    if (c != SettingsCategory.account) {
                      overviewPreparedRevision = null;
                    }
                  },
                  pages: {
                    SettingsCategory.account: _WhenShown(
                      onShown: () {
                        accountPagesShown++;
                        ensureOverview();
                        if (!securityRequested) {
                          securityRequested = true;
                          unawaited(refreshSecurity());
                        }
                        // The first status read starts above only when shown.
                        // Returning listens and catches up without a second first read.
                        listenSecurity();
                        if (securityInfo != null &&
                            status == 'restored' &&
                            securityUnsubscribe == null) {
                          unawaited(refreshSecurity());
                        }
                      },
                      onHidden: () {
                        overviewPreparedRevision = null;
                        overviewAttempted = false;
                        accountPagesShown--;
                        if (accountPagesShown <= 0) stopSecurityListening();
                      },
                      child: passkeysOpen
                          ? passkeysPage()
                          : widget.localSecuritySetting == null
                          ? accountSecurityPage()
                          : Column(
                              children: [
                                if (widget.localSecuritySetting != null)
                                  widget.localSecuritySetting!,
                                accountSecurityPage(),
                              ],
                            ),
                    ),
                    SettingsCategory.devices: devicesPage(),
                    SettingsCategory.sources: SourceSettings(
                      key: ValueKey((sessionOwner, sessionKey)),
                      controller: workspace,
                      onOpenAccount: () =>
                          navigated(SettingsCategory.account.route),
                    ),
                    SettingsCategory.display: DisplaySettings(
                      preference: tileDisplay,
                    ),
                    SettingsCategory.about: const AboutPage(),
                    if (sharingClient != null)
                      SettingsCategory.sharing: SharingPage(
                        key: ValueKey(sharingIdentity),
                        client: sharingClient!,
                        entries: workspace.store.entries
                            .where((e) => e.manage)
                            .toList(),
                      ),
                    SettingsCategory.transfer:
                        widget.transferPageBuilder?.call(
                          workspace.importDuplicateKeys,
                          workspace.refresh,
                        ) ??
                        widget.transferPage ??
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Transfer codes is not available on this client yet.',
                          ),
                        ),
                  },
                ),
              ),
              if (organizationBusy) const LinearProgressIndicator(),
            ],
          ),
        );
      },
    );
  }

  static const _recoveryStages = {
    'recovery': LostAccessStage.choose,
    'recovery/start': LostAccessStage.startEmail,
    'recovery/finish': LostAccessStage.finishEmail,
  };

  @override
  Widget build(BuildContext context) {
    // View-only lost-access routes. They work signed out and carry nothing
    // but the step: every send, verify and finish stays an explicit button
    // inside the page itself.
    final stage = _recoveryStages[widget.navigation];
    if (stage != null &&
        bridge is RecoveryBridge &&
        (bridge as RecoveryBridge).recoveryAvailable) {
      return LostAccessPage(
        key: ValueKey(widget.navigation),
        bridge: bridge as RecoveryBridge,
        initialStage: stage,
        onNavigate: widget.onNavigate,
        onExit: widget.onNavigate == null ? null : () => navigated('codes'),
      );
    }
    if (const bool.fromEnvironment('SHARING_ENABLED') &&
        widget.navigation == 'invite' &&
        bridge is SharingInviteBridge &&
        status == 'restored') {
      final host = bridge as SharingInviteBridge;
      return Scaffold(
        body: SharingAcceptPage(
          key: ValueKey((sessionOwner, sessionKey, 'host-invite')),
          pending: host.invitePending,
          consumeOnce: true,
          acceptPending: () async {
            final r = await host.acceptPendingInvite();
            if ([400, 401, 403, 404, 429].contains(r.status)) {
              throw ClientFailure(r.status);
            }
            if (r.status != 200) throw const MutationUnconfirmed();
            final v = jsonDecode(r.body);
            if (v is! Map || v['ok'] != true || v['canDelegate'] is! bool) {
              throw const MutationUnconfirmed();
            }
            final mode = AccessMode.values
                .where((m) => m.name == v['mode'])
                .firstOrNull;
            if (mode == null) throw const MutationUnconfirmed();
            return InviteAccepted(mode, v['canDelegate'] as bool);
          },
          onOpenCodes: () {
            host.dismissInvite();
            setState(() => applyRoute('codes'));
            workspace.resume();
            workspace.refreshAfterMutation(showUpdating: true);
            navigated('codes');
          },
        ),
      );
    }
    if (isExtensionPopup(bridge)) {
      return ExtensionPopupView(bridge: bridge, clock: widget.clock);
    }
    if (widget.workspaceEnabled &&
        ['restored', 'session-paused', 'restoring'].contains(status) &&
        !accountOpen) {
      return ProductShell(
        importSaver: widget.importSaver,
        navigation: widget.navigation,
        onNavigate: widget.onNavigate,
        organization: organizationReady ? organization : null,
        organizationBusy: organizationBusy,
        organizationMessage: message,
        onOrganizationChanged: () {
          unawaited(saveOrganization().catchError((Object _) => false));
        },
        saveOrganization: saveOrganization,
        showTileTags: tileDisplay.showTags,
        profileEmail: overview?['email'] as String? ?? cachedProfile?.email,
        profilePicture: overview != null
            ? (overview!['picture'] is String
                  ? overview!['picture'] as String
                  : null)
            : cachedProfile?.picture,
        assignmentEnabled: widget.assignmentEnabled,
        entryEditEnabled: widget.entryEditEnabled,
        entryDomainsEnabled: widget.entryDomainsEnabled,
        controller: workspace,
        batchPolicy:
            const bool.fromEnvironment(
              'OTPANDA_BATCH_ENABLED',
              defaultValue: true,
            )
            ? const BatchPolicy(
                maxEntries: int.fromEnvironment(
                  'OTPANDA_BATCH_ENTRY_CAP',
                  defaultValue: 3,
                ),
                maxTotalCodes: int.fromEnvironment(
                  'OTPANDA_BATCH_CODE_BUDGET',
                  defaultValue: 100,
                ),
                minPeriodSeconds: int.fromEnvironment(
                  'OTPANDA_BATCH_MIN_PERIOD',
                  defaultValue: 20,
                ),
                maxPeriodSeconds: 86400,
                maxWindowSeconds: 600,
                minRemainingMs: 1,
              )
            : null,
        clock: now,
        onSignedOut: () {
          bridge.clear();
          setState(() => status = bridge.status);
        },
        onOpenAccount: openSettings,
        onCopyAssigned: workspace.copyAssigned,
        onCopyPrivate: workspace.copyPrivate,
      );
    }

    if (['session-paused', 'restoring'].contains(status)) {
      return Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.memory(
                ottyImage,
                width: 32,
                height: 32,
                semanticLabel: 'OTPanda',
              ),
              const SizedBox(width: 10),
              const Flexible(
                child: Text('OTPanda', overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  status == 'restoring'
                      ? 'Restoring your session...'
                      : 'Your session is paused.',
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => run(() => bridge.start('restore')),
                  child: const Text('Continue session'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (status != 'restored') {
      return Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.memory(
                ottyImage,
                width: 32,
                height: 32,
                semanticLabel: 'OTPanda',
              ),
              const SizedBox(width: 10),
              const Flexible(
                child: Text('OTPanda', overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: widget.onNavigate == null
                  ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const ClientHome(fictionalCatalog: true),
                      ),
                    )
                  : () => navigated('demo'),
              child: const Text('Temporary demo'),
            ),
          ],
        ),
        body: AuthEntry(
          bridge: bridge,
          status: status,
          message: message,
          busy: busy,
          onLostAccess: widget.onNavigate == null
              ? null
              : () => navigated('recovery'),
          run: (action) => run(action),
        ),
      );
    }
    return settingsScaffold();
  }
}

/// Calls [onShown] once when it enters the tree and [onHidden] when it leaves.
class _WhenShown extends StatefulWidget {
  final VoidCallback onShown, onHidden;
  final Widget child;
  const _WhenShown({
    required this.onShown,
    required this.onHidden,
    required this.child,
  });
  @override
  State<_WhenShown> createState() => _WhenShownState();
}

class _WhenShownState extends State<_WhenShown> {
  late final VoidCallback hidden = widget.onHidden;
  bool shown = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      shown = true;
      widget.onShown();
    });
  }

  @override
  void dispose() {
    if (shown) hidden();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

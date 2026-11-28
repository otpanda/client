import 'dart:convert';
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart' show RealtimeBridge, RuleBridge;
import 'rules_capability.dart';
import 'rule_action_dialog.dart';
import 'session_contract.dart';

/// A separate capability. Native clients do not inherit browser source consent.
abstract interface class GmailSourceBridge {
  Future<SessionResponse> gmailSourceStatus();
  Future<void> connectGmail();

  /// One-time neutral result of returning from Google: 'connected', 'refused' or ''.
  /// Never carries a reason, mailbox or account detail.
  Future<String> takeGmailResult();
  Future<GmailDisconnectResult> disconnectGmail(
    String sourceId, {
    String rules = 'keep',
  });
}

/// What the API reported for an owner disconnect. Only booleans are kept.
/// [artifactsRemoved] is null when the API did not say, which is not a claim
/// that nothing was left behind.
class GmailDisconnectResult {
  final bool disconnected, googlePermissionRemains, lifecycleBlocked;
  final bool? artifactsRemoved;
  const GmailDisconnectResult({
    required this.disconnected,
    this.googlePermissionRemains = true,
    this.lifecycleBlocked = false,
    this.artifactsRemoved,
  });
  factory GmailDisconnectResult.fromJson(String body) {
    final v = jsonDecode(body);
    if (v is! Map || v['disconnected'] is! bool) {
      throw const FormatException('Unexpected disconnect result');
    }
    return GmailDisconnectResult(
      disconnected: v['disconnected'] as bool,
      googlePermissionRemains: v['googlePermissionRemains'] != false,
      lifecycleBlocked: v['lifecycleBlocked'] == true,
      artifactsRemoved: v['artifactsRemoved'] is bool
          ? v['artifactsRemoved'] as bool
          : null,
    );
  }
}

class GmailSourceConnect extends StatefulWidget {
  final GmailSourceBridge bridge;
  final VoidCallback? onOpenAccount;

  /// True only when the account's own source list holds a Gmail source.
  final bool hasGmailSource;

  /// The owning Sources view has a current confirmed snapshot. Status alone
  /// does not establish which mailboxes are already connected.
  final bool sourceStateKnown;
  const GmailSourceConnect({
    super.key,
    required this.bridge,
    this.onOpenAccount,
    this.hasGmailSource = false,
    this.sourceStateKnown = true,
  });
  @override
  State<GmailSourceConnect> createState() => _GmailSourceConnectState();
}

class _GmailSourceConnectState extends State<GmailSourceConnect>
    with WidgetsBindingObserver {
  bool checking = true, ready = false, busy = false, passkey = false;
  bool blocked = false;
  bool inFlight = false;
  void Function()? unsubscribe;
  Timer? spacing;
  bool again = false;
  String error = '';

  /// The return marker is only a hint from the URL. It is shown as success only once status says ready AND the
  /// account's own sources hold a Gmail source.
  bool claim = false;
  int unproven = 0;
  int pending = 0, skipped = 0, leftoverLabels = 0, leftoverFilters = 0;
  bool delayed = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    start();
    // Live hints replace the 30s poll. 'connect' closes any gap after a
    // reconnect; resume still checks. A burst runs one read, spaced 1s apart.
    final b = widget.bridge;
    if (b is RealtimeBridge) {
      unsubscribe = (b as RealtimeBridge).realtimeSubscribe((reason) {
        if (reason == 'connect' || reason == 'changed') hint();
      });
    }
  }

  void hint() {
    if (!mounted) return;
    if (spacing != null || inFlight) {
      again = true;
      return;
    }
    check();
    spacing = Timer(const Duration(seconds: 1), () {
      spacing = null;
      if (again && !inFlight) {
        again = false;
        hint();
      }
    });
  }

  @override
  void dispose() {
    unsubscribe?.call();
    spacing?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) check();
  }

  /// Reads the one-shot marker first, then checks status, so the two cannot race.
  Future<void> start() async {
    String r = '';
    try {
      r = await widget.bridge.takeGmailResult();
    } catch (_) {}
    if (!mounted) return;
    if (r == 'refused') {
      setState(
        () => error = 'Gmail was not connected. Try again when you are ready.',
      );
    } else if (r == 'connected') {
      claim = true;
    }
    await check();
    if (r == 'connected' && mounted && widget.bridge is RuleBridge) {
      final bridge = widget.bridge as RuleBridge;
      try {
        final cap = await probeRulesCapability(bridge);
        if (cap?.available != true || !mounted) return;
        final j = jsonDecode(await bridge.readRules());
        final rows = (j['rules'] as List)
            .whereType<Map<String, dynamic>>()
            .where((r) => r['status'] == 'paused' && r['kind'] == 'gmail')
            .toList();
        if (rows.isEmpty || !mounted) return;
        final review = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Resume saved matching rules?'),
            content: const Text(
              'Your kept rules are still paused. Review each rule and its future recipients before resuming. You can leave all rules paused.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Keep paused'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Review rules'),
              ),
            ],
          ),
        );
        if (review != true || !mounted) return;
        for (final row in rows) {
          if (!mounted) return;
          await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => RuleActionDialog(
              bridge: bridge,
              target: {
                'operation': 'resume',
                'entryId': row['entryId'],
                'ruleId': row['ruleId'],
              },
            ),
          );
        }
      } catch (_) {} // Rules remain paused if loading or review fails.
    }
  }

  @override
  void didUpdateWidget(GmailSourceConnect old) {
    super.didUpdateWidget(old);
    // A source that disappears (disconnect) contradicts any earlier success claim.
    if (old.hasGmailSource && !widget.hasGmailSource) claim = false;
  }

  Future<void> check() async {
    if (inFlight || !mounted) return;
    inFlight = true;
    try {
      final r = await widget.bridge.gmailSourceStatus();
      final v = jsonDecode(r.body);
      if (!mounted) return;
      if (r.status == 200 &&
          v is Map &&
          v['ready'] is bool &&
          v['passkeyRequired'] is bool) {
        ready = v['ready'];
        passkey = v['passkeyRequired'];
        pending = v['pending'] is int ? v['pending'] : 0;
        delayed = v['full'] == true;
        blocked = v['lifecycleBlocked'] == true;
        leftoverLabels = v['leftoverLabels'] is int ? v['leftoverLabels'] : 0;
        leftoverFilters = v['leftoverFilters'] is int
            ? v['leftoverFilters']
            : 0;
        skipped = v['skipped'] is Map
            ? (v['skipped'] as Map).values.whereType<int>().fold(
                0,
                (a, b) => a + b,
              )
            : 0;
        if (!ready) claim = false;
      }
    } catch (_) {
      error = '';
    } finally {
      inFlight = false;
    }
    if (claim && !widget.hasGmailSource) {
      // Status was read but no Gmail source is listed: after a second completed check the claim is dropped.
      if (++unproven >= 2) claim = false;
    }
    if (mounted) setState(() => checking = false);
    // A hint that arrived while this read was in flight gets exactly one
    // trailing read, never an overlapping one.
    if (again && spacing == null && mounted) {
      again = false;
      hint();
    }
  }

  Future<void> connect() async {
    if (!widget.sourceStateKnown) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        constraints: const BoxConstraints(maxWidth: 400),
        title: const Text('Connect Gmail'),
        content: const SingleChildScrollView(
          child: Text(
            'This development test supports only OTPanda\'s test mailbox. Google will ask to read mail, manage labels and manage basic Gmail settings. OTPanda creates one label and one add-label-only filter, then checks matching new mail for codes. The filter can miss codes or include unrelated mail. It does not send, delete or archive messages. Connecting a mailbox does not share it. Sharing an entry shares only that entry\'s codes.\n\nVerify with your passkey, then choose the mailbox in Google.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Verify and continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !widget.sourceStateKnown) return;
    setState(() {
      busy = true;
      error = '';
      claim = false;
    });
    try {
      await widget.bridge.connectGmail();
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'Gmail was not connected. Try again when you are ready.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Gmail',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            checking
                ? 'Checking email collection...'
                : !ready
                ? 'Email collection is not available yet.'
                : blocked
                ? 'Connecting Gmail is paused.'
                : passkey
                ? 'Add a passkey in Account & security before connecting Gmail.'
                : 'Read verification codes from a mailbox you choose. Google sign-in and mailbox collection are separate.',
          ),
          if (!checking && ready && blocked)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'An earlier Gmail connect, disconnect or renewal step did not finish cleanly, so OTPanda cannot tell what is left in the mailbox. This does not clear by itself and OTPanda will not retry it for you. You can still disconnect a connected Gmail source here.',
              ),
            ),
          if (leftoverLabels > 0 || leftoverFilters > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${leftoverLabels == 1 ? '1 OTPanda label' : '$leftoverLabels OTPanda labels'} and ${leftoverFilters == 1 ? '1 filter' : '$leftoverFilters filters'} may remain in Gmail after disconnecting. Remove the OTPanda label and its filter in Gmail settings if you no longer want them. The Google grant may also remain until you remove it in your Google Account.',
              ),
            ),
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                delayed
                    ? 'Collection is delayed while ${pending == 1 ? '1 message waits' : '$pending messages wait'} to be fetched from Gmail. OTPanda retries automatically.'
                    : '${pending == 1 ? '1 message is' : '$pending messages are'} waiting to be fetched from Gmail. OTPanda retries automatically.',
              ),
            ),
          if (skipped > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${skipped == 1 ? '1 message in the last 8 days was' : '$skipped messages in the last 8 days were'} not collected because ${skipped == 1 ? 'it was too large or invalid' : 'they were too large or invalid'}.',
              ),
            ),
          if (claim && !checking && ready && widget.hasGmailSource)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Gmail connected.'),
            ),
          if (error.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(error)),
          if (!checking && ready)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton(
                onPressed: busy || blocked || !widget.sourceStateKnown
                    ? null
                    : passkey
                    ? widget.onOpenAccount
                    : connect,
                child: Text(
                  busy
                      ? 'Verifying...'
                      : passkey
                      ? 'Account & security'
                      : 'Connect Gmail',
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class GmailSourceDisconnect extends StatefulWidget {
  final GmailSourceBridge bridge;
  final String sourceId, label;
  final VoidCallback onChanged;
  const GmailSourceDisconnect({
    super.key,
    required this.bridge,
    required this.sourceId,
    required this.label,
    required this.onChanged,
  });
  @override
  State<GmailSourceDisconnect> createState() => _GmailSourceDisconnectState();
}

class _GmailSourceDisconnectState extends State<GmailSourceDisconnect> {
  bool busy = false;
  String error = '';
  Future<void> disconnect() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        constraints: const BoxConstraints(maxWidth: 400),
        title: const Text('Disconnect Gmail?'),
        content: Text(
          'Stop collecting codes from ${widget.label}. Verify with a passkey to disconnect. This removes OTPanda\'s stored mailbox token and OTPanda will try to remove the label and filter it created. Google permission to read mail and manage the OTPanda label and filter may remain. Remove OTPanda in your Google Account permissions too if you want to revoke that grant.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep connected'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Verify and disconnect'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    // The API signs the keep/delete choice only when it says so explicitly. An
    // unknown answer keeps the connector connected: no legacy payload fallback,
    // no silent keep, no silent delete.
    final Object bridgeForRules = widget.bridge;
    final cap = bridgeForRules is RuleBridge
        ? await probeRulesCapability(bridgeForRules)
        : null;
    if (!mounted) return;
    if (cap == null || !cap.disconnectPolicy) {
      setState(
        () => error = 'Could not check how saved matching rules are handled. Gmail is still connected. Try again.',
      );
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete saved matching rules?'),
        content: const Text(
          'Delete the rules for this Gmail connector, or keep them paused. Kept rules never resume automatically after reconnection.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'keep'),
            child: const Text('Keep paused'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'delete'),
            child: const Text('Delete rules'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.bridge.disconnectGmail(
        widget.sourceId,
        rules: choice,
      );
      if (!mounted) return;
      setState(() => busy = false);
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          constraints: const BoxConstraints(maxWidth: 400),
          title: Text(
            result.disconnected ? 'Gmail disconnected' : 'Nothing was changed',
          ),
          content: Text(disconnectMessage(result)),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (result.disconnected) widget.onChanged();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not disconnect Gmail. Try again.');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(
        onPressed: busy ? null : disconnect,
        child: Text(busy ? 'Verifying...' : 'Disconnect Gmail'),
      ),
      if (error.isNotEmpty) Text(error),
    ],
  );
}

/// Result wording. Never claims more than the API reported.
String disconnectMessage(GmailDisconnectResult r) {
  if (!r.disconnected) {
    return r.lifecycleBlocked
        ? 'Another Gmail step for this mailbox is still unresolved, so OTPanda did not change anything and cannot confirm whether collection from it is still running. You can try again later; this does not clear by itself.'
        : 'Gmail was not disconnected. Try again.';
  }
  final b = StringBuffer(
    'OTPanda stopped collecting codes and removed its stored mailbox token. ',
  );
  if (r.lifecycleBlocked) {
    b.write(
      'An earlier Gmail step did not finish cleanly, so OTPanda could not confirm whether its label and filter were removed. They may still be in the mailbox. ',
    );
  } else if (r.artifactsRemoved == true) {
    b.write('It also removed the label and filter it created in Gmail. ');
  } else if (r.artifactsRemoved == false) {
    b.write(
      'It could not remove the label and filter it created in Gmail. They may still be there. ',
    );
  }
  if (r.googlePermissionRemains) {
    b.write(
      'Google may still list OTPanda in your account permissions. Remove it there if you want to revoke that access.',
    );
  }
  return b.toString().trimRight();
}

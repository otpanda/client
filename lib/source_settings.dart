import 'package:material_ui/material_ui.dart';

import 'gmail_source.dart';
import 'read_workspace_controller.dart';
import 'settings_hub.dart';

class SourceSettings extends StatefulWidget {
  const SourceSettings({
    super.key,
    required this.controller,
    this.onOpenAccount,
  });
  final ReadWorkspaceController controller;
  final VoidCallback? onOpenAccount;
  @override
  State<SourceSettings> createState() => _SourceSettingsState();
}

class _SourceSettingsState extends State<SourceSettings>
    with WidgetsBindingObserver {
  ReadWorkspaceController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.showSources();
    });
  }

  @override
  void didUpdateWidget(SourceSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.hideSources();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) controller.showSources();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.showSources();
    } else {
      controller.hideSources();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.hideSources();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final bridge = controller.bridge;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (bridge is GmailSourceBridge)
            GmailSourceConnect(
              bridge: bridge as GmailSourceBridge,
              onOpenAccount: widget.onOpenAccount,
              sourceStateKnown:
                  controller.sourcesLoaded &&
                  !controller.sourcesLoading &&
                  controller.sourcesMessage.isEmpty,
              hasGmailSource: controller.settingsSources.any(
                (s) => s.kind == 'gmail',
              ),
            ),
          if (!controller.sourcesLoaded && controller.sourcesMessage.isEmpty)
            settingsCard('Sources', [
              Semantics(
                label: 'Loading sources',
                child: RedactedText('Connected source'),
              ),
              SizedBox(height: 8),
              RedactedText('Mailboxes and phones that receive codes'),
            ]),
          if (controller.sourcesMessage.isNotEmpty)
            settingsCard('Sources', [Text(controller.sourcesMessage)]),
          if (controller.sourcesLoaded &&
              controller.sourcesMessage.isEmpty &&
              controller.settingsSources.isEmpty)
            settingsCard('Sources', const [
              Text('No sources connected. Connect a mailbox to receive codes.'),
            ]),
          for (final source in controller.settingsSources)
            settingsCard(source.label, [
              Text(source.kind.toUpperCase()),
              if (source.kind == 'gmail' && bridge is GmailSourceBridge)
                GmailSourceDisconnect(
                  bridge: bridge as GmailSourceBridge,
                  sourceId: source.id,
                  label: source.label,
                  onChanged: () => controller.refreshSources(),
                ),
            ]),
        ],
      );
    },
  );
}

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../core/transfer/file_scanner.dart';
import '../features/history/history_screen.dart';
import '../features/home/home_screen.dart';
import '../features/send/send_flow.dart';
import '../features/settings/settings_screen.dart';
import '../features/transfers/transfer_widgets.dart';
import '../platform/platform_services.dart';
import '../ui/widgets.dart';
import 'app_controller.dart';

const _seed = Color(0xFF2F6FED);

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      scrolledUnderElevation: 1,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class LanBeamApp extends StatelessWidget {
  const LanBeamApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return NotifierBuilder(
      notifier: controller.engine.settings,
      builder: (context) => MaterialApp(
        title: 'LanBeam',
        debugShowCheckedModeBanner: false,
        navigatorKey: controller.navigatorKey,
        scaffoldMessengerKey: controller.messengerKey,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: switch (controller.settings.themeMode) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        home: RootShell(controller: controller),
      ),
    );
  }
}

/// Navigation rail on wide screens, bottom navigation on phones.
/// On desktop the whole window accepts dropped files and folders.
class RootShell extends StatefulWidget {
  const RootShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  bool _dragging = false;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // Ask for notification permission (and legacy storage on old Android)
    // once the first frame is up, not during startup.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => controller.requestStartupPermissions(),
    );
  }

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.swap_vert_outlined, Icons.swap_vert, 'Transfers'),
    (Icons.history_outlined, Icons.history, 'History'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  Widget _page(int index) => switch (index) {
    0 => HomeScreen(controller: controller),
    1 => TransfersScreen(controller: controller),
    2 => HistoryScreen(controller: controller),
    _ => SettingsScreen(controller: controller),
  };

  void _onDrop(DropDoneDetails details) {
    setState(() => _dragging = false);
    final selections = [
      for (final f in details.files) LocalPathSelection(f.path),
    ];
    if (selections.isEmpty) return;
    startSendFlow(context, controller, selections: selections);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.tab,
      builder: (context, index, _) {
        final wide = MediaQuery.sizeOf(context).width >= 840;
        final activeCount = controller.engine.transfers
            .where((t) => t.status.isRunning)
            .length;
        Widget badge(Widget icon, int i) => i == 1 && activeCount > 0
            ? Badge(label: Text('$activeCount'), child: icon)
            : icon;

        Widget body = _page(index);
        if (isDesktop) {
          body = DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: _onDrop,
            child: Stack(children: [body, if (_dragging) const _DropOverlay()]),
          );
        }

        if (wide) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) => controller.tab.value = i,
                  labelType: NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Icon(
                      Icons.bolt,
                      color: Theme.of(context).colorScheme.primary,
                      size: 32,
                    ),
                  ),
                  destinations: [
                    for (var i = 0; i < _destinations.length; i++)
                      NavigationRailDestination(
                        icon: badge(Icon(_destinations[i].$1), i),
                        selectedIcon: badge(Icon(_destinations[i].$2), i),
                        label: Text(_destinations[i].$3),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) => controller.tab.value = i,
            destinations: [
              for (var i = 0; i < _destinations.length; i++)
                NavigationDestination(
                  icon: badge(Icon(_destinations[i].$1), i),
                  selectedIcon: badge(Icon(_destinations[i].$2), i),
                  label: _destinations[i].$3,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: scheme.primary, width: 2),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.file_download_outlined,
                  size: 56,
                  color: scheme.onPrimaryContainer,
                ),
                const SizedBox(height: 12),
                Text(
                  'Drop files or folders to send',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

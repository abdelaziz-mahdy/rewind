import 'package:flutter/material.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../coordinator/clip_coordinator.dart';
import '../events/game_catalog.dart';
import '../obs/app_info.dart';
import '../games/exe_icon_resolver.dart';
import '../games/game_descriptor.dart';
import '../games/steam_icon_resolver.dart';
import '../settings/app_settings.dart';
import 'capture_app_match.dart';
import 'theme.dart';
import 'widgets/game_tile_avatar.dart';

/// One row of the catalog: a display/detection label pair plus the set of
/// gameIds whose config/clips/activity count toward this row's state — for
/// the merged League row that's both its vendor id and the catalog's id.
class _CatalogRow {
  final String gameId;
  final String displayName;
  final String detectionLabel;
  final String? secondaryLabel;
  final Set<String> matchIds;

  const _CatalogRow({
    required this.gameId,
    required this.displayName,
    required this.detectionLabel,
    this.secondaryLabel,
    required this.matchIds,
  });
}

enum _RowState { running, inLibrary, addable }

/// The processMatch of the first non-primary id in [d]'s merged set that has
/// a [popularGamesCatalog] entry — e.g. League's "Also via process:
/// LeagueClientUx" secondary label. Null when there is none (no merged
/// descriptor lacks one today, but a future one might).
String? _secondaryLabelFor(GameDescriptor d) {
  for (final id in d.mergedGameIds) {
    if (id == d.primaryGameId) continue;
    final catalogMatch = popularGamesCatalog.where((g) => g.gameId == id);
    if (catalogMatch.isNotEmpty) {
      return 'Also via process: ${catalogMatch.first.processMatch}';
    }
  }
  return null;
}

List<_CatalogRow> _buildCatalogRows() {
  // A descriptor with more than one merged gameId (League: the vendor
  // integration + the catalog's generic `app:league_of_legends` entry) is
  // listed first and absorbs its catalog id, rather than showing a
  // confusing duplicate row (§3.5) — driven by the registry, not a
  // hardcoded League special case (Task 21).
  final mergedDescriptors =
      gameDescriptors.where((d) => d.mergedGameIds.length > 1);
  final absorbedCatalogIds = <String>{
    for (final d in mergedDescriptors)
      for (final id in d.mergedGameIds)
        if (id != d.primaryGameId) id,
  };
  return [
    for (final d in mergedDescriptors)
      _CatalogRow(
        gameId: d.primaryGameId,
        displayName: d.displayName,
        detectionLabel: d.hasLiveFeed ? 'Live Client API' : 'Process detection',
        secondaryLabel: _secondaryLabelFor(d),
        matchIds: d.mergedGameIds,
      ),
    for (final g in popularGamesCatalog)
      if (!absorbedCatalogIds.contains(g.gameId))
        _CatalogRow(
          gameId: g.gameId,
          displayName: g.displayName,
          detectionLabel: 'Process: ${g.processMatch}',
          matchIds: {g.gameId},
        ),
  ];
}

_RowState _stateFor(_CatalogRow row, AppSettings settings, List<Clip> clips,
    Set<String> activeIds) {
  if (row.matchIds.any(activeIds.contains)) return _RowState.running;
  final inLibrary =
      settings.allConfigs.any((c) => row.matchIds.contains(c.gameId)) ||
          clips.any((c) => row.matchIds.contains(c.gameId));
  return inLibrary ? _RowState.inLibrary : _RowState.addable;
}

/// The Supported Games catalog (§3.5): every title Rewind can auto-detect out
/// of the box, with League's vendor integration and its generic
/// process-detection catalog entry merged into one row. Each row shows a
/// derived state — a mint "Running" dot, a muted "In your library" label, or
/// an Add button — and Add writes through the same `settings.configFor` →
/// `setConfig` → `onSettingsChanged` path the hub's per-game settings use, so
/// the game appears in the rail immediately (the rail's directory rebuild is
/// already reactive to a settings mutation via `settingsRevision`).
class SupportedGamesScreen extends StatefulWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;

  /// Persists a settings change (mutated in place) — the Add flow's path.
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Navigates the Shell to this game's hub — called when a running or
  /// in-library row is tapped. Addable rows aren't tappable to navigate;
  /// their explicit Add button is the only affordance.
  final ValueChanged<String> onOpenGame;

  /// Live app enumeration for the "Running now" section — lets a user add
  /// any app that's actually running right now, not just catalog titles
  /// (the original "Add game" gap: the fixed catalog couldn't add the game
  /// you were literally playing). Null (tests, stub engine) hides the
  /// section.
  final List<AppInfo> Function()? listApps;

  /// Resolves a real game icon + name from the local Steam library for
  /// running apps that have no macOS bundle icon (Steam/Wine games). Null
  /// (tests, no Steam) leaves those rows on the letter monogram.
  final SteamIconResolver? steamResolver;

  /// Fallback icon resolver for a non-Steam Wine game — reads the icon from
  /// the game's own `.exe`. Tried only when the Steam lookup misses. Null
  /// leaves those rows on the monogram.
  final ExeIconResolver? exeResolver;

  const SupportedGamesScreen({
    required this.coordinator,
    required this.library,
    required this.onSettingsChanged,
    required this.onOpenGame,
    this.listApps,
    this.steamResolver,
    this.exeResolver,
    super.key,
  });

  @override
  State<SupportedGamesScreen> createState() => _SupportedGamesScreenState();
}

class _SupportedGamesScreenState extends State<SupportedGamesScreen> {
  void _addGame(String gameId) {
    final settings = widget.coordinator.settings;
    final cfg = settings.configFor(gameId);
    settings.setConfig(cfg);
    setState(() {});
    widget.onSettingsChanged(settings);
  }

  /// The real Steam art for a running app that has no OS bundle icon — the
  /// robot for R.E.P.O. and friends. Resolved by the app's window/exe name
  /// against the local Steam library. Null when there's no resolver, the app
  /// already has a bundle icon, or it isn't a Steam game. Memoized inside the
  /// resolver, so calling it per build is cheap.
  SteamGameArt? _artFor(AppInfo a) {
    final resolver = widget.steamResolver;
    if (resolver == null) return null;
    if (a.iconPath != null && a.iconPath!.isNotEmpty) return null;
    return resolver.resolveByInstallDir(a.name);
  }

  /// "Running now" Add: same learn path as picking the app as a capture
  /// source (`learnAppAsGame` — processMatch/displayName/iconPath rules),
  /// WITHOUT switching the capture target; auto-switch takes over next
  /// time the game is detected running. Any resolved Steam [art] (or, failing
  /// that, the game's own exe icon) is stored so the rail/hub keep the real
  /// icon after the game stops running.
  Future<void> _addRunningApp(AppInfo a, SteamGameArt? art) async {
    final settings = widget.coordinator.settings;
    String? exeIcon;
    if (art == null && (a.iconPath == null || a.iconPath!.isEmpty)) {
      exeIcon = await widget.exeResolver?.iconForApp(a);
    }
    if (!mounted) return;
    learnAppAsGame(settings, a, art: art, iconPath: exeIcon);
    setState(() {});
    widget.onSettingsChanged(settings);
  }

  /// Running apps not yet in the library and not already a catalog row —
  /// the catalog rows above already carry their own Add/state. Probable
  /// games first (Wine exes + catalog matches, per partitionCapturableApps),
  /// then everything else.
  List<AppInfo> _addableRunningApps(AppSettings settings) {
    final apps = widget.listApps?.call() ?? const <AppInfo>[];
    final known = settings.allConfigs.map((c) => c.gameId).toSet();
    final grouped = partitionCapturableApps(apps);
    return [
      for (final a in [...grouped.games, ...grouped.others])
        if (matchingCatalogGame(a) == null && !known.contains(gameIdForApp(a)))
          a,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable:
          Listenable.merge([widget.library, widget.coordinator.activeGameIds]),
      builder: (context, _) {
        final settings = widget.coordinator.settings;
        final clips = widget.library.all;
        final activeIds = widget.coordinator.activeGameIds.value;
        final rows = _buildCatalogRows();

        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            Text('Supported Games', style: theme.textTheme.display),
            const SizedBox(height: 4),
            Text(
              'Games Rewind can auto-detect out of the box.',
              style: theme.textTheme.bodyMuted,
            ),
            const SizedBox(height: 16),
            for (final row in rows)
              _CatalogRowTile(
                key: ValueKey('supportedGameRow:${row.gameId}'),
                row: row,
                state: _stateFor(row, settings, clips, activeIds),
                onAdd: () => _addGame(row.gameId),
                onOpen: () => widget.onOpenGame(row.gameId),
              ),
            if (widget.listApps != null) ...[
              const SizedBox(height: 28),
              Text('Running now', style: theme.textTheme.title),
              const SizedBox(height: 4),
              Text(
                "Playing something that isn't in the list? Add any app "
                'running right now and Rewind will treat it as a game — '
                'auto-detected and auto-captured next time it launches.',
                style: theme.textTheme.bodyMuted,
              ),
              const SizedBox(height: 8),
              ...switch (_addableRunningApps(settings)) {
                [] => [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Nothing new running — every running app is already '
                        'in your library or the list above.',
                        style: theme.textTheme.bodyMuted,
                      ),
                    ),
                  ],
                final apps => [
                    for (final a in apps)
                      if (_artFor(a) case final art)
                        _RunningAppRow(
                          key: ValueKey('runningAppRow:${gameIdForApp(a)}'),
                          app: a,
                          art: art,
                          exeResolver: widget.exeResolver,
                          onAdd: () {
                            _addRunningApp(a, art);
                          },
                        ),
                  ],
              },
            ],
            const SizedBox(height: 20),
            Text(
              'Rewind only reads official local APIs and process names — '
              'never game memory. Games without a sanctioned API get hotkey '
              'capture only.',
              style: theme.textTheme.bodyMuted,
            ),
          ],
        );
      },
    );
  }
}

/// One 56 px catalog row (§3.5): name + detection method on the left, the
/// derived state on the right. Tappable to open the hub once the game is
/// running or in the library; addable rows only respond to their Add button.
class _CatalogRowTile extends StatelessWidget {
  final _CatalogRow row;
  final _RowState state;
  final VoidCallback onAdd;
  final VoidCallback onOpen;

  const _CatalogRowTile({
    required this.row,
    required this.state,
    required this.onAdd,
    required this.onOpen,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final detail = row.secondaryLabel == null
        ? row.detectionLabel
        : '${row.detectionLabel} · ${row.secondaryLabel}';

    final content = Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.hairline)),
      ),
      child: Row(
        children: [
          GameTileAvatar(
            gameId: row.gameId,
            displayName: row.displayName,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.displayName, style: theme.textTheme.title),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodyMuted,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _StateIndicator(state: state, onAdd: onAdd),
        ],
      ),
    );

    if (state == _RowState.addable) return content;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onOpen, child: content),
    );
  }
}

/// The right-hand side of a catalog row: a live mint dot + "RUNNING", a muted
/// "IN YOUR LIBRARY" label, or an Add button — mirroring the rail's live dot
/// and the hub's status-pill treatment.
class _StateIndicator extends StatelessWidget {
  final _RowState state;
  final VoidCallback onAdd;

  const _StateIndicator({required this.state, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    switch (state) {
      case _RowState.running:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration:
                  BoxDecoration(color: tokens.accent, shape: BoxShape.circle),
              child: const SizedBox(width: 6, height: 6),
            ),
            const SizedBox(width: 6),
            Text('RUNNING',
                style: theme.textTheme.micro.copyWith(color: tokens.accent)),
          ],
        );
      case _RowState.inLibrary:
        return Text('IN YOUR LIBRARY',
            style: theme.textTheme.micro.copyWith(color: tokens.textMuted));
      case _RowState.addable:
        return OutlinedButton(
          key: const ValueKey('addGameButton'),
          onPressed: onAdd,
          child: const Text('Add'),
        );
    }
  }
}

/// One "Running now" row: the app's real icon (a macOS bundle icon, or a
/// game icon resolved from the local Steam library via [art]), name, a Wine
/// marker where relevant, and an Add button. Mirrors _CatalogRowTile's
/// geometry so the two lists read as one screen.
class _RunningAppRow extends StatelessWidget {
  final AppInfo app;
  final SteamGameArt? art;
  final ExeIconResolver? exeResolver;
  final VoidCallback onAdd;

  const _RunningAppRow({
    required this.app,
    required this.onAdd,
    this.art,
    this.exeResolver,
    super.key,
  });

  /// The row's avatar. A known icon (bundle or Steam) renders directly; a
  /// bundle-less Wine game with no Steam art asks the exe resolver (async) for
  /// its embedded icon and swaps the monogram for it when it lands. The
  /// resolver memoizes, so the future is stable across rebuilds.
  Widget _avatar(String displayName) {
    final known = app.iconPath ?? art?.iconPath;
    if (known != null || app.bundleId.isNotEmpty || exeResolver == null) {
      return GameTileAvatar(
        gameId: gameIdForApp(app),
        displayName: displayName,
        iconPath: known,
        size: 32,
      );
    }
    return FutureBuilder<String?>(
      future: exeResolver!.iconForApp(app),
      builder: (context, snap) => GameTileAvatar(
        gameId: gameIdForApp(app),
        displayName: displayName,
        iconPath: snap.data,
        size: 32,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final displayName = art?.name ?? app.name;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        border: Border.fromBorderSide(hairlineBorder()),
      ),
      child: Row(
        children: [
          _avatar(displayName),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              displayName,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.body,
            ),
          ),
          if (app.bundleId.isEmpty) ...[
            Text('Windows app', style: theme.textTheme.bodyMuted),
            const SizedBox(width: 12),
          ],
          OutlinedButton(
            onPressed: onAdd,
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

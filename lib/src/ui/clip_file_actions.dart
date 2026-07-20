import 'dart:io';

import 'package:flutter/material.dart';

/// Shared "hand this clip file to the OS" actions, used by the clip tile's
/// overflow menu and the player's header. Both return whether the OS
/// accepted the request so callers can surface failure (a menu item that
/// silently does nothing reads as broken).
Future<bool> openClipFile(String path) async {
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('open', [path]);
      return r.exitCode == 0;
    } else if (Platform.isWindows) {
      // `start` is a cmd.exe built-in, not an executable; a quoted first
      // arg is taken as the window title, so pass an empty title first.
      // No exit-code gate: cmd/start exit codes don't reliably reflect
      // whether a handler opened, so Windows stays launch-and-hope with
      // only the exception path reporting failure.
      await Process.run('cmd', ['/c', 'start', '', path]);
      return true;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Reveals the file in Finder / Explorer.
Future<bool> revealClipFile(String path) async {
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('open', ['-R', path]);
      return r.exitCode == 0;
    } else if (Platform.isWindows) {
      // Documented form: "/select," joined with the path as ONE argument.
      // Same no-exit-code-gate rationale as openClipFile: explorer returns
      // 1 even when the window opens fine.
      await Process.run('explorer', ['/select,$path']);
      return true;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// The one failure toast both actions share.
void showOpenFailedToast(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
    behavior: SnackBarBehavior.floating,
    content: Text(
        "Couldn't open this file — it may have been moved or deleted."),
  ));
}

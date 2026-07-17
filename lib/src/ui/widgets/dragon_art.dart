import 'dart:io';

import 'package:flutter/material.dart';

/// Bridges a `DDragon` art lookup (champion portrait / item icon — a
/// `Future<File?>` that resolves off disk-cached art, see
/// `lib/src/games/league/ddragon.dart`) into the widget tree, using the same
/// pattern as `ClipThumbnail`/`ThumbnailCache.ensure`: start on
/// [placeholder], swap to the image the instant the future resolves, and
/// stay on [placeholder] forever if it resolves to null (offline, unknown
/// champion/item id) or if [future] itself is null (no `DDragon` wired up —
/// every widget test that doesn't care about art, and any build before the
/// app threads one through). NEVER a broken-image icon.
class DragonArt extends StatelessWidget {
  final Future<File?>? future;
  final double size;
  final BorderRadius? borderRadius;
  final Widget placeholder;

  const DragonArt({
    required this.future,
    required this.size,
    required this.placeholder,
    this.borderRadius,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final f = future;
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: SizedBox(
        width: size,
        height: size,
        child: f == null
            ? placeholder
            : FutureBuilder<File?>(
                future: f,
                builder: (context, snapshot) {
                  final file = snapshot.data;
                  if (file == null) return placeholder;
                  return Image.file(
                    file,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  );
                },
              ),
      ),
    );
  }
}

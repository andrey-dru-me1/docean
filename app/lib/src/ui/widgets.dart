/// Rendering helpers shared across the search/chat UI.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import '../features/search_service.dart' show HighlightSpan;

/// A curated palette of tag colors. Each tag receives a deterministic color by
/// hashing its name and picking from this list, so the same tag always renders
/// the same hue across surfaces (detail view, browse cards, filters).
const List<Color> kTagPalette = <Color>[
  Color(0xFF1B5E20), // green 900
  Color(0xFF4A148C), // deep purple 900
  Color(0xFF0D47A1), // blue 900
  Color(0xFFB71C1C), // red 900
  Color(0xFFE65100), // orange 900
  Color(0xFF006064), // cyan 900
  Color(0xFF880E4F), // pink 900
  Color(0xFF33691E), // light green 900
  Color(0xFF01579B), // light blue 900
  Color(0xFF4E342E), // brown 900
  Color(0xFF1A237E), // indigo 900
  Color(0xFF004D40), // teal 900
];

/// Derive a deterministic color for a tag name.
///
/// The name is hashed (FNV-1a over its code units) and mapped onto
/// [kTagPalette]. Empty names always resolve to the first palette entry so the
/// result is stable even for malformed input.
Color tagColorFor(String name) {
  var hash = 0x811c9dc5;
  for (final unit in name.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return kTagPalette[hash % kTagPalette.length];
}

/// The mixed tint used as a tag chip background for a given tag name on a
/// given surface.
///
/// The palette is a set of *dark* material 900 shades ([kTagPalette]), so a
/// plain `color.withValues(alpha: 0.16)` wash renders as a near-black smudge
/// on the dark theme's already-dark surface — low contrast and hard to read.
/// In dark mode the tint is instead a *light* hue of the same tag blended
/// into the surface at high opacity, producing a clearly-visible pastel
/// colored pill with dark labels staying readable. Light themes keep the
/// original washed-out translucent wash. The caller supplies the surface
/// color (typically `ColorScheme.surface`) so the blend always matches the
/// chip's backdrop.
Color tagTintFor(BuildContext context, String name) {
  final scheme = Theme.of(context).colorScheme;
  if (scheme.brightness == Brightness.light) {
    return tagColorFor(name).withValues(alpha: 0.16);
  }
  final light = HSLColor.fromColor(
    tagColorFor(name),
  ).withLightness(0.85).toColor();
  return Color.alphaBlend(light.withValues(alpha: 0.70), scheme.surface);
}

/// A compact, colored tag chip used consistently across every surface:
/// preview tiles, filter bars, search results, and the info sidebar.
///
/// The color is derived deterministically from the tag name (see
/// [tagColorFor]); the background is the tag's tinted hue so dark and light
/// themes both stay readable.
///
/// * When [onSelected] is provided the chip acts as a filter (with a
///   checkmark when [selected]).
/// * When [onPressed] is provided the chip is tappable (action-style).
/// * When [onDeleted] is provided a hover/touch delete affordance (×) is
///   shown on a plain chip.
///
/// The visual palette is always the same — the same tag always looks the
/// same regardless of which surface it appears on.
///
/// Note: the chip deliberately passes **no `avatar`** — a zero-size avatar
/// placeholder would still reserve the avatar slot and push the label away
/// from the chip's left edge.
class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.selected = false,
    this.overlay = false,
    this.onSelected,
    this.onPressed,
    this.onDeleted,
  });

  final String label;

  /// Selection state for filter chips: when selected the chip is filled with a
  /// stronger tint so the active filter is obvious at a glance.
  final bool selected;

  /// Renders the chip on top of a visual preview (e.g. the Documents grid
  /// tiles): the washed-out tint is replaced with a translucent tint of the
  /// tag's own color and a tag-colored ring, so the chip retains its color
  /// identity while a white label (with a soft shadow) stays readable over
  /// arbitrary image content.
  final bool overlay;

  /// When non-null the chip is interactive: tapping toggles [selected].
  /// This turns the chip into a filter chip (with a checkmark).
  final ValueChanged<bool>? onSelected;

  /// When non-null the chip is tappable (action-style, no selection state).
  final VoidCallback? onPressed;

  /// When non-null a hover/touch delete affordance (×) is shown and tapping
  /// it calls this callback.
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final color = tagColorFor(label);
    final background = overlay
        // A translucent tint of the tag's own color (instead of a mono dark
        // scrim) so on-preview chips keep their deterministic color identity
        // while still scrimming arbitrary image content underneath.
        ? color.withValues(alpha: 0.55)
        : selected
        ? tagTintFor(context, label).withValues(alpha: 0.38)
        : tagTintFor(context, label);
    final labelColor = overlay ? Colors.white : color;
    final labelStyle = TextStyle(
      fontSize: 11.5,
      color: labelColor,
      fontWeight: FontWeight.w600,
      shadows: overlay
          ? const [Shadow(color: Colors.black45, blurRadius: 3)]
          : null,
    );

    if (onSelected != null) {
      return FilterChip(
        key: key,
        label: Text(label),
        selected: selected,
        visualDensity: VisualDensity.compact,
        backgroundColor: background,
        selectedColor: tagTintFor(context, label).withValues(alpha: 0.38),
        side: BorderSide(color: color.withValues(alpha: 0.45)),
        labelStyle: labelStyle,
        showCheckmark: false,
        onSelected: onSelected,
      );
    }

    if (onPressed != null) {
      return ActionChip(
        key: key,
        label: Text(label),
        visualDensity: VisualDensity.compact,
        backgroundColor: background,
        side: BorderSide(color: color.withValues(alpha: 0.45)),
        labelStyle: labelStyle,
        onPressed: onPressed,
      );
    }

    return Chip(
      key: key,
      visualDensity: VisualDensity.compact,
      backgroundColor: background,
      side: BorderSide(
        color: overlay
            ? color.withValues(alpha: 0.85)
            : color.withValues(alpha: 0.45),
      ),
      labelStyle: labelStyle,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      label: Text(label),
      deleteIcon: onDeleted != null ? TagDeleteIcon(color: color) : null,
      deleteIconColor: color,
      onDeleted: onDeleted,
    );
  }
}

/// Read a [HighlightSpan]'s byte range as ints for slicing a snippet substring.
(int, int) spanRange(HighlightSpan span) =>
    (span.start.toInt(), span.end.toInt());

/// The delete (X) affordance for a tag chip that supports removal.
///
/// Desktop (mouse pointer) users get a clean chip that reveals the X **only on
/// hover** (`MouseRegion`), keeping the tag row compact and uncluttered; touch
/// platforms always show the X so the delete action stays reachable (and long
/// press remains available on the chip itself as an alternative).
class TagDeleteIcon extends StatefulWidget {
  const TagDeleteIcon({super.key, required this.color});

  final Color color;

  @override
  State<TagDeleteIcon> createState() => _TagDeleteIconState();
}

class _TagDeleteIconState extends State<TagDeleteIcon> {
  bool _hovering = false;

  /// Whether a non-mouse pointer (touch/stylus) has interacted so far.
  ///
  /// There is no declarative "is this device touch-only?" in `MediaQuery` on
  /// desktop, so we watch incoming pointer events instead: a touch/stylus
  /// `PointerDown` marks the device as touch and keeps the X always visible
  /// (the delete action stays reachable and long-press remains an
  /// alternative); a pure mouse device stays clean until hover.
  bool _touchInteraction = false;

  @override
  Widget build(BuildContext context) {
    final visible = _hovering || _touchInteraction;
    return Listener(
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.mouse) {
          setState(() => _touchInteraction = true);
        }
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: Icon(Icons.clear, size: 16, color: widget.color),
          ),
        ),
      ),
    );
  }
}

/// Renders a snippet with the query-matching spans emphasized.
class HighlightedSnippet extends StatelessWidget {
  const HighlightedSnippet({
    super.key,
    required this.text,
    this.highlights = const [],
    this.style,
    this.highlightStyle = const TextStyle(
      fontWeight: FontWeight.w700,
      color: Colors.teal,
    ),
    this.maxLines,
    this.textAlign,
  });

  final String text;
  final List<HighlightSpan> highlights;
  final TextStyle? style;
  final TextStyle highlightStyle;
  final int? maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    if (highlights.isEmpty) {
      return Text(
        text,
        style: style ?? Theme.of(context).textTheme.bodyMedium,
        maxLines: maxLines,
        overflow: maxLines != null ? TextOverflow.ellipsis : null,
        textAlign: textAlign,
      );
    }

    final spans = <TextSpan>[];
    int cursor = 0;
    for (final h in highlights) {
      final (start, end) = spanRange(h);
      // Guard against spans that exceed the snippet (e.g. stale spans).
      if (start > text.length ||
          end > text.length ||
          start < 0 ||
          end < start) {
        continue;
      }
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      spans.add(
        TextSpan(text: text.substring(start, end), style: highlightStyle),
      );
      cursor = end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(
        style: style ?? Theme.of(context).textTheme.bodyMedium,
        children: spans,
      ),
      maxLines: maxLines,
      overflow: maxLines != null ? TextOverflow.ellipsis : null,
      textAlign: textAlign,
    );
  }
}

/// A dismissible banner shown when no AI provider is configured, so the app
/// still explains why some features are limited.
class AiUnavailableBanner extends StatelessWidget {
  const AiUnavailableBanner({super.key, this.onConfigure});

  final VoidCallback? onConfigure;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.smart_toy_outlined, color: scheme.onTertiaryContainer),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'No AI provider is configured. Search still works offline and '
                'the assistant will return matching excerpts. Configure a '
                'provider to get generated answers.',
              ),
            ),
            if (onConfigure != null)
              TextButton(
                onPressed: onConfigure,
                child: const Text('Configure'),
              ),
          ],
        ),
      ),
    );
  }
}

/// A reusable empty-state box.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    // Wrap in a scroll view so the empty state never overflows when the
    // surrounding screen is short (e.g. small viewports or when other panels
    // consume vertical space).
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 64,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    if (subtitle != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        subtitle!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

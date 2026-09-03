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

/// A compact, colored tag pill used consistently across every surface:
/// preview tiles, filter bars, search results, and the info sidebar.
///
/// The color is derived deterministically from the tag name (see
/// [tagColorFor]); the pill always renders an **opaque** fill of the tag's own
/// color with an opaque tag-colored ring and a white label (with a soft
/// shadow), so dark and light themes — and arbitrary preview content
/// underneath — both stay readable.
///
/// Hover and select both make the *background* lighter: an active filter
/// (selected) and any interactive pill under the pointer lighten toward white,
/// so the state is obvious at a glance while nothing on the chip is
/// translucent.
///
/// * When [onSelected] is provided the chip acts as a filter: tapping toggles
///   [selected] (the pill lightens when selected).
/// * When [onPressed] is provided the chip is tappable (action-style).
/// * When [onDeleted] is provided a hover/touch delete affordance (×) is
///   overlaid on the chip — it reserves no extra space and only appears when
///   the chip is hovered (mouse) or touched (touch/stylus).
///
/// Interactive pills (any handler) lighten on hover and show a click cursor on
/// mouse platforms; display-only pills stay inert (no hover feedback).
///
/// The visual palette is always the same — the same tag always looks the
/// same regardless of which surface it appears on.
class TagChip extends StatefulWidget {
  const TagChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onSelected,
    this.onPressed,
    this.onDeleted,
  });

  final String label;

  /// Selection state for filter chips: when selected the pill is filled with a
  /// stronger tint and a fully-opaque ring so the active filter is obvious at
  /// a glance.
  final bool selected;

  /// When non-null the chip is interactive: tapping toggles [selected].
  /// This turns the chip into a filter chip.
  final ValueChanged<bool>? onSelected;

  /// When non-null the chip is tappable (action-style, no selection state).
  final VoidCallback? onPressed;

  /// When non-null a hover/touch delete affordance (×) is overlaid on top of
  /// the chip — no extra space is reserved. The cross appears centered on the
  /// chip only while hovering (mouse) or after a touch interaction.
  final VoidCallback? onDeleted;

  @override
  State<TagChip> createState() => _TagChipState();
}

class _TagChipState extends State<TagChip> {
  /// Whether a mouse pointer is hovering this pill. Interactive pills
  /// brighten slightly so the affordance reads as live.
  bool _hovering = false;

  bool get _interactive =>
      widget.onSelected != null ||
      widget.onPressed != null ||
      widget.onDeleted != null;

  void _handleTap() {
    if (widget.onSelected != null) {
      widget.onSelected!(!widget.selected);
    } else if (widget.onPressed != null) {
      widget.onPressed!();
    }
    // onDeleted is handled by the overlay TagDeleteIcon, not the pill itself.
  }

  @override
  Widget build(BuildContext context) {
    final color = tagColorFor(widget.label);

    // The grid-tile overlay look: a fully-opaque fill of the tag's own color
    // with an opaque tag-colored ring and white label — the visual every
    // surface now shares. Nothing here is translucent.
    final background = widget.selected
        ? Color.lerp(color, Colors.white, 0.38)!
        : color;
    final borderColor = widget.selected
        ? Color.lerp(color, Colors.white, 0.42)!
        : Color.lerp(color, Colors.white, 0.12)!;
    final labelStyle = TextStyle(
      fontSize: 11.5,
      color: Colors.white,
      fontWeight: FontWeight.w600,
      height: 1,
      shadows: const [Shadow(color: Colors.black45, blurRadius: 3)],
    );

    // Hover feedback: interactive pills (and the active filter under the
    // pointer) lighten their fill and ring toward white; display-only pills
    // stay exactly the same on hover. A selected pill keeps lightening on
    // hover too (it never reads as de-selected).
    final hoverBackground = widget.selected
        ? Color.lerp(color, Colors.white, 0.52)!
        : Color.lerp(color, Colors.white, 0.22)!;
    final hoverBorder = widget.selected
        ? Color.lerp(color, Colors.white, 0.55)!
        : Color.lerp(color, Colors.white, 0.28)!;

    final pill = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      // Compact pill, slightly taller than the original chips so the white
      // label breathes (the user-tuned vertical padding stays).
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: _hovering && _interactive ? hoverBackground : background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: _hovering && _interactive ? hoverBorder : borderColor,
        ),
      ),
      child: Text(
        widget.label,
        style: labelStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

    // Display-only chip: no hover affordance, no cursor, no tap handling.
    if (!_interactive) {
      return pill;
    }

    // Interactive chip: hover feedback + click cursor on the pill, plus tap
    // handling. No key is set here — the widget's own key (e.g.
    // `filter-$tag`) lives on the TagChip element, so find-by-key resolve this
    // chip exactly once.
    final tap = GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        cursor: SystemMouseCursors.click,
        child: pill,
      ),
    );

    // Delete-able chip: overlay the hover-reveal × on top. Its own
    // MouseRegion tracks the × independently for the reveal, so the outer
    // region only brightens the pill while the × sits above it.
    if (widget.onDeleted != null) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          tap,
          Positioned.fill(
            child: TagDeleteIcon(
              color: color,
              onDeleted: widget.onDeleted!,
            ),
          ),
        ],
      );
    }

    return tap;
  }
}

/// Read a [HighlightSpan]'s byte range as ints for slicing a snippet substring.
(int, int) spanRange(HighlightSpan span) =>
    (span.start.toInt(), span.end.toInt());

/// The delete (×) affordance for a tag chip that supports removal.
///
/// This widget is designed to sit as a [Positioned.fill] child inside a
/// [Stack] wrapping a chip — it occupies the chip's full area but reserves
/// **no extra layout space**. The × appears as a small light-gray circle
/// centered on the chip.
///
/// Desktop (mouse pointer) users get a clean chip that reveals the × **only on
/// hover** (`MouseRegion`), keeping the tag row compact and uncluttered; touch
/// platforms always show the × after the first touch so the delete action stays
/// reachable.
class TagDeleteIcon extends StatefulWidget {
  const TagDeleteIcon({
    super.key,
    required this.color,
    required this.onDeleted,
  });

  /// The tag's deterministic color, used for the cross icon tint.
  final Color color;

  /// Called when the user taps the × to remove the tag.
  final VoidCallback onDeleted;

  @override
  State<TagDeleteIcon> createState() => _TagDeleteIconState();
}

class _TagDeleteIconState extends State<TagDeleteIcon> {
  bool _hovering = false;

  /// Whether a non-mouse pointer (touch/stylus) has interacted so far.
  ///
  /// There is no declarative "is this device touch-only?" in `MediaQuery` on
  /// desktop, so we watch incoming pointer events instead: a touch/stylus
  /// `PointerDown` marks the device as touch and keeps the × always visible
  /// (the delete action stays reachable); a pure mouse device stays clean
  /// until hover.
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
        cursor: visible ? SystemMouseCursors.click : MouseCursor.defer,
        // The tap handler stays *above* the visibility gate so a touch that
        // reveals the × also registers as the deletion (matching the chip's
        // original single-tap-to-delete behavior); only the visual circle is
        // hidden/ignored until hover or touch.
        child: GestureDetector(
          onTap: widget.onDeleted,
          // Always hit-testable even while the inner visual is hidden/ignored,
          // so a touch that reveals the × still registers as the deletion.
          behavior: HitTestBehavior.opaque,
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: Center(
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE0E0E0), // light-gray circle
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.clear,
                    size: 12,
                    color: widget.color.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ),
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

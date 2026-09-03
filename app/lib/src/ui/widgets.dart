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
/// Selection lightens the fill toward white; hovering lightens **nothing** and
/// never swaps the cursor to a pointer — the delete × on removable chips is
/// the sole hover affordance. Nothing on the chip is translucent.
///
/// * When [onSelected] is provided the chip acts as a filter: tapping toggles
///   [selected] (the pill lightens when selected).
/// * When [onPressed] is provided the chip is tappable (action-style).
/// * When [onDeleted] is provided a hover/touch delete affordance (×) is
///   overlaid flush against the pill's **right edge** — it reserves no extra
///   space and only appears when the chip is hovered (mouse) or touched
///   (touch/stylus). The × has no circular disc: a gradient scrim fades the
///   label tail into the pill fill so the cross reads as part of the pill.
///
/// Interactive pills (any handler) never lighten on hover nor show a click
/// cursor; display-only pills stay inert (nothing distinguishes them until
/// tapped).
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

  /// When non-null a hover/touch delete affordance (×) is overlaid flush
  /// against the pill's **right edge** — no extra space is reserved, and there
  /// is no circular disc: a gradient scrim fades the label tail into the pill
  /// fill so the cross reads as part of the pill. It appears only while
  /// hovering (mouse) or after a touch interaction.
  final VoidCallback? onDeleted;

  @override
  State<TagChip> createState() => _TagChipState();
}

class _TagChipState extends State<TagChip> {
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

    final pill = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      // Compact pill, slightly taller than the original chips so the white
      // label breathes (the user-tuned vertical padding stays).
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        widget.label,
        style: labelStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

    // Display-only chip: inert — no tap handling, no cursor.
    if (!_interactive) {
      return pill;
    }

    // Interactive chip: tap handling only. No hover feedback and no click
    // cursor — the delete × on removable chips is the sole hover affordance.
    // No key is set here — the widget's own key (e.g. `filter-$tag`) lives on
    // the TagChip element, so find-by-key resolve this chip exactly once.
    final tap = GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: pill,
    );

    // Delete-able chip: overlay the hover-reveal × flush against the pill's
    // right edge. Its own MouseRegion tracks the × independently for the
    // reveal, so the pill itself stays constant on hover.
    if (widget.onDeleted != null) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          tap,
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: _kDeleteAffordanceWidth,
            child: TagDeleteIcon(
              background: background,
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

/// Width of the delete affordance lane laid over a chip's right edge.
///
/// The overlay is a thin strip (no reserved layout space, no rounded
/// container): the cross inside it is a bare white × over the gradient scrim.
const double _kDeleteAffordanceWidth = 22;

/// The delete (×) affordance for a tag chip that supports removal.
///
/// This widget sits as a [Positioned] strip flush against a chip's **right
/// edge** inside a [Stack] — it reserves **no extra layout space** and draws
/// no circle/disc. When visible it fades in a white × (soft shadow) over a
/// horizontal gradient scrim that blends from the pill's own fill to
/// transparent ([background] → transparent rightward), so the label tail
/// visibly dims under the affordance while the strip stays visually attached
/// to the pill.
///
/// Desktop (mouse pointer) users get a clean chip that reveals the × **only on
/// hover** (`MouseRegion`), keeping the tag row compact and uncluttered; touch
/// platforms always show the × after the first touch so the delete action stays
/// reachable.
class TagDeleteIcon extends StatefulWidget {
  const TagDeleteIcon({
    super.key,
    required this.background,
    required this.onDeleted,
  });

  /// The current pill fill (resting or hover-lightened) used as the opaque end
  /// of the fade-out scrim that dims the label tail behind the cross.
  final Color background;

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
        // original single-tap-to-delete behavior); only the visual scrim +
        // cross are hidden/ignored until hover or touch.
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
              // A full-width lane: the scrim is the background, the bare ×
              // floats over it — no circle, no disc.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // The dim: a horizontal gradient that starts fully opaque
                  // with the pill's own fill (matching the pill background, so
                  // the seam is invisible) and fades to transparent rightward,
                  // so the label tail under the × is gradiently dimmed.
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      widget.background,
                      widget.background.withValues(alpha: 0),
                    ],
                  ),
                ),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.clear,
                      size: 12,
                      color: Colors.white,
                      shadows: const [
                        Shadow(color: Colors.black54, blurRadius: 4),
                      ],
                    ),
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

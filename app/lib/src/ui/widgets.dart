/// Rendering helpers shared across the search/chat UI.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:super_clipboard/super_clipboard.dart'
    show FileFormat, Formats, SimpleFileFormat, VirtualFileStorage;
import 'package:super_drag_and_drop/super_drag_and_drop.dart'
    show DragItem, DragItemWidget, DropOperation, DraggableWidget;

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
  Color(0xFFBF360C), // deep orange 900
  Color(0xFF00695C), // teal 800
  Color(0xFF1565C0), // blue 800
  Color(0xFFAD1457), // pink 800
  Color(0xFF2E7D32), // green 800
  Color(0xFF283593), // indigo 800
  Color(0xFFC62828), // red 800
  Color(0xFF6A1B9A), // purple 800
  Color(0xFF00838F), // cyan 800
  Color(0xFF4E342E), // brown 800
  Color(0xFF558B2F), // light green 800
  Color(0xFF0277BD), // light blue 800
  Color(0xFFEF6C00), // orange 800
  Color(0xFF7B1FA2), // purple 700
  Color(0xFF37474F), // blue grey 800
  Color(0xFF5D4037), // brown 700
  Color(0xFF1976D2), // blue 700
  Color(0xFFD81B60), // pink 700
  Color(0xFF388E3C), // green 700
  Color(0xFF512DA8), // deep purple 700
  Color(0xFFD32F2F), // red 700
  Color(0xFF4527A0), // deep purple 800
  Color(0xFF00897B), // teal 700
  Color(0xFF827717), // lime 900
  Color(0xFFF57F17), // yellow 900
  Color(0xFFE91E63), // pink 600
  Color(0xFF9C27B0), // purple 600
  Color(0xFF3F51B5), // indigo 500
  Color(0xFF2196F3), // blue 500
  Color(0xFF009688), // teal 500
  Color(0xFF4CAF50), // green 500
  Color(0xFFFF9800), // orange 500
  Color(0xFF607D8B), // blue grey 500
  Color(0xFF78909C), // blue grey 400
  Color(0xFFEF5350), // red 400
  Color(0xFFAB47BC), // purple 300
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
    this.onEdit,
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

  /// When non-null a hover/touch edit affordance (✎) is overlaid flush
  /// against the pill's **left edge** — no extra space is reserved, and there
  /// is no circular disc: a gradient scrim fades the label start into the pill
  /// fill so the pencil reads as part of the pill. It appears only while
  /// hovering (mouse) or after a touch interaction.
  final VoidCallback? onEdit;

  @override
  State<TagChip> createState() => _TagChipState();
}

class _TagChipState extends State<TagChip> {
  /// Segment index currently under the pointer (compressed split pills only).
  int? _hoverSegment;

  /// Hit-tests pill hover: gaps between segments keep the last state so the
  /// layout never oscillates while the cursor crosses dividers.
  final GlobalKey _rowKey = GlobalKey();

  /// A non-mouse pointer touched the chip: drop compression and show the
  /// full split pill — touch users have no hover to expand segments with.
  bool _touchInteraction = false;

  bool get _interactive =>
      widget.onSelected != null ||
      widget.onPressed != null ||
      widget.onDeleted != null ||
      widget.onEdit != null;

  void _handleTap() {
    if (widget.onSelected != null) {
      widget.onSelected!(!widget.selected);
    } else if (widget.onPressed != null) {
      widget.onPressed!();
    }
    // onDeleted is handled by the overlay TagDeleteIcon, not the pill itself.
  }

  double _textWidth(BuildContext context, String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
    )..layout();
    return tp.width;
  }

  /// The longest prefix of [text] whose rendered width fits [width]. Every
  /// cut is marked with `…` when the glyph fits; single-letter collapses are
  /// untouched automatically (a letter plus the ellipsis never fits the
  /// letter's own width).
  String _prefixFitting(
    BuildContext context,
    String text,
    TextStyle style,
    double width,
  ) {
    if (width <= 0) return '';
    if (_textWidth(context, text, style) <= width) return text;
    bool fits(String s) => _textWidth(context, s, style) <= width;
    if (fits('…')) {
      var lo = 0, hi = text.length;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (fits('${text.substring(0, mid)}…')) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      if (lo > 0) return '${text.substring(0, lo)}…';
    }
    var lo = 0, hi = text.length;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (fits(text.substring(0, mid))) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return text.substring(0, lo);
  }

  /// Compressed hierarchical pill (desktop):
  ///
  /// * rest — parents collapse to one letter (plus any prefix the reserved
  ///   spare allows), the leaf shows in full flush with the rounded edge;
  /// * hovering a parent expands it to its full name and re-splits the rest
  ///   fairly (nearest neighbours first) — the leaf shrinks and cuts
  ///   mid-word with an ellipsis; hovering the leaf restores the resting
  ///   layout exactly;
  /// * the pill width is FIXED to the widest state; every block box carries
  ///   a small right "room" baked into the width math, so glyph advance
  ///   drift and the text shadow never shave the last letter and boxes meet
  ///   edge-to-edge with no dead gaps;
  /// * when the incoming width is tighter than the natural pill, the shared
  ///   text budget shrinks to fit: the leaf is cut first, then parents, each
  ///   truncated segment ending in an ellipsis — the pill always fits;
  /// * no per-block clipping and no scaling — layout is exact.
  Widget _buildCompressedSplitPill(
    BuildContext context,
    List<String> segments,
    TextStyle labelStyle,
    double maxWidth,
  ) {
    const pad = 8.0;
    const blockPadding = pad * 2;
    final parentCount = segments.length - 1;
    final letters = <double>[
      for (var i = 0; i < parentCount; i++)
        _textWidth(context, segments[i][0], labelStyle),
    ];
    final fulls = <double>[
      for (var i = 0; i < parentCount; i++)
        _textWidth(context, segments[i], labelStyle),
    ];
    final leafWidth = _textWidth(context, segments.last, labelStyle);
    final leafLetter = _textWidth(context, segments.last[0], labelStyle);
    final dividers = 1.0 * (segments.length - 1);
    final core = segments.length * blockPadding + dividers;
    final letterSum = letters.fold<double>(0, (a, b) => a + b);

    // Right-side room per block: absorbs real-font advance drift and part of
    // the drop-shadow. Folded into the fixed width so it costs nothing at
    // the edges. Parents keep it tight — it reads as padding before the
    // divider. The leaf block already carries the same right padding (8) a
    // plain pill gives its label, so only a small fixed sliver is added on
    // top: a length-scaled tail would make hierarchical pills trail far more
    // dead space than plain ones and steal width the last glyph needs.
    final roomParent = 1.5;
    final roomLeaf = 4.0;
    final roomSum = roomParent * parentCount + roomLeaf;

    // Fixed pill width: the widest state (rest, or one parent expanded with
    // everything else at its floor) plus the rooms.
    var textMax = letterSum + leafWidth;
    for (var i = 0; i < parentCount; i++) {
      final hoverTotal = fulls[i] + (letterSum - letters[i]) + leafLetter;
      if (hoverTotal > textMax) textMax = hoverTotal;
    }
    var content = core + roomSum + textMax;
    var budget = content - core - roomSum; // shared TEXT width + spare
    // Tight cells (grid tiles): the pill must never exceed the incoming
    // width. Trim the shared text budget to the room that padding and
    // dividers leave; the allocation below then cuts the leaf first, and
    // the parents after it.
    if (maxWidth.isFinite && content > maxWidth) {
      content = maxWidth;
      budget = math.max(content - core - roomSum, 0);
    }

    final texts = List<double>.filled(segments.length, 0);
    final hovered = _hoverSegment;
    final capsAll = <double>[...fulls, leafWidth];
    final floorsAll = <double>[...letters, leafLetter];
    double spare;
    // Hovering the leaf is the resting layout: at rest the leaf already
    // renders in full, so "expanding" it must not re-split the parents.
    if (hovered == null || hovered >= parentCount) {
      for (var i = 0; i < parentCount; i++) {
        texts[i] = letters[i];
      }
      texts[parentCount] = leafWidth;
      spare = budget - letterSum - leafWidth;
      // The leaf must sit flush against the rounded right edge: give any
      // leftover to the parents' prefixes (most expandable first); only
      // what has nowhere to go remains as trailing leaf fill.
      if (spare > 0 && parentCount > 0) {
        final order = <int>[for (var i = 0; i < parentCount; i++) i]
          ..sort(
            (a, b) => (fulls[b] - letters[b]).compareTo(fulls[a] - letters[a]),
          );
        for (final i in order) {
          if (spare <= 0) break;
          final take = math.min(spare, fulls[i] - letters[i]);
          texts[i] += take;
          spare -= take;
        }
      } else if (spare < 0) {
        // Clamped budget: cut the leaf (widest text, most meaningful to
        // abbreviate) down first; only then eat into the one-letter parents.
        var over = -spare;
        final leafCut = math.min(over, texts[parentCount]);
        texts[parentCount] -= leafCut;
        over -= leafCut;
        if (over > 0) {
          final shrinkOrder = <int>[for (var i = 0; i < parentCount; i++) i]
            ..sort((a, b) => letters[b].compareTo(letters[a]));
          for (final i in shrinkOrder) {
            if (over <= 0) break;
            final cut = math.min(over, texts[i]);
            texts[i] -= cut;
            over -= cut;
          }
        }
        spare = 0;
      }
    } else {
      texts[hovered] = capsAll[hovered];
      // Distance-priority greedy split: the NEAREST cell (left neighbour
      // wins ties) expands toward its full word first, then the next, the
      // leaf last — each step only reserving the minimum one-letter floors
      // for the cells behind it. So a hovered left segment lets the middle
      // neighbour reach its full size, and the leaf only takes the width
      // that remains (full word + trailing fill when there is still more).
      final order = <int>[];
      for (var d = 1; d <= segments.length; d++) {
        if (hovered - d >= 0) order.add(hovered - d);
        if (hovered + d <= parentCount) order.add(hovered + d);
      }
      var rem = budget - capsAll[hovered];
      for (var k = 0; k < order.length; k++) {
        final i = order[k];
        final reserve = order
            .sublist(k + 1)
            .fold<double>(0, (a, j) => a + floorsAll[j]);
        final want = rem - reserve;
        texts[i] = want <= floorsAll[i]
            ? floorsAll[i]
            : math.min(capsAll[i], want);
        rem -= texts[i];
      }
      spare = rem;
      if (spare < 0) {
        // Clamped budget: even the hovered word at full plus the letter
        // floors does not fit. Shrink the hovered segment toward its floor
        // (it ellipsizes), then the other parents and the leaf below theirs.
        var over = -spare;
        final hoverCut = math.min(over, texts[hovered] - floorsAll[hovered]);
        texts[hovered] -= hoverCut;
        over -= hoverCut;
        final shrinkOrder = <int>[
          for (var i = 0; i < parentCount; i++)
            if (i != hovered) i,
        ]..sort((a, b) => letters[b].compareTo(letters[a]));
        for (final i in shrinkOrder) {
          if (over <= 0) break;
          final cut = math.min(over, texts[i]);
          texts[i] -= cut;
          over -= cut;
        }
        if (over > 0) {
          final cut = math.min(over, texts[parentCount]);
          texts[parentCount] -= cut;
          over -= cut;
        }
        if (over > 0) {
          // Last resort: the hovered letter rides its own block padding.
          texts[hovered] -= math.min(over, texts[hovered]);
        }
        spare = 0;
      }
    }

    final children = <Widget>[];
    final blockWidths = <double>[];
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) {
        children.add(
          const SizedBox(width: 1, child: ColoredBox(color: Colors.white24)),
        );
      }
      final prefix = segments.sublist(0, i + 1).join('/');
      var blockColor = tagColorFor(prefix);
      if (widget.selected) {
        blockColor = Color.lerp(blockColor, Colors.white, 0.38)!;
      }
      final isLeaf = i == segments.length - 1;
      final room = isLeaf ? roomLeaf : roomParent;
      final shown = _prefixFitting(context, segments[i], labelStyle, texts[i]);
      final width = texts[i] + blockPadding + room + (isLeaf ? spare : 0.0);
      blockWidths.add(width);
      children.add(
        // AnimatedContainer (no clip): the width lerps smoothly and the text
        // — already at its new budget — simply rides the moving edges.
        // AnimatedSize was avoided on purpose: it clips while lerping, which
        // shaved segment glyphs and the rounded ends mid-animation.
        AnimatedContainer(
          key: ValueKey('seg-block-$i'),
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: width,
          decoration: BoxDecoration(color: blockColor),
          padding: const EdgeInsets.symmetric(horizontal: pad, vertical: 5),
          child: Text(
            shown.isEmpty ? segments[i][0] : shown,
            style: labelStyle,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
          ),
        ),
      );
    }
    return SizedBox(
      key: const ValueKey('tag-pill'),
      width: content,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: MouseRegion(
          onExit: (_) {
            if (_hoverSegment != null) {
              setState(() => _hoverSegment = null);
            }
          },
          child: Listener(
            onPointerHover: (event) {
              final ro = _rowKey.currentContext?.findRenderObject();
              if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
              final local = ro.globalToLocal(event.position);
              // Resolve the target segment now, but apply it after the
              // current frame: setState inside the hover callback would run
              // during the mouse-tracker's device-update pass and trip its
              // re-entrancy assertion.
              int? target;
              var x = 0.0;
              for (var i = 0; i < blockWidths.length; i++) {
                if (local.dx >= x && local.dx <= x + blockWidths[i]) {
                  target = i;
                  break;
                }
                x += blockWidths[i] + 1;
              }
              if (target != null && target != _hoverSegment) {
                // Deferred a microtask: applying immediately would rebuild
                // inside the mouse-tracker's device-update pass and trip its
                // re-entrancy assertion.
                scheduleMicrotask(() {
                  if (mounted && _hoverSegment != target) {
                    setState(() => _hoverSegment = target);
                  }
                });
              }
            },
            // The blocks sum EXACTLY to `content` (rooms are baked in); the
            // row is laid out plain — no scaling, no overflow asserts.
            child: Row(
              key: _rowKey,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = tagColorFor(widget.label);
    final isSplit = widget.label.contains('/');

    // Border and overlay background color are based on the FIRST segment's color.
    final firstColor = isSplit
        ? tagColorFor(widget.label.split('/').first)
        : color;
    // Overlay background used by edit/delete grims: lightened when selected.
    final background = widget.selected
        ? Color.lerp(firstColor, Colors.white, 0.38)!
        : firstColor;

    final labelStyle = TextStyle(
      fontSize: 11.5,
      color: Colors.white,
      fontWeight: FontWeight.w600,
      height: 1,
      shadows: const [Shadow(color: Colors.black45, blurRadius: 3)],
    );

    Widget pill;
    if (isSplit) {
      final segments = widget.label.split('/');
      if (!_touchInteraction && _hoverable) {
        // Collapsed letters, single-segment hover expansion, fixed width —
        // but never wider than the cell the chip is placed in (grid tiles
        // bound it with the Wrap's remaining run width).
        return _wrapInteractions(
          context,
          LayoutBuilder(
            builder: (context, constraints) => _buildCompressedSplitPill(
              context,
              segments,
              labelStyle,
              constraints.maxWidth,
            ),
          ),
          background,
        );
      }
      final blockChildren = <Widget>[];
      for (var i = 0; i < segments.length; i++) {
        if (i > 0) {
          blockChildren.add(
            const SizedBox(width: 1, child: ColoredBox(color: Colors.white24)),
          );
        }
        final prefix = segments.sublist(0, i + 1).join('/');
        var blockColor = tagColorFor(prefix);
        if (widget.selected) {
          blockColor = Color.lerp(blockColor, Colors.white, 0.38)!;
        }
        // Blocks hug their text: no alignment (an alignment makes a bounded
        // Container EXPAND to its constraints), no Flexible (flex shares
        // clamp segments to an equal fraction of the run even when the whole
        // pill would fit — that is where stray ellipses came from).
        blockChildren.add(
          Container(
            color: blockColor,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Text(segments[i], style: labelStyle, maxLines: 1),
          ),
        );
      }

      pill = AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        // No border: a border would draw over the segment dividers and
        // break the seamless split look.
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(999)),
        clipBehavior: Clip.antiAlias,
        child: FittedBox(
          // scaleDown: the pill hugs its content (never stretches to the
          // available width), segments render at full size whenever the run
          // allows it, and an oversized pill shrinks slightly instead of
          // cutting text with an ellipsis.
          fit: BoxFit.scaleDown,
          child: IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: blockChildren,
            ),
          ),
        ),
      );
    } else {
      // Single-segment label: exact same look as before, minus the border.
      pill = AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          widget.label,
          style: labelStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return _wrapInteractions(context, pill, background);
  }

  /// Whether the platform provides a persistent pointer for hover (desktop
  /// and web); touch platforms keep full-text pills.
  bool get _hoverable =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  /// Wraps a rendered pill with touch detection and the chip's interactions
  /// (tap, edit/delete edge affordances).
  Widget _wrapInteractions(
    BuildContext context,
    Widget pill,
    Color background,
  ) {
    // A touch interaction anywhere on the chip drops compression — touch
    // users cannot hover segments open.
    if (isSplitLabel) {
      pill = Listener(
        onPointerDown: (event) {
          if (event.kind != PointerDeviceKind.mouse && !_touchInteraction) {
            setState(() => _touchInteraction = true);
          }
        },
        child: pill,
      );
    }
    if (!_interactive) {
      return pill;
    }
    final tap = GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: pill,
    );
    if (widget.onEdit != null || widget.onDeleted != null) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          tap,
          if (widget.onEdit != null)
            Positioned(
              top: 0,
              left: 0,
              bottom: 0,
              width: _kEditAffordanceWidth,
              child: TagEditIcon(
                key: ValueKey('edit-${widget.label}'),
                background: background,
                onEdit: widget.onEdit!,
              ),
            ),
          if (widget.onDeleted != null)
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

  bool get isSplitLabel => widget.label.contains('/');
}

/// Read a [HighlightSpan]'s byte range as ints for slicing a snippet substring.
(int, int) spanRange(HighlightSpan span) =>
    (span.start.toInt(), span.end.toInt());

/// Width of the delete affordance lane laid over a chip's right edge.
///
/// The overlay is a thin strip (no reserved layout space, no rounded
/// container): the cross inside it is a bare white × over the gradient scrim.
const double _kDeleteAffordanceWidth = 22;

/// Width of the edit affordance lane laid over a chip's left edge.
///
/// Mirrors [_kDeleteAffordanceWidth] on the opposite side: a thin strip (no
/// reserved layout space) with a gradient scrim and a compact ✎.
const double _kEditAffordanceWidth = 22;

/// The edit (✎) affordance for a tag chip that supports an action (e.g.
/// renaming).
///
/// This widget sits as a [Positioned] strip flush against a chip's **left
/// edge** inside a [Stack] — it reserves **no extra layout space** and draws
/// no circle/disc. When visible it fades in a white ✎ (soft shadow) over a
/// horizontal gradient scrim that blends from the pill's own fill at the strip's
/// right edge into transparent on the left, so the label start visibly dims
/// under the affordance while the strip stays visually attached to the pill.
///
/// Desktop (mouse pointer) users get a clean chip that reveals the ✎ **only
/// on hover** (`MouseRegion`), keeping the tag row compact and uncluttered;
/// touch platforms always show the ✎ after the first touch so the edit action
/// stays reachable.
class TagEditIcon extends StatefulWidget {
  const TagEditIcon({
    super.key,
    required this.background,
    required this.onEdit,
  });

  final Color background;
  final VoidCallback onEdit;

  @override
  State<TagEditIcon> createState() => _TagEditIconState();
}

class _TagEditIconState extends State<TagEditIcon> {
  bool _hovering = false;
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
        child: GestureDetector(
          onTap: widget.onEdit,
          behavior: HitTestBehavior.opaque,
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      widget.background.withValues(alpha: 0),
                      widget.background,
                    ],
                  ),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.edit,
                      size: 13,
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

/// Wraps [child] in a draggable that exports [documentId]'s raw bytes as a
/// virtual file when dragged out to the OS (Finder/Desktop/etc on macOS).
///
/// Documents are stored in a content-addressed blob store rather than as loose
/// on-disk files, so the drag exports a **virtual file**: the plugin's macOS
/// implementation wraps this in an `NSFilePromiseProvider`, letting the user
/// drop the document onto Finder where the raw bytes (fetched lazily from
/// [readBytes]) are materialized into a real file.
///
/// Returns [child] unchanged when the platform cannot provide a virtual-file
/// drag-out (e.g. Linux/Android tests) so the fallback surface stays intact.
Widget wrapDocumentDragOut({
  required Widget child,
  required String documentId,
  required String fileName,
  String? mimeType,
  required Future<List<int>> Function() readBytes,
}) {
  if (!kIsWeb &&
      defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.windows) {
    return child;
  }
  return DragItemWidget(
    allowedOperations: () => [DropOperation.copy],
    canAddItemToExistingSession: true,
    dragItemProvider: (request) => _documentDragItem(
      documentId: documentId,
      fileName: fileName,
      mimeType: mimeType,
      readBytes: readBytes,
    ),
    child: DraggableWidget(child: child),
  );
}

/// Builds the [DragItem] exported when a document tile is dragged out to the
/// OS (Finder/Desktop/etc).
Future<DragItem?> _documentDragItem({
  required String documentId,
  required String fileName,
  String? mimeType,
  required Future<List<int>> Function() readBytes,
}) async {
  if (!kIsWeb &&
      defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.windows) {
    // Virtual files are currently supported for drag-out on macOS and Windows
    // only; other platforms would provide no useful representation.
    return null;
  }
  final item = DragItem(suggestedName: fileName, localData: documentId);
  item.addVirtualFile(
    format: _kFileFormatForMime(mimeType),
    provider: (sinkProvider, _) async {
      try {
        final bytes = await readBytes();
        final data = Uint8List.fromList(bytes);
        // Some receivers call the provider with a file size hint; forward the
        // actual length so the written file matches the stored blob.
        final sink = sinkProvider(fileSize: data.length);
        sink.add(data);
        sink.close();
      } catch (_) {
        // The drop receiver aborted or the blob could not be read; nothing to
        // write. The drag session simply ends without materializing a file.
      }
    },
    storageSuggestion: VirtualFileStorage.temporaryFile,
  );
  return item;
}

/// A best-effort [FileFormat] for the document's MIME type so the dropped file
/// is tagged with a sensible UTI on macOS / MIME on other platforms. Unknown
/// MIME types fall back to a generic binary data format.
FileFormat _kFileFormatForMime(String? mimeType) {
  if (mimeType == null || mimeType.isEmpty) return _kGenericFileFormat;
  final mime = mimeType.toLowerCase();
  const byMime = <String, FileFormat>{
    'application/pdf': Formats.pdf,
    'image/png': Formats.png,
    'image/jpeg': Formats.jpeg,
    'image/gif': Formats.gif,
    'image/webp': Formats.webp,
    'image/svg+xml': Formats.svg,
    'image/bmp': Formats.bmp,
    'image/tiff': Formats.tiff,
    'image/heic': Formats.heic,
    'image/heif': Formats.heif,
    'text/markdown': Formats.md,
    'text/csv': Formats.csv,
    'application/json': Formats.json,
    'application/zip': Formats.zip,
    'application/gzip': Formats.gzip,
    'application/x-tar': Formats.tar,
    'application/msword': Formats.doc,
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
        Formats.docx,
    'application/epub+zip': Formats.epub,
    'application/vnd.ms-excel': Formats.xls,
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
        Formats.xlsx,
    'application/vnd.ms-powerpoint': Formats.ppt,
    'application/vnd.openxmlformats-officedocument.presentationml.presentation':
        Formats.pptx,
    'text/rtf': Formats.rtf,
    'audio/mpeg': Formats.mp3,
    'audio/mp4': Formats.m4a,
    'audio/ogg': Formats.oga,
    'audio/flac': Formats.flac,
    'video/mp4': Formats.mp4,
    'video/quicktime': Formats.mov,
    'video/x-msvideo': Formats.avi,
    'video/mpeg': Formats.mpeg,
    'video/webm': Formats.webm,
    'video/ogg': Formats.ogg,
    'video/x-matroska': Formats.mkv,
  };
  return byMime[mime] ?? _kGenericFileFormat;
}

/// Generic binary format used when a document's MIME type is unknown, so the
/// virtual file still carries a valid UTI (`public.data`) for the drag.
const FileFormat _kGenericFileFormat = SimpleFileFormat(
  uniformTypeIdentifiers: ['public.data'],
  mimeTypes: ['application/octet-stream'],
);

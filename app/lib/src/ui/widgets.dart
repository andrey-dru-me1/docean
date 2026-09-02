/// Rendering helpers shared across the search/chat UI.
library;

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

/// The washed-out background tint used by tag chips for a given tag name.
Color tagTintFor(String name) => tagColorFor(name).withValues(alpha: 0.16);

/// A compact, colored tag chip with no avatar icon.
///
/// The color is derived deterministically from the tag name (see
/// [tagColorFor]); the background is the tag's tinted hue so dark and light
/// themes both stay readable. Use [BuildContext]-free construction so the same
/// chip can be reused inside `Wrap`s on any surface.
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, this.selected = false});

  final String label;

  /// Selection state for filter chips: when selected the chip is filled with a
  /// stronger tint so the active filter is obvious at a glance.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = tagColorFor(label);
    final background = selected
        ? tagTintFor(label).withValues(alpha: 0.38)
        : tagTintFor(label);
    return Chip(
      visualDensity: VisualDensity.compact,
      backgroundColor: background,
      side: BorderSide(color: color.withValues(alpha: 0.45)),
      labelStyle: TextStyle(
        fontSize: 11.5,
        color: color,
        fontWeight: FontWeight.w600,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      label: Text(label),
      avatar: const SizedBox.shrink(),
    );
  }
}

/// Read a [HighlightSpan]'s byte range as ints for slicing a snippet substring.
(int, int) spanRange(HighlightSpan span) =>
    (span.start.toInt(), span.end.toInt());

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

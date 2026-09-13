import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/tag_hierarchy.dart' show suggestTagCompletions;

/// Reusable tag search field with ranked completions and keyboard-first
/// interaction:
///
/// * completions come from [suggestTagCompletions] (exact → prefix → segment
///   prefix → subsequence — `study/mit/machine-learning` is found by
///   `machine-le`, `ml` or `smml`); the BEST match is highlighted by default;
/// * ArrowDown/ArrowUp move the highlight (wrapping), Enter selects it,
///   Escape closes the panel and keeps the typed text as "my own value":
///   Enter AFTER Escape submits the raw input (free-text mode) instead of a
///   completion; tapping a row selects it too. Arrows are claimed by a
///   Shortcuts+Actions pair around the field (the DropdownMenu desktop
///   pattern), so text-editing caret shortcuts cannot take them;
/// * after a selection the field clears but KEEPS focus, so the next tag can
///   be typed immediately (sequential searching);
/// * when [allowFreeText] is set the panel gains a `Create "<query>"` row —
///   placed under exact matches (index 0 when none) and above the fuzzy
///   ones, hidden when the query already IS a tag; it is reachable by the
///   arrows/tap/Enter like any row, and a [submitValidator] rejection shows
///   the message inline; with no completion at all it is the only row, so
///   Enter creates straight away.
class TagSearchField extends StatefulWidget {
  const TagSearchField({
    super.key,
    required this.allTags,
    required this.onSelected,
    this.allowFreeText = false,
    this.submitValidator,
    this.hintText,
    this.autofocus = false,
    this.maxSuggestions = 8,
    this.textStyle,
    this.contentPadding,
    this.keyPrefix = 'tag-search',
    this.onBlur,
  });

  /// Candidate pool for completions (usually the live tag registry).
  final List<String> allTags;

  /// Called with a trimmed tag when the user picks a completion or
  /// (with [allowFreeText]) submits free text.
  final ValueChanged<String> onSelected;

  /// Whether the panel may offer `Create "<query>"` and Enter-with-no-
  /// completion submits the typed text itself.
  final bool allowFreeText;

  /// Validation for free-text submissions: a non-null return shows the
  /// message inline and suppresses [onSelected].
  final String? Function(String tag)? submitValidator;

  final String? hintText;
  final bool autofocus;
  final int maxSuggestions;

  /// Label typography; defaults to the compact 11.5/w600 pill style.
  final TextStyle? textStyle;

  /// Field inner padding (dense layouts pass compact values).
  final EdgeInsetsGeometry? contentPadding;

  /// Prefix for internal ValueKeys (field, rows, create entry).
  final String keyPrefix;

  /// Notified when the field loses focus (e.g. click-away collapse).
  final VoidCallback? onBlur;

  @override
  State<TagSearchField> createState() => _TagSearchFieldState();
}

class _TagSearchFieldState extends State<TagSearchField> {
  static const double _rowHeight = 32;
  static const int _maxRows = 6;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _anchorKey = GlobalKey();
  final ScrollController _listScroll = ScrollController();

  OverlayEntry? _overlay;
  List<_SugRow> _rows = const [];
  int _active = 0;
  String? _error;

  /// Field width captured at the moment the panel opens (safe to read the
  /// render box during an event handler, NOT during the overlay's build).
  double _popupWidth = 240;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    // The node handles Escape only; arrows go through the Shortcuts+Actions
    // pair in build(), which reliably beats the caret shortcuts on macOS.
    _focusNode.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    _overlay?.remove();
    _focusNode.removeListener(_onFocusChange);
    _listScroll.dispose();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) {
      _hideOverlay();
      // Defer the click-away report by one frame: TextInputAction.done
      // blurs the field momentarily; if focus returns (selection refocuses,
      // or an error keeps the field open) the composer must NOT collapse.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) widget.onBlur?.call();
      });
      return;
    }
    if (mounted) setState(() {});
  }

  void _onChanged(String value) {
    _error = null;
    final matches = suggestTagCompletions(
      value,
      widget.allTags,
      limit: widget.maxSuggestions,
    );
    final query = value.trim();
    // Offer "create" whenever free text is allowed and no EXACT tag match
    // exists (creating an existing name would be a silent no-op). The row
    // sits under the exact matches — which is index 0 when there are none —
    // above the fuzzy ones.
    final exactExists =
        query.isNotEmpty &&
        widget.allTags.any((t) => t.toLowerCase() == query.toLowerCase());
    _rows = <_SugRow>[
      if (widget.allowFreeText && !exactExists && query.isNotEmpty)
        const _SugRow.create(),
      for (final m in matches) _SugRow.tag(m),
    ];
    // Default highlight: the best REAL match, so Enter keeps behaving like
    // "pick the top suggestion"; the create row is one arrow away.
    final firstTag = _rows.indexWhere((r) => !r.create);
    _active = firstTag < 0 ? 0 : firstTag;
    if (_rows.isEmpty) {
      _hideOverlay();
    } else {
      _showOrUpdateOverlay();
    }
    setState(() {});
  }

  void _select(String tag) {
    _hideOverlay();
    _controller.clear();
    _rows = const [];
    _error = null;
    setState(() {});
    // Keep the caret hot for sequential typing.
    _focusNode.requestFocus();
    widget.onSelected(tag.trim());
  }

  /// Picks the row currently under the highlight (tag or create).
  void _pickAt(int index) {
    if (_rows.isEmpty) return;
    final row = _rows[index.clamp(0, _rows.length - 1)];
    if (row.create) {
      _submitFreeText();
    } else {
      _select(row.tag!);
    }
  }

  /// Validates and submits the raw input as a new tag name.
  void _submitFreeText() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final err = widget.submitValidator?.call(text);
    if (err != null) {
      setState(() => _error = err);
      // A rejected submit keeps the caret hot (done-actions blur first).
      _focusNode.requestFocus();
      return;
    }
    _select(text);
  }

  void _submit() {
    // Only while the panel is actually OPEN does Enter pick the highlighted
    // row; after Escape dismissed it, Enter means "use my text" directly.
    if (_overlay != null && _rows.isNotEmpty) {
      _pickAt(_active);
      return;
    }
    if (widget.allowFreeText) _submitFreeText();
  }

  /// Escape closes the panel (a second Escape unfocuses = collapse). Arrows
  /// are claimed by the Shortcuts+Actions pair wrapped around the field —
  /// the pattern DropdownMenu uses on desktop, because node-level key
  /// handling loses to the text-input pipeline on real macOS. Enter arrives
  /// via onSubmitted.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_overlay != null) {
        _hideOverlay();
      } else {
        // Esc with no panel is the "collapse" gesture (inline composers).
        _focusNode.unfocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveActive(int delta) {
    if (_overlay == null || _rows.isEmpty) return;
    _setActive((_active + delta + _rows.length) % _rows.length);
  }

  /// Points the highlight at [index] (keyboard arrows and mouse hover both
  /// route here). The overlay entry is an independent subtree: it needs
  /// markNeedsBuild, not just setState, or the drawn highlight stays stale.
  void _setActive(int index) {
    if (_overlay == null || index == _active) return;
    _active = index;
    _overlay!.markNeedsBuild();
    setState(() {});
    _scrollActiveIntoView();
  }

  void _scrollActiveIntoView() {
    if (!_listScroll.hasClients) return;
    final viewport = _rowHeight * math.min(_rows.length, _maxRows);
    final top = _active * _rowHeight;
    final bottom = top + _rowHeight;
    final offset = _listScroll.offset;
    if (top < offset) {
      _listScroll.jumpTo(math.max(0, top));
    } else if (bottom > offset + viewport) {
      _listScroll.jumpTo(bottom - viewport);
    }
  }

  void _showOrUpdateOverlay() {
    // Measure the field while still inside the change handler (render box has
    // a valid size from the previous frame; reading it in the overlay builder
    // would crash with "Cannot get size during build").
    final renderBox =
        _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      _popupWidth = renderBox.size.width;
    }
    if (_overlay == null) {
      _overlay = OverlayEntry(builder: (_) => _buildOverlay());
      Overlay.of(context, rootOverlay: true).insert(_overlay!);
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void _hideOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  Widget _buildOverlay() {
    final scheme = Theme.of(context).colorScheme;
    final anchorWidth = _popupWidth;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 4),
            // Shares the default EditableText tap-group with the field, so a
            // tap on the panel counts as INSIDE the field: no focus loss, the
            // row's tap-up registers before _select tears the panel down.
            child: TextFieldTapRegion(
              child: Material(
                elevation: 6,
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(6),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: anchorWidth,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: _rowHeight * _maxRows,
                    ),
                    child: ListView.builder(
                      controller: _listScroll,
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: _rows.length,
                      itemBuilder: (context, index) {
                        final row = _rows[index];
                        final active = index == _active;
                        if (row.create) {
                          final query = _controller.text.trim();
                          return MouseRegion(
                            onEnter: (_) => _setActive(index),
                            child: GestureDetector(
                              onTap: _submitFreeText,
                              child: Container(
                                key: ValueKey('${widget.keyPrefix}-create'),
                                height: _rowHeight,
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                color: active
                                    ? scheme.primary.withValues(alpha: 0.18)
                                    : null,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.add_circle_outline,
                                      size: 16,
                                      color: scheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Create "$query"',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style:
                                            (widget.textStyle ??
                                                    Theme.of(
                                                      context,
                                                    ).textTheme.bodyMedium)
                                                ?.copyWith(
                                                  color: scheme.primary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }
                        final tag = row.tag!;
                        return MouseRegion(
                          onEnter: (_) => _setActive(index),
                          child: GestureDetector(
                            onTap: () => _select(tag),
                            child: Container(
                              key: ValueKey(
                                '${widget.keyPrefix}-suggestion-$tag',
                              ),
                              height: _rowHeight,
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              color: active
                                  ? scheme.primary.withValues(alpha: 0.18)
                                  : null,
                              // Long paths are ellipsized to one line; the
                              // tooltip keeps the full tag readable.
                              child: Tooltip(
                                message: tag,
                                child: Text(
                                  tag,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      (widget.textStyle ??
                                              Theme.of(
                                                context,
                                              ).textTheme.bodyMedium)
                                          ?.copyWith(
                                            fontWeight: FontWeight.w500,
                                          ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Comfortable pill: roomier than the 24px tag chips it complements, no
    // leading icon, stadium border, subtle fill so it reads as an inline
    // affordance rather than a form field.
    final shape = BorderRadius.circular(999);
    OutlineInputBorder stadiumBorder({Color? color}) => OutlineInputBorder(
      borderRadius: shape,
      borderSide: color == null
          ? BorderSide.none
          : BorderSide(color: color, width: 1),
    );
    final textStyle =
        widget.textStyle ??
        const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ).copyWith(color: scheme.onSurface);
    // Arrows → custom intents handled above the text-input shortcuts
    // (DropdownMenu's desktop pattern): the pair sits OUTSIDE the field so
    // its Actions resolve the intents before EditableText moves the caret.
    return Actions(
      actions: <Type, Action<Intent>>{
        _ArrowUpIntent: CallbackAction<_ArrowUpIntent>(
          onInvoke: (_) {
            _moveActive(-1);
            return null;
          },
        ),
        _ArrowDownIntent: CallbackAction<_ArrowDownIntent>(
          onInvoke: (_) {
            _moveActive(1);
            return null;
          },
        ),
      },
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowUp): _ArrowUpIntent(),
          SingleActivator(LogicalKeyboardKey.arrowDown): _ArrowDownIntent(),
        },
        child: CompositedTransformTarget(
          key: _anchorKey,
          link: _layerLink,
          child: TextField(
            key: ValueKey('${widget.keyPrefix}-field'),
            controller: _controller,
            focusNode: _focusNode,
            autofocus: widget.autofocus,
            style: textStyle,
            onChanged: _onChanged,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: widget.hintText,
              hintStyle: textStyle.copyWith(
                fontWeight: FontWeight.w400,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              contentPadding:
                  widget.contentPadding ??
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              errorText: _error,
              errorStyle: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontSize: 11,
              ),
              border: stadiumBorder(color: scheme.outlineVariant),
              enabledBorder: stadiumBorder(color: scheme.outlineVariant),
              focusedBorder: stadiumBorder(color: scheme.primary),
              errorBorder: stadiumBorder(color: scheme.error),
              focusedErrorBorder: stadiumBorder(color: scheme.error),
            ),
          ),
        ),
      ),
    );
  }
}

/// Local intents for suggestion-list navigation (mapped via [Shortcuts] so
/// they are claimed before the text-input caret shortcuts).
class _ArrowUpIntent extends Intent {
  const _ArrowUpIntent();
}

class _ArrowDownIntent extends Intent {
  const _ArrowDownIntent();
}

/// One dropdown row: an existing-tag completion or the create-new entry.
class _SugRow {
  const _SugRow.tag(this.tag) : create = false;
  const _SugRow.create() : tag = null, create = true;

  final String? tag;
  final bool create;
}

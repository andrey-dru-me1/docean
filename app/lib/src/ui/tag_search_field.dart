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
///   Escape closes the panel; tapping a row selects it too;
/// * after a selection the field clears but KEEPS focus, so the next tag can
///   be typed immediately (sequential searching);
/// * when [allowFreeText] is set, Enter with no completion submits the raw
///   input; a [submitValidator] rejection shows the message inline.
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

  /// Whether Enter with no completion submits the typed text itself.
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

  /// Prefix for internal ValueKeys (field, rows).
  final String keyPrefix;

  /// Notified when the field loses focus (e.g. click-away collapse).
  final VoidCallback? onBlur;

  @override
  State<TagSearchField> createState() => _TagSearchFieldState();
}

class _TagSearchFieldState extends State<TagSearchField> {
  static const double _rowHeight = 28;
  static const int _maxRows = 6;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _anchorKey = GlobalKey();
  final ScrollController _listScroll = ScrollController();

  OverlayEntry? _overlay;
  List<String> _matches = const [];
  int _active = 0;
  String? _error;

  /// Field width captured at the moment the panel opens (safe to read the
  /// render box during an event handler, NOT during the overlay's build).
  double _popupWidth = 240;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
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
    _matches = suggestTagCompletions(
      value,
      widget.allTags,
      limit: widget.maxSuggestions,
    );
    _active = 0;
    if (_matches.isEmpty) {
      _hideOverlay();
    } else {
      _showOrUpdateOverlay();
    }
    setState(() {});
  }

  void _select(String tag) {
    _hideOverlay();
    _controller.clear();
    _matches = const [];
    _error = null;
    setState(() {});
    // Keep the caret hot for sequential typing.
    _focusNode.requestFocus();
    widget.onSelected(tag.trim());
  }

  void _submit() {
    if (_matches.isNotEmpty) {
      _select(_matches[math.min(_active, _matches.length - 1)]);
      return;
    }
    final text = _controller.text.trim();
    if (widget.allowFreeText && text.isNotEmpty) {
      final err = widget.submitValidator?.call(text);
      if (err != null) {
        setState(() => _error = err);
        // A rejected submit keeps the caret hot (done-actions blur first).
        _focusNode.requestFocus();
        return;
      }
      _select(text);
    }
  }

  /// Arrows/Escape bubble here from the field's internal focus node; Enter
  /// is consumed by the field itself and arrives via onSubmitted.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_matches.isNotEmpty && _overlay != null) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() => _active = (_active + 1) % _matches.length);
        _scrollActiveIntoView();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(
          () => _active = (_active - 1 + _matches.length) % _matches.length,
        );
        _scrollActiveIntoView();
        return KeyEventResult.handled;
      }
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

  void _scrollActiveIntoView() {
    if (!_listScroll.hasClients) return;
    final viewport = _rowHeight * math.min(_matches.length, _maxRows);
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
            // Treat taps on the panel as *inside* the field: without this the
            // focus manager unfocuses the field on tap-down, collapsing the
            // panel before the row's tap-up can register the selection.
            // Shares the default EditableText tap-group with the field, so a
            // tap on the panel counts as INSIDE the field: no focus loss, the
            // row's tap-up registers the selection before _select tears down.
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
                      itemCount: _matches.length,
                      itemBuilder: (context, index) {
                        final tag = _matches[index];
                        final active = index == _active;
                        return GestureDetector(
                          onTap: () => _select(tag),
                          child: Container(
                            key: ValueKey(
                              '${widget.keyPrefix}-suggestion-$tag',
                            ),
                            height: _rowHeight,
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            color: active
                                ? scheme.primary.withValues(alpha: 0.18)
                                : null,
                            child: Text(
                              tag,
                              style:
                                  (widget.textStyle ??
                                          Theme.of(
                                            context,
                                          ).textTheme.bodyMedium)
                                      ?.copyWith(fontWeight: FontWeight.w500),
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
    // Compact pill: same height as TagChip pills (~24px), no leading icon,
    // stadium border, subtle fill so it reads as an inline affordance rather
    // than a form field.
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
    return CompositedTransformTarget(
      link: _layerLink,
      child: Focus(
        key: _anchorKey,
        onKeyEvent: _onKey,
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
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
    );
  }
}

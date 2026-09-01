// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'ingest.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

/// @nodoc
mixin _$ProgressEvent {
  String get fileName => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileName) processing,
    required TResult Function(String fileName, int percent) extracting,
    required TResult Function(String fileName, String documentId) completed,
    required TResult Function(String fileName, String error) failed,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileName)? processing,
    TResult? Function(String fileName, int percent)? extracting,
    TResult? Function(String fileName, String documentId)? completed,
    TResult? Function(String fileName, String error)? failed,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileName)? processing,
    TResult Function(String fileName, int percent)? extracting,
    TResult Function(String fileName, String documentId)? completed,
    TResult Function(String fileName, String error)? failed,
    required TResult orElse(),
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(ProgressEvent_Processing value) processing,
    required TResult Function(ProgressEvent_Extracting value) extracting,
    required TResult Function(ProgressEvent_Completed value) completed,
    required TResult Function(ProgressEvent_Failed value) failed,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(ProgressEvent_Processing value)? processing,
    TResult? Function(ProgressEvent_Extracting value)? extracting,
    TResult? Function(ProgressEvent_Completed value)? completed,
    TResult? Function(ProgressEvent_Failed value)? failed,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(ProgressEvent_Processing value)? processing,
    TResult Function(ProgressEvent_Extracting value)? extracting,
    TResult Function(ProgressEvent_Completed value)? completed,
    TResult Function(ProgressEvent_Failed value)? failed,
    required TResult orElse(),
  }) => throw _privateConstructorUsedError;

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ProgressEventCopyWith<ProgressEvent> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ProgressEventCopyWith<$Res> {
  factory $ProgressEventCopyWith(
    ProgressEvent value,
    $Res Function(ProgressEvent) then,
  ) = _$ProgressEventCopyWithImpl<$Res, ProgressEvent>;
  @useResult
  $Res call({String fileName});
}

/// @nodoc
class _$ProgressEventCopyWithImpl<$Res, $Val extends ProgressEvent>
    implements $ProgressEventCopyWith<$Res> {
  _$ProgressEventCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? fileName = null}) {
    return _then(
      _value.copyWith(
            fileName: null == fileName
                ? _value.fileName
                : fileName // ignore: cast_nullable_to_non_nullable
                      as String,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$ProgressEvent_ProcessingImplCopyWith<$Res>
    implements $ProgressEventCopyWith<$Res> {
  factory _$$ProgressEvent_ProcessingImplCopyWith(
    _$ProgressEvent_ProcessingImpl value,
    $Res Function(_$ProgressEvent_ProcessingImpl) then,
  ) = __$$ProgressEvent_ProcessingImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String fileName});
}

/// @nodoc
class __$$ProgressEvent_ProcessingImplCopyWithImpl<$Res>
    extends _$ProgressEventCopyWithImpl<$Res, _$ProgressEvent_ProcessingImpl>
    implements _$$ProgressEvent_ProcessingImplCopyWith<$Res> {
  __$$ProgressEvent_ProcessingImplCopyWithImpl(
    _$ProgressEvent_ProcessingImpl _value,
    $Res Function(_$ProgressEvent_ProcessingImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? fileName = null}) {
    return _then(
      _$ProgressEvent_ProcessingImpl(
        fileName: null == fileName
            ? _value.fileName
            : fileName // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc

class _$ProgressEvent_ProcessingImpl extends ProgressEvent_Processing {
  const _$ProgressEvent_ProcessingImpl({required this.fileName}) : super._();

  @override
  final String fileName;

  @override
  String toString() {
    return 'ProgressEvent.processing(fileName: $fileName)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ProgressEvent_ProcessingImpl &&
            (identical(other.fileName, fileName) ||
                other.fileName == fileName));
  }

  @override
  int get hashCode => Object.hash(runtimeType, fileName);

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ProgressEvent_ProcessingImplCopyWith<_$ProgressEvent_ProcessingImpl>
  get copyWith =>
      __$$ProgressEvent_ProcessingImplCopyWithImpl<
        _$ProgressEvent_ProcessingImpl
      >(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileName) processing,
    required TResult Function(String fileName, int percent) extracting,
    required TResult Function(String fileName, String documentId) completed,
    required TResult Function(String fileName, String error) failed,
  }) {
    return processing(fileName);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileName)? processing,
    TResult? Function(String fileName, int percent)? extracting,
    TResult? Function(String fileName, String documentId)? completed,
    TResult? Function(String fileName, String error)? failed,
  }) {
    return processing?.call(fileName);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileName)? processing,
    TResult Function(String fileName, int percent)? extracting,
    TResult Function(String fileName, String documentId)? completed,
    TResult Function(String fileName, String error)? failed,
    required TResult orElse(),
  }) {
    if (processing != null) {
      return processing(fileName);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(ProgressEvent_Processing value) processing,
    required TResult Function(ProgressEvent_Extracting value) extracting,
    required TResult Function(ProgressEvent_Completed value) completed,
    required TResult Function(ProgressEvent_Failed value) failed,
  }) {
    return processing(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(ProgressEvent_Processing value)? processing,
    TResult? Function(ProgressEvent_Extracting value)? extracting,
    TResult? Function(ProgressEvent_Completed value)? completed,
    TResult? Function(ProgressEvent_Failed value)? failed,
  }) {
    return processing?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(ProgressEvent_Processing value)? processing,
    TResult Function(ProgressEvent_Extracting value)? extracting,
    TResult Function(ProgressEvent_Completed value)? completed,
    TResult Function(ProgressEvent_Failed value)? failed,
    required TResult orElse(),
  }) {
    if (processing != null) {
      return processing(this);
    }
    return orElse();
  }
}

abstract class ProgressEvent_Processing extends ProgressEvent {
  const factory ProgressEvent_Processing({required final String fileName}) =
      _$ProgressEvent_ProcessingImpl;
  const ProgressEvent_Processing._() : super._();

  @override
  String get fileName;

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ProgressEvent_ProcessingImplCopyWith<_$ProgressEvent_ProcessingImpl>
  get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$ProgressEvent_ExtractingImplCopyWith<$Res>
    implements $ProgressEventCopyWith<$Res> {
  factory _$$ProgressEvent_ExtractingImplCopyWith(
    _$ProgressEvent_ExtractingImpl value,
    $Res Function(_$ProgressEvent_ExtractingImpl) then,
  ) = __$$ProgressEvent_ExtractingImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String fileName, int percent});
}

/// @nodoc
class __$$ProgressEvent_ExtractingImplCopyWithImpl<$Res>
    extends _$ProgressEventCopyWithImpl<$Res, _$ProgressEvent_ExtractingImpl>
    implements _$$ProgressEvent_ExtractingImplCopyWith<$Res> {
  __$$ProgressEvent_ExtractingImplCopyWithImpl(
    _$ProgressEvent_ExtractingImpl _value,
    $Res Function(_$ProgressEvent_ExtractingImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? fileName = null, Object? percent = null}) {
    return _then(
      _$ProgressEvent_ExtractingImpl(
        fileName: null == fileName
            ? _value.fileName
            : fileName // ignore: cast_nullable_to_non_nullable
                  as String,
        percent: null == percent
            ? _value.percent
            : percent // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// @nodoc

class _$ProgressEvent_ExtractingImpl extends ProgressEvent_Extracting {
  const _$ProgressEvent_ExtractingImpl({
    required this.fileName,
    required this.percent,
  }) : super._();

  @override
  final String fileName;

  /// 0..=100 across the extraction phase.
  @override
  final int percent;

  @override
  String toString() {
    return 'ProgressEvent.extracting(fileName: $fileName, percent: $percent)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ProgressEvent_ExtractingImpl &&
            (identical(other.fileName, fileName) ||
                other.fileName == fileName) &&
            (identical(other.percent, percent) || other.percent == percent));
  }

  @override
  int get hashCode => Object.hash(runtimeType, fileName, percent);

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ProgressEvent_ExtractingImplCopyWith<_$ProgressEvent_ExtractingImpl>
  get copyWith =>
      __$$ProgressEvent_ExtractingImplCopyWithImpl<
        _$ProgressEvent_ExtractingImpl
      >(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileName) processing,
    required TResult Function(String fileName, int percent) extracting,
    required TResult Function(String fileName, String documentId) completed,
    required TResult Function(String fileName, String error) failed,
  }) {
    return extracting(fileName, percent);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileName)? processing,
    TResult? Function(String fileName, int percent)? extracting,
    TResult? Function(String fileName, String documentId)? completed,
    TResult? Function(String fileName, String error)? failed,
  }) {
    return extracting?.call(fileName, percent);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileName)? processing,
    TResult Function(String fileName, int percent)? extracting,
    TResult Function(String fileName, String documentId)? completed,
    TResult Function(String fileName, String error)? failed,
    required TResult orElse(),
  }) {
    if (extracting != null) {
      return extracting(fileName, percent);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(ProgressEvent_Processing value) processing,
    required TResult Function(ProgressEvent_Extracting value) extracting,
    required TResult Function(ProgressEvent_Completed value) completed,
    required TResult Function(ProgressEvent_Failed value) failed,
  }) {
    return extracting(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(ProgressEvent_Processing value)? processing,
    TResult? Function(ProgressEvent_Extracting value)? extracting,
    TResult? Function(ProgressEvent_Completed value)? completed,
    TResult? Function(ProgressEvent_Failed value)? failed,
  }) {
    return extracting?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(ProgressEvent_Processing value)? processing,
    TResult Function(ProgressEvent_Extracting value)? extracting,
    TResult Function(ProgressEvent_Completed value)? completed,
    TResult Function(ProgressEvent_Failed value)? failed,
    required TResult orElse(),
  }) {
    if (extracting != null) {
      return extracting(this);
    }
    return orElse();
  }
}

abstract class ProgressEvent_Extracting extends ProgressEvent {
  const factory ProgressEvent_Extracting({
    required final String fileName,
    required final int percent,
  }) = _$ProgressEvent_ExtractingImpl;
  const ProgressEvent_Extracting._() : super._();

  @override
  String get fileName;

  /// 0..=100 across the extraction phase.
  int get percent;

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ProgressEvent_ExtractingImplCopyWith<_$ProgressEvent_ExtractingImpl>
  get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$ProgressEvent_CompletedImplCopyWith<$Res>
    implements $ProgressEventCopyWith<$Res> {
  factory _$$ProgressEvent_CompletedImplCopyWith(
    _$ProgressEvent_CompletedImpl value,
    $Res Function(_$ProgressEvent_CompletedImpl) then,
  ) = __$$ProgressEvent_CompletedImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String fileName, String documentId});
}

/// @nodoc
class __$$ProgressEvent_CompletedImplCopyWithImpl<$Res>
    extends _$ProgressEventCopyWithImpl<$Res, _$ProgressEvent_CompletedImpl>
    implements _$$ProgressEvent_CompletedImplCopyWith<$Res> {
  __$$ProgressEvent_CompletedImplCopyWithImpl(
    _$ProgressEvent_CompletedImpl _value,
    $Res Function(_$ProgressEvent_CompletedImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? fileName = null, Object? documentId = null}) {
    return _then(
      _$ProgressEvent_CompletedImpl(
        fileName: null == fileName
            ? _value.fileName
            : fileName // ignore: cast_nullable_to_non_nullable
                  as String,
        documentId: null == documentId
            ? _value.documentId
            : documentId // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc

class _$ProgressEvent_CompletedImpl extends ProgressEvent_Completed {
  const _$ProgressEvent_CompletedImpl({
    required this.fileName,
    required this.documentId,
  }) : super._();

  @override
  final String fileName;
  @override
  final String documentId;

  @override
  String toString() {
    return 'ProgressEvent.completed(fileName: $fileName, documentId: $documentId)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ProgressEvent_CompletedImpl &&
            (identical(other.fileName, fileName) ||
                other.fileName == fileName) &&
            (identical(other.documentId, documentId) ||
                other.documentId == documentId));
  }

  @override
  int get hashCode => Object.hash(runtimeType, fileName, documentId);

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ProgressEvent_CompletedImplCopyWith<_$ProgressEvent_CompletedImpl>
  get copyWith =>
      __$$ProgressEvent_CompletedImplCopyWithImpl<
        _$ProgressEvent_CompletedImpl
      >(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileName) processing,
    required TResult Function(String fileName, int percent) extracting,
    required TResult Function(String fileName, String documentId) completed,
    required TResult Function(String fileName, String error) failed,
  }) {
    return completed(fileName, documentId);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileName)? processing,
    TResult? Function(String fileName, int percent)? extracting,
    TResult? Function(String fileName, String documentId)? completed,
    TResult? Function(String fileName, String error)? failed,
  }) {
    return completed?.call(fileName, documentId);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileName)? processing,
    TResult Function(String fileName, int percent)? extracting,
    TResult Function(String fileName, String documentId)? completed,
    TResult Function(String fileName, String error)? failed,
    required TResult orElse(),
  }) {
    if (completed != null) {
      return completed(fileName, documentId);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(ProgressEvent_Processing value) processing,
    required TResult Function(ProgressEvent_Extracting value) extracting,
    required TResult Function(ProgressEvent_Completed value) completed,
    required TResult Function(ProgressEvent_Failed value) failed,
  }) {
    return completed(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(ProgressEvent_Processing value)? processing,
    TResult? Function(ProgressEvent_Extracting value)? extracting,
    TResult? Function(ProgressEvent_Completed value)? completed,
    TResult? Function(ProgressEvent_Failed value)? failed,
  }) {
    return completed?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(ProgressEvent_Processing value)? processing,
    TResult Function(ProgressEvent_Extracting value)? extracting,
    TResult Function(ProgressEvent_Completed value)? completed,
    TResult Function(ProgressEvent_Failed value)? failed,
    required TResult orElse(),
  }) {
    if (completed != null) {
      return completed(this);
    }
    return orElse();
  }
}

abstract class ProgressEvent_Completed extends ProgressEvent {
  const factory ProgressEvent_Completed({
    required final String fileName,
    required final String documentId,
  }) = _$ProgressEvent_CompletedImpl;
  const ProgressEvent_Completed._() : super._();

  @override
  String get fileName;
  String get documentId;

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ProgressEvent_CompletedImplCopyWith<_$ProgressEvent_CompletedImpl>
  get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$ProgressEvent_FailedImplCopyWith<$Res>
    implements $ProgressEventCopyWith<$Res> {
  factory _$$ProgressEvent_FailedImplCopyWith(
    _$ProgressEvent_FailedImpl value,
    $Res Function(_$ProgressEvent_FailedImpl) then,
  ) = __$$ProgressEvent_FailedImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String fileName, String error});
}

/// @nodoc
class __$$ProgressEvent_FailedImplCopyWithImpl<$Res>
    extends _$ProgressEventCopyWithImpl<$Res, _$ProgressEvent_FailedImpl>
    implements _$$ProgressEvent_FailedImplCopyWith<$Res> {
  __$$ProgressEvent_FailedImplCopyWithImpl(
    _$ProgressEvent_FailedImpl _value,
    $Res Function(_$ProgressEvent_FailedImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? fileName = null, Object? error = null}) {
    return _then(
      _$ProgressEvent_FailedImpl(
        fileName: null == fileName
            ? _value.fileName
            : fileName // ignore: cast_nullable_to_non_nullable
                  as String,
        error: null == error
            ? _value.error
            : error // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc

class _$ProgressEvent_FailedImpl extends ProgressEvent_Failed {
  const _$ProgressEvent_FailedImpl({
    required this.fileName,
    required this.error,
  }) : super._();

  @override
  final String fileName;
  @override
  final String error;

  @override
  String toString() {
    return 'ProgressEvent.failed(fileName: $fileName, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ProgressEvent_FailedImpl &&
            (identical(other.fileName, fileName) ||
                other.fileName == fileName) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(runtimeType, fileName, error);

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ProgressEvent_FailedImplCopyWith<_$ProgressEvent_FailedImpl>
  get copyWith =>
      __$$ProgressEvent_FailedImplCopyWithImpl<_$ProgressEvent_FailedImpl>(
        this,
        _$identity,
      );

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String fileName) processing,
    required TResult Function(String fileName, int percent) extracting,
    required TResult Function(String fileName, String documentId) completed,
    required TResult Function(String fileName, String error) failed,
  }) {
    return failed(fileName, error);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String fileName)? processing,
    TResult? Function(String fileName, int percent)? extracting,
    TResult? Function(String fileName, String documentId)? completed,
    TResult? Function(String fileName, String error)? failed,
  }) {
    return failed?.call(fileName, error);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String fileName)? processing,
    TResult Function(String fileName, int percent)? extracting,
    TResult Function(String fileName, String documentId)? completed,
    TResult Function(String fileName, String error)? failed,
    required TResult orElse(),
  }) {
    if (failed != null) {
      return failed(fileName, error);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(ProgressEvent_Processing value) processing,
    required TResult Function(ProgressEvent_Extracting value) extracting,
    required TResult Function(ProgressEvent_Completed value) completed,
    required TResult Function(ProgressEvent_Failed value) failed,
  }) {
    return failed(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(ProgressEvent_Processing value)? processing,
    TResult? Function(ProgressEvent_Extracting value)? extracting,
    TResult? Function(ProgressEvent_Completed value)? completed,
    TResult? Function(ProgressEvent_Failed value)? failed,
  }) {
    return failed?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(ProgressEvent_Processing value)? processing,
    TResult Function(ProgressEvent_Extracting value)? extracting,
    TResult Function(ProgressEvent_Completed value)? completed,
    TResult Function(ProgressEvent_Failed value)? failed,
    required TResult orElse(),
  }) {
    if (failed != null) {
      return failed(this);
    }
    return orElse();
  }
}

abstract class ProgressEvent_Failed extends ProgressEvent {
  const factory ProgressEvent_Failed({
    required final String fileName,
    required final String error,
  }) = _$ProgressEvent_FailedImpl;
  const ProgressEvent_Failed._() : super._();

  @override
  String get fileName;
  String get error;

  /// Create a copy of ProgressEvent
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ProgressEvent_FailedImplCopyWith<_$ProgressEvent_FailedImpl>
  get copyWith => throw _privateConstructorUsedError;
}

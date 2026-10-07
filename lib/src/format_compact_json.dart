import 'dart:convert';

typedef _JsonFormatOptions = ({
  bool collapsePrimitiveLists,
  int maxInlineListLength,
  int? maxInlineMapLength,
});

bool _isPrimitiveJsonValue(Object? v) =>
    v == null || v is num || v is bool || v is String;

String? _tryFormatInlineMap(Map<String, dynamic> map, int? maxInlineMapLength) {
  if (!map.values.every(_isPrimitiveJsonValue)) return null;
  final entries = map.entries
      .map((e) => '${jsonEncode(e.key)}: ${jsonEncode(e.value)}')
      .join(', ');
  final inline = '{$entries}';
  if (maxInlineMapLength != null && inline.length > maxInlineMapLength) {
    return null;
  }
  return inline;
}

String _formatMapEntries(
  Map<String, dynamic> data,
  int indent,
  _JsonFormatOptions options,
) {
  final pad = '  ' * indent;
  final childPad = '  ' * (indent + 1);
  final lines = data.entries
      .map(
        (e) =>
            '$childPad${jsonEncode(e.key)}: '
            '${_formatJsonValue(e.value, indent + 1, options)}',
      )
      .join(',\n');
  return '{\n$lines\n$pad}';
}

String _formatListElements(
  List<Object?> data,
  int indent,
  _JsonFormatOptions options,
) {
  final pad = '  ' * indent;
  final childPad = '  ' * (indent + 1);
  final lines = data
      .map((e) => '$childPad${_formatJsonValue(e, indent + 1, options)}')
      .join(',\n');
  return '[\n$lines\n$pad]';
}

String _formatMapValue(
  Map<String, dynamic> data,
  int indent,
  _JsonFormatOptions options,
) {
  if (data.isEmpty) return '{}';
  final inline = indent >= 2
      ? _tryFormatInlineMap(data, options.maxInlineMapLength)
      : null;
  return inline ?? _formatMapEntries(data, indent, options);
}

String _formatListValue(
  List<Object?> data,
  int indent,
  _JsonFormatOptions options,
) {
  if (data.isEmpty) return '[]';
  if (options.collapsePrimitiveLists && data.every(_isPrimitiveJsonValue)) {
    final inline = '[${data.map(jsonEncode).join(', ')}]';
    if (inline.length <= options.maxInlineListLength) return inline;
  }
  return _formatListElements(data, indent, options);
}

String _formatJsonValue(Object? data, int indent, _JsonFormatOptions options) =>
    switch (data) {
      final Map<String, dynamic> m => _formatMapValue(m, indent, options),
      final Map<Object?, Object?> m => _formatMapValue(
        Map<String, dynamic>.from(m),
        indent,
        options,
      ),
      final List<Object?> l => _formatListValue(l, indent, options),
      _ => jsonEncode(data),
    };

/// Formats [data] as canonical 2-space indented JSON with primitive leaf maps
/// whose single-line representation is at most [maxInlineMapLength] characters
/// (or unlimited when `null`) collapsed onto single lines for diff clarity and
/// token efficiency.
///
/// When [collapsePrimitiveLists] is `true`, primitive arrays whose single-line
/// JSON representation is at most [maxInlineListLength] characters are also
/// formatted on a single line.
String formatCompactJson(
  Object? data, {
  int indent = 0,
  bool collapsePrimitiveLists = false,
  int maxInlineListLength = 100,
  int? maxInlineMapLength = 160,
}) => _formatJsonValue(data, indent, (
  collapsePrimitiveLists: collapsePrimitiveLists,
  maxInlineListLength: maxInlineListLength,
  maxInlineMapLength: maxInlineMapLength,
));

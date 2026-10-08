import 'dart:convert';

import 'known_field_type.dart';
import 'sentinel_sources.dart';

Map<String, KnownFieldType> _extractFlatFieldTypes(
  Map<dynamic, dynamic> source,
) => {
  for (final entry in source.entries)
    if (entry case MapEntry(
      key: final String k,
      value: final String v,
    ) when !k.contains('.'))
      k: ?KnownFieldType.tryFromKey(v),
};

Map<String, KnownFieldType> _extractDottedFieldTypes(
  Map<dynamic, dynamic> source,
  String collectionKey,
) {
  final dotPrefix = '$collectionKey.';
  final result = <String, KnownFieldType>{};
  for (final entry in source.entries) {
    if (entry case MapEntry(
      key: final String k,
      value: final String v,
    ) when k.startsWith(dotPrefix)) {
      final field = k.substring(dotPrefix.length);
      final type = KnownFieldType.tryFromKey(v);
      if (field.isNotEmpty && !field.contains('.') && type != null) {
        result[field] = type;
      }
    }
  }
  return result;
}

Map<String, Set<String>> _extractFlatFieldValues(
  Map<dynamic, dynamic> source,
) => {
  for (final entry in source.entries)
    if (entry case MapEntry(
      key: final String k,
      value: final List<dynamic> v,
    ) when !k.contains('.'))
      k: v.whereType<String>().toSet(),
};

Map<String, Set<String>> _extractDottedFieldValues(
  Map<dynamic, dynamic> source,
  String collectionKey,
) {
  final dotPrefix = '$collectionKey.';
  final result = <String, Set<String>>{};
  for (final entry in source.entries) {
    if (entry case MapEntry(
      key: final String k,
      value: final List<dynamic> v,
    ) when k.startsWith(dotPrefix)) {
      final field = k.substring(dotPrefix.length);
      if (field.isNotEmpty && !field.contains('.')) {
        result[field] = v.whereType<String>().toSet();
      }
    }
  }
  return result;
}

/// Reserved root JSON key holding `md-live` schema and projection directives
/// (`field_types`, `field_values`, `table_columns`).
const String mdLiveEnvelopeKey = '@md_live';

const Set<String> _knownMdLiveEnvelopeKeys = {
  'field_types',
  'field_values',
  'table_columns',
};

/// Extracts the `@md_live` directive map from [rootJson], or `null` if absent
/// or not a map.
Map<dynamic, dynamic>? mdLiveEnvelope(Map<String, dynamic> rootJson) =>
    switch (rootJson[mdLiveEnvelopeKey]) {
      final Map<dynamic, dynamic> m => m,
      _ => null,
    };

/// Resolves the `field -> KnownFieldType` map for [collectionKey] from
/// `rootJson['@md_live']['field_types']`, merging any top-level default field
/// types with collection-scoped overrides (supporting both
/// `"collection.field": "type"` and `"collection": {"field": "type"}`).
Map<String, KnownFieldType> resolveCollectionFieldTypes(
  Map<String, dynamic> rootJson, [
  String? collectionKey,
]) {
  final rawFieldTypes = mdLiveEnvelope(rootJson)?['field_types'];
  if (rawFieldTypes is! Map) return const {};
  final resolved = _extractFlatFieldTypes(rawFieldTypes);
  if (collectionKey == null) return resolved;
  resolved.addAll(_extractDottedFieldTypes(rawFieldTypes, collectionKey));
  final scoped = rawFieldTypes[collectionKey];
  if (scoped is Map) {
    resolved.addAll(_extractFlatFieldTypes(scoped));
  }
  return resolved;
}

Map<String, Set<String>> _resolveCollectionFieldValues(
  Map<String, dynamic> rootJson,
  String collectionKey,
) {
  final rawFieldValues = mdLiveEnvelope(rootJson)?['field_values'];
  if (rawFieldValues is! Map) return const {};
  final resolved = _extractFlatFieldValues(rawFieldValues)
    ..addAll(_extractDottedFieldValues(rawFieldValues, collectionKey));
  final scoped = rawFieldValues[collectionKey];
  if (scoped is Map) {
    resolved.addAll(_extractFlatFieldValues(scoped));
  }
  return resolved;
}

List<String> _validateCollectionKnownFields(
  String collectionKey,
  List<Object?> items,
  Map<String, KnownFieldType> fieldTypes,
  String prefix,
) {
  final errors = <String>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map) continue;
    for (final entry in fieldTypes.entries) {
      final field = entry.key;
      if (!item.containsKey(field)) continue;
      final err = entry.value.validateValue(item[field]);
      if (err != null) {
        errors.add('$prefix$collectionKey[$i].$field: $err');
      }
    }
  }
  return errors;
}

String? _validateValueAgainstAllowed(Object? value, Set<String> allowed) {
  if (value is String && allowed.contains(value)) return null;
  if (value is List && value.isNotEmpty) {
    for (final item in value) {
      if (item is! String || !allowed.contains(item)) {
        return 'invalid value "$item" (expected one of: ${allowed.join(', ')})';
      }
    }
    return null;
  }
  return 'invalid value "$value" (expected one of: ${allowed.join(', ')})';
}

List<String> _validateCollectionFieldValues(
  String collectionKey,
  List<Object?> items,
  Map<String, Set<String>> fieldValues,
  String prefix,
) {
  final errors = <String>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map) continue;
    for (final entry in fieldValues.entries) {
      final field = entry.key;
      if (!item.containsKey(field)) continue;
      final err = _validateValueAgainstAllowed(item[field], entry.value);
      if (err != null) {
        errors.add('$prefix$collectionKey[$i].$field: $err');
      }
    }
  }
  return errors;
}

String? _validateScopedFieldTypeEntry(
  String parentKey,
  Object? subKey,
  Object? subVal,
  String prefix,
) {
  if (subKey is! String || subKey.isEmpty || subKey.contains('.')) {
    return '${prefix}invalid field_types key "$parentKey.$subKey"';
  }
  if (subVal is! String || KnownFieldType.tryFromKey(subVal) == null) {
    return '${prefix}unknown field_type "$subVal" for "$parentKey.$subKey"';
  }
  return null;
}

List<String> _validateScopedFieldTypesMap(
  Object? parentKey,
  Map<dynamic, dynamic> scoped,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (parentKey is! String ||
      parentKey.isEmpty ||
      parentKey.contains('.') ||
      rootJson[parentKey] is! List) {
    return ['${prefix}unknown collection "$parentKey" in field_types'];
  }
  return [
    for (final sub in scoped.entries)
      ?_validateScopedFieldTypeEntry(parentKey, sub.key, sub.value, prefix),
  ];
}

String? _validateStringFieldTypeEntry(
  Object? key,
  String val,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (key is! String || key.isEmpty) {
    return '${prefix}invalid field_types key "$key"';
  }
  if (key.contains('.')) {
    final parts = key.split('.');
    if (parts.length != 2 ||
        parts[0].isEmpty ||
        parts[1].isEmpty ||
        rootJson[parts[0]] is! List) {
      return '${prefix}unknown collection in field_types key "$key"';
    }
  }
  if (KnownFieldType.tryFromKey(val) == null) {
    return '${prefix}unknown field_type "$val" for "$key"';
  }
  return null;
}

List<String> _validateFieldTypesDeclaration(
  Object? rawFieldTypes,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (rawFieldTypes == null) return const [];
  if (rawFieldTypes is! Map) {
    return ['${prefix}field_types must be a JSON object map'];
  }
  final errors = <String>[];
  for (final entry in rawFieldTypes.entries) {
    final key = entry.key;
    final val = entry.value;
    if (val is String) {
      final err = _validateStringFieldTypeEntry(key, val, rootJson, prefix);
      if (err != null) errors.add(err);
    } else if (val is Map) {
      errors.addAll(_validateScopedFieldTypesMap(key, val, rootJson, prefix));
    } else {
      errors.add('${prefix}invalid field_types entry for "$key"');
    }
  }
  return errors;
}

String? _validateAllowedValuesList(
  Object? rawValues,
  String targetLabel,
  String prefix,
) {
  final label = '${prefix}field_values["$targetLabel"]';
  final shapeError = '$label must be a non-empty list of trimmed strings';
  if (rawValues is! List || rawValues.isEmpty) return shapeError;
  final seen = <String>{};
  for (final item in rawValues) {
    if (item is! String || item.trim().isEmpty || item.trim() != item) {
      return shapeError;
    }
    if (!seen.add(item)) {
      return '$label contains duplicate value "$item"';
    }
  }
  return null;
}

List<String> _validateScopedFieldValuesMap(
  Object? parentKey,
  Map<dynamic, dynamic> scoped,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (parentKey is! String ||
      parentKey.isEmpty ||
      parentKey.contains('.') ||
      rootJson[parentKey] is! List) {
    return ['${prefix}unknown collection "$parentKey" in field_values'];
  }
  final errors = <String>[];
  for (final sub in scoped.entries) {
    final subKey = sub.key;
    if (subKey is! String || subKey.isEmpty || subKey.contains('.')) {
      errors.add('${prefix}invalid field_values key "$parentKey.$subKey"');
      continue;
    }
    final err = _validateAllowedValuesList(
      sub.value,
      '$parentKey.$subKey',
      prefix,
    );
    if (err != null) errors.add(err);
  }
  return errors;
}

String? _validateFlatOrDottedFieldValuesEntry(
  Object? key,
  List<Object?> val,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (key is! String || key.isEmpty) {
    return '${prefix}invalid field_values key "$key"';
  }
  if (key.contains('.')) {
    final parts = key.split('.');
    if (parts.length != 2 ||
        parts[0].isEmpty ||
        parts[1].isEmpty ||
        rootJson[parts[0]] is! List) {
      return '${prefix}unknown collection in field_values key "$key"';
    }
  }
  return _validateAllowedValuesList(val, key, prefix);
}

List<String> _validateFieldValuesDeclaration(
  Object? rawFieldValues,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (rawFieldValues == null) return const [];
  if (rawFieldValues is! Map) {
    return ['${prefix}field_values must be a JSON object map'];
  }
  final errors = <String>[];
  for (final entry in rawFieldValues.entries) {
    final key = entry.key;
    final val = entry.value;
    if (val is List) {
      final err = _validateFlatOrDottedFieldValuesEntry(
        key,
        val,
        rootJson,
        prefix,
      );
      if (err != null) errors.add(err);
    } else if (val is Map) {
      errors.addAll(_validateScopedFieldValuesMap(key, val, rootJson, prefix));
    } else {
      errors.add('${prefix}invalid field_values entry for "$key"');
    }
  }
  return errors;
}

List<String> _validateSingleTableColumnsEntry(
  Object? colKey,
  Object? colVal,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (colKey is! String || colKey.isEmpty || rootJson[colKey] is! List) {
    return ['${prefix}unknown collection "$colKey" in table_columns'];
  }
  if (colVal is! List ||
      colVal.isEmpty ||
      !colVal.every((e) => e is String && e.trim().isNotEmpty)) {
    final label = '${prefix}table_columns["$colKey"]';
    return ['$label must be a non-empty list of column keys'];
  }
  final cols = colVal.cast<String>();
  final items = rootJson[colKey] as List<Object?>;
  final errors = <String>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map) continue;
    for (final col in cols) {
      if (col != '#index' && !item.containsKey(col)) {
        errors.add('$prefix$colKey[$i] missing table_columns key "$col"');
      }
    }
  }
  return errors;
}

List<String> _validateTableColumnsDeclaration(
  Object? rawTableCols,
  Map<String, dynamic> rootJson,
  String prefix,
) {
  if (rawTableCols == null) return const [];
  if (rawTableCols is! Map) {
    return ['${prefix}table_columns must be a JSON object map'];
  }
  return [
    for (final entry in rawTableCols.entries)
      ..._validateSingleTableColumnsEntry(
        entry.key,
        entry.value,
        rootJson,
        prefix,
      ),
  ];
}

List<String> _validateMdLiveEnvelope(
  Map<String, dynamic> rootJson,
  String prefix,
) {
  final errors = <String>[
    for (final key in _knownMdLiveEnvelopeKeys)
      if (rootJson.containsKey(key))
        '${prefix}move "$key" inside "$mdLiveEnvelopeKey"',
  ];
  if (!rootJson.containsKey(mdLiveEnvelopeKey)) return errors;
  final rawEnvelope = rootJson[mdLiveEnvelopeKey];
  if (rawEnvelope is! Map) {
    return [...errors, '$prefix$mdLiveEnvelopeKey must be a JSON object map'];
  }
  for (final key in rawEnvelope.keys) {
    if (key is! String || !_knownMdLiveEnvelopeKeys.contains(key)) {
      errors.add('${prefix}unknown $mdLiveEnvelopeKey key "$key"');
    }
  }
  return errors;
}

/// Validates `rootJson['@md_live']` (`field_types`, `field_values`, and
/// `table_columns` declarations, unknown `@md_live` keys, and legacy top-level
/// directives) and checks every record in matching collections against its
/// declared [KnownFieldType] and allowed-value rules.
List<String> validateKnownFields(
  Map<String, dynamic> rootJson, {
  String prefix = '',
}) {
  final envErrors = _validateMdLiveEnvelope(rootJson, prefix);
  final envelope = mdLiveEnvelope(rootJson);
  if (envelope == null) return envErrors;

  final tableColErrors = _validateTableColumnsDeclaration(
    envelope['table_columns'],
    rootJson,
    prefix,
  );
  final typeDeclErrors = _validateFieldTypesDeclaration(
    envelope['field_types'],
    rootJson,
    prefix,
  );
  final valDeclErrors = _validateFieldValuesDeclaration(
    envelope['field_values'],
    rootJson,
    prefix,
  );
  final errors = [
    ...envErrors,
    ...tableColErrors,
    ...typeDeclErrors,
    ...valDeclErrors,
  ];
  if (typeDeclErrors.isNotEmpty || valDeclErrors.isNotEmpty) return errors;

  for (final entry in rootJson.entries) {
    if (entry.key == mdLiveEnvelopeKey || entry.value is! List) continue;
    final items = entry.value as List<Object?>;
    final fieldTypes = resolveCollectionFieldTypes(rootJson, entry.key);
    if (fieldTypes.isNotEmpty) {
      errors.addAll(
        _validateCollectionKnownFields(entry.key, items, fieldTypes, prefix),
      );
    }
    final fieldValues = _resolveCollectionFieldValues(rootJson, entry.key);
    if (fieldValues.isNotEmpty) {
      errors.addAll(
        _validateCollectionFieldValues(entry.key, items, fieldValues, prefix),
      );
    }
  }
  return errors;
}

({Object? decoded, String? parseError}) _loadCachedSentinelJson(
  String filePath,
  String? Function(String relativeJsonPath) readJsonFileSync,
  Map<String, Object?> decodedCache,
) {
  if (decodedCache.containsKey(filePath)) {
    return (decoded: decodedCache[filePath], parseError: null);
  }
  final raw = readJsonFileSync(filePath);
  if (raw == null || raw.trim().isEmpty) {
    decodedCache[filePath] = null;
    return (decoded: null, parseError: null);
  }
  try {
    final decoded = jsonDecode(raw);
    decodedCache[filePath] = decoded;
    return (decoded: decoded, parseError: null);
  } on FormatException catch (e) {
    decodedCache[filePath] = null;
    return (decoded: null, parseError: e.message);
  }
}

/// Validates that every sentinel `src="<file.json>[#<selector>]"` marker in
/// [markdown] resolves to a non-empty list of JSON object maps via
/// [readJsonFileSync] and passes [validateKnownFields], returning any
/// validation error messages.
List<String> validateSentinelSources(
  String markdown,
  String? Function(String relativeJsonPath) readJsonFileSync, {
  String? markdownName,
}) {
  final sources = extractSentinelJsonSources(markdown);
  if (sources.isEmpty) return const [];

  final prefix = markdownName != null ? '$markdownName: ' : '';
  final decodedCache = <String, Object?>{};
  final validatedFiles = <String>{};
  final errors = <String>[];

  for (final src in sources) {
    final ({String filePath, String? selector}) spec;
    try {
      spec = parseSentinelSourceSpec(src);
      // parseSentinelSourceSpec reports malformed specs via ArgumentError.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (e) {
      errors.add('${prefix}invalid sentinel src "$src" (${e.message})');
      continue;
    }
    final (:decoded, :parseError) = _loadCachedSentinelJson(
      spec.filePath,
      readJsonFileSync,
      decodedCache,
    );
    if (parseError != null) {
      errors.add('${prefix}invalid JSON in "${spec.filePath}" ($parseError)');
    }
    if (decoded == null) {
      errors.add(
        '${prefix}missing JSON file "${spec.filePath}" for src="$src"',
      );
      continue;
    }
    if (validatedFiles.add(spec.filePath) && decoded is Map) {
      errors.addAll(
        validateKnownFields(
          Map<String, dynamic>.from(decoded),
          prefix: '$prefix${spec.filePath}: ',
        ),
      );
    }
    final slice = resolveSentinelJsonSlice(decoded, spec.selector);
    if (slice == null || slice.isEmpty) {
      errors.add(
        '${prefix}sentinel src="$src" did not resolve to a '
        'non-empty record list',
      );
    }
  }
  return errors;
}

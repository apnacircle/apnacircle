import 'app_en.dart';
import 'app_ur.dart';

/// Tiny string lookup (no codegen needed for v0.1).
/// Usage: `Strings.of(context).t('sos')`.
String tr(bool isUrdu, String key) =>
    (isUrdu ? urStrings : enStrings)[key] ?? enStrings[key] ?? key;

/// Same as [tr] but interpolates `{name}` placeholders from [args]
/// (v0.6.32 — parameterized strings, e.g. `{name} has been allowed`).
/// Values in the maps use `{name}` syntax, never `$name`, so the
/// same key works for both locales with different word order.
String trf(bool isUrdu, String key, [Map<String, Object> args = const {}]) {
  var out = tr(isUrdu, key);
  args.forEach((k, v) {
    out = out.replaceAll('{$k}', v.toString());
  });
  return out;
}

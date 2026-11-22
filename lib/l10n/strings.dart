import 'app_en.dart';
import 'app_ur.dart';

/// Tiny string lookup (no codegen needed for v0.1).
/// Usage: `Strings.of(context).t('sos')`.
String tr(bool isUrdu, String key) =>
    (isUrdu ? urStrings : enStrings)[key] ?? enStrings[key] ?? key;

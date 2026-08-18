/// The app's version, mirroring `pubspec.yaml`.
///
/// Duplicated rather than read at runtime on purpose: reading it would mean
/// adding a plugin dependency for one string. `test/app_version_test.dart`
/// parses `pubspec.yaml` and fails if the two ever drift, so the duplication
/// cannot rot silently.
///
/// Surfaced on Settings → About. An app with no visible version leaves "what
/// version are you on?" unanswerable from inside the app — including for the
/// person about to press the Report an issue button sitting next to it.
const String kAppVersion = '0.2.0';

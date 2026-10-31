import 'dart:io';

/// Locate the native asset created by Flutter's package build hook. CI may
/// override it (macOS also supports the project's existing build convention).
String pdfiumTestModule() {
  final configured = Platform.environment['PDFIUM_PATH'];
  if (configured != null) return File(configured).absolute.path;
  final mac = File('build/native_assets/macos/libpdfium.dylib');
  if (Platform.isMacOS && mac.existsSync()) return mac.absolute.path;
  final root = Directory('.dart_tool/hooks_runner/shared/pdfium_dart/build');
  final name = Platform.isWindows
      ? 'pdfium.dll'
      : Platform.isMacOS
      ? 'libpdfium.dylib'
      : 'libpdfium.so';
  if (root.existsSync()) {
    for (final file in root.listSync(recursive: true).whereType<File>()) {
      if (file.uri.pathSegments.last == name) return file.absolute.path;
    }
  }
  throw StateError(
    'Set PDFIUM_PATH to the native PDFium library for this platform.',
  );
}

// Downloads a Pyodide distribution into assets/pyodide/ for offline use by the
// native code interpreter (lib/core/services/pyodide_code_runner.dart).
//
// Usage (from repo root):
//   dart run tool/fetch_pyodide.dart                       # core runtime only
//   dart run tool/fetch_pyodide.dart --packages=numpy,matplotlib
//
// The version is read from `_pyodideVersion` in pyodide_code_runner.dart so the
// bundled assets always match the runtime. Binaries are git-ignored; re-run per
// checkout. After fetching, run `flutter pub get`.
import 'dart:convert';
import 'dart:io';

const String _runnerPath = 'lib/core/services/pyodide_code_runner.dart';
const String _outDirPath = 'assets/pyodide';

// Minimal files needed to boot Pyodide (UMD build) with the standard library.
const List<String> _coreFiles = <String>[
  'pyodide.js',
  'pyodide.asm.js',
  'pyodide.asm.wasm',
  'pyodide-lock.json',
  'python_stdlib.zip',
];

Future<void> main(List<String> args) async {
  final version = _readPinnedVersion();
  final base = 'https://cdn.jsdelivr.net/pyodide/$version/full/';
  final outDir = Directory(_outDirPath);
  await outDir.create(recursive: true);

  final packages = _parsePackages(args);

  final client = HttpClient();
  try {
    stdout.writeln('Pyodide $version → ${outDir.path}/');
    for (final file in _coreFiles) {
      await _download(client, '$base$file', '${outDir.path}/$file');
    }

    if (packages.isNotEmpty) {
      final lockText =
          await File('${outDir.path}/pyodide-lock.json').readAsString();
      final lock = jsonDecode(lockText) as Map<String, dynamic>;
      final files = _resolvePackageFiles(lock, packages);
      stdout.writeln(
        'Resolved ${files.length} wheel(s) for ${packages.join(', ')} '
        '(incl. dependencies)',
      );
      for (final file in files) {
        await _download(client, '$base$file', '${outDir.path}/$file');
      }
    }

    stdout.writeln('\nDone. Now run: flutter pub get');
  } finally {
    client.close(force: true);
  }
}

String _readPinnedVersion() {
  final source = File(_runnerPath).readAsStringSync();
  final match =
      RegExp("_pyodideVersion\\s*=\\s*'([^']+)'").firstMatch(source);
  if (match == null) {
    stderr.writeln('Could not read _pyodideVersion from $_runnerPath');
    exit(1);
  }
  return match.group(1)!;
}

Set<String> _parsePackages(List<String> args) {
  final result = <String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? value;
    if (arg.startsWith('--packages=')) {
      value = arg.substring('--packages='.length);
    } else if (arg == '--packages' && i + 1 < args.length) {
      value = args[++i];
    }
    if (value != null) {
      for (final name in value.split(',')) {
        final trimmed = name.trim();
        if (trimmed.isNotEmpty) result.add(trimmed.toLowerCase());
      }
    }
  }
  return result;
}

/// Resolves the transitive closure of wheel file names for [requested],
/// walking each package's `depends` in the Pyodide lock file.
List<String> _resolvePackageFiles(
  Map<String, dynamic> lock,
  Set<String> requested,
) {
  final packages = (lock['packages'] as Map).cast<String, dynamic>();
  // Case-insensitive name → entry lookup (lock keys are normalized lowercase).
  final byName = <String, Map<String, dynamic>>{};
  for (final entry in packages.entries) {
    byName[entry.key.toLowerCase()] =
        (entry.value as Map).cast<String, dynamic>();
  }

  final files = <String>{};
  final seen = <String>{};
  final queue = <String>[...requested];
  while (queue.isNotEmpty) {
    final name = queue.removeLast();
    if (!seen.add(name)) continue;
    final pkg = byName[name];
    if (pkg == null) {
      stderr.writeln('  warning: package "$name" not found in lock file');
      continue;
    }
    final fileName = pkg['file_name']?.toString();
    if (fileName != null && fileName.isNotEmpty) files.add(fileName);
    final depends = pkg['depends'];
    if (depends is List) {
      for (final dep in depends) {
        queue.add(dep.toString().toLowerCase());
      }
    }
  }
  return files.toList()..sort();
}

Future<void> _download(HttpClient client, String url, String dest) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  if (response.statusCode != 200) {
    stderr.writeln('  FAILED ${response.statusCode}: $url');
    exit(1);
  }
  final bytes = await _collect(response);
  await File(dest).writeAsBytes(bytes);
  stdout.writeln('  ${_human(bytes.length).padLeft(9)}  ${dest.split('/').last}');
}

Future<List<int>> _collect(HttpClientResponse response) async {
  final bytes = <int>[];
  await for (final chunk in response) {
    bytes.addAll(chunk);
  }
  return bytes;
}

String _human(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

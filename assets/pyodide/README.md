# Bundled Pyodide (offline code interpreter)

This directory holds an optional **offline copy of Pyodide** used by the native
code interpreter (`lib/core/services/pyodide_code_runner.dart`).

- **Empty by default.** Without these files the runner loads Pyodide from the
  jsDelivr CDN at runtime (needs internet on first use).
- **When populated** (run the fetch script below), the runner serves Pyodide
  from an in-app `localhost` server, so Python runs fully **offline** with no
  external network dependency.

The binaries are intentionally **git-ignored** (the core runtime is ~10 MB and
packages such as numpy/matplotlib add tens of MB). Fetch them per checkout.

## Populate

From the repo root:

```bash
# Core runtime only (stdlib Python works offline; ~10 MB):
dart run tool/fetch_pyodide.dart

# Core + extra packages bundled offline (resolves their dependencies):
dart run tool/fetch_pyodide.dart --packages=numpy,matplotlib
```

The version is pinned by `_pyodideVersion` in `pyodide_code_runner.dart` and
must match what the script downloads (the script reads the same constant).

After fetching, run `flutter pub get` so the new assets are picked up.

## Notes

- Packages that are **not** bundled cannot load while offline (and will not
  load at all when the runner is using bundled assets, since Pyodide resolves
  packages relative to the same origin). Bundle every package you need offline,
  or leave this directory empty to keep full CDN package access online.
- Android: serving `http://localhost` to the WebView may require allowing
  cleartext traffic for localhost in the network security config. See the
  `flutter_inappwebview` `InAppLocalhostServer` docs if Pyodide fails to load
  from the bundled assets on Android.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../utils/debug_logger.dart';

/// Result of executing a Python snippet through the on-device Pyodide runtime.
///
/// Mirrors the shape Open WebUI's browser worker returns for `execute:python`
/// events (`{stdout, stderr, result}`); [error] is local-only diagnostic state
/// and is not sent back to the server.
class PyodidePythonResult {
  const PyodidePythonResult({
    this.stdout = '',
    this.stderr = '',
    this.result,
    this.error,
  });

  final String stdout;
  final String stderr;
  final dynamic result;
  final String? error;

  /// The payload Open WebUI expects the client to ack for an `execute:python`
  /// event. Matches the browser worker's `{stdout, stderr, result}` contract.
  Map<String, dynamic> toAck() => <String, dynamic>{
    'stdout': stdout,
    'stderr': stderr,
    'result': result,
  };
}

/// Runs Python entirely on-device using Pyodide (CPython compiled to
/// WebAssembly) inside a hidden [HeadlessInAppWebView] — the same engine the
/// Open WebUI web client uses. This preserves the "no code runs on the server"
/// property of the pyodide code-interpreter engine while still producing real
/// `stdout`/`stderr` in the native client.
///
/// Pyodide is loaded from a bundled offline distribution under `assets/pyodide`
/// when present (served via an in-app localhost server), otherwise from the
/// jsDelivr CDN. See `tool/fetch_pyodide.dart` to populate the offline assets.
///
/// Execution is serialized: a single headless WebView hosts one Pyodide
/// instance and runs snippets one at a time. A run that exceeds its timeout
/// tears the WebView down (a runaway sync loop blocks the JS thread and cannot
/// be interrupted without cross-origin isolation), so the next run re-boots a
/// fresh instance.
class PyodideCodeRunner {
  PyodideCodeRunner._();

  static final PyodideCodeRunner instance = PyodideCodeRunner._();

  /// Pinned Pyodide release. Bump deliberately — the indexURL is derived from
  /// the script location so the version must exist on the jsDelivr CDN (and,
  /// for offline use, the bundled assets must match this version). Keep in sync
  /// with `tool/fetch_pyodide.dart`.
  static const String _pyodideVersion = 'v0.26.4';
  static const String _cdnBase =
      'https://cdn.jsdelivr.net/pyodide/$_pyodideVersion/full/';

  /// Flutter asset directory holding a bundled Pyodide distribution. Populated
  /// by `tool/fetch_pyodide.dart`; absent by default (the runtime then falls
  /// back to [_cdnBase]).
  static const String _assetDir = 'assets/pyodide';
  static const String _assetProbe = '$_assetDir/pyodide.js';

  /// Port for the in-app localhost server that serves the bundled assets to the
  /// WebView (Pyodide resolves its wasm/stdlib relative to the page origin, so
  /// the assets must be reachable over http, not file://).
  static const int _localhostPort = 8459;

  // Overall deadline for a single execution (boot + run). Kept under the
  // server's event-call timeout so we always ack a result rather than letting
  // the request lapse into a "Client Session disconnected" error.
  static const Duration _defaultTimeout = Duration(seconds: 40);
  // Internal boot guard for warm-up (which runs outside [_runLocked]'s
  // deadline). Kept at/under the run deadline.
  static const Duration _bootTimeout = Duration(seconds: 38);

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Completer<void>? _ready;

  InAppLocalhostServer? _localhostServer;
  String? _resolvedBaseUrl;

  /// Set when booting from bundled localhost assets fails, pinning all
  /// subsequent boots to the CDN for the rest of the process.
  bool _forceCdn = false;

  /// Serializes runs so a single Pyodide instance handles one snippet at a
  /// time. Chained so the next run waits for the previous to settle.
  Future<void> _queue = Future<void>.value();

  bool get _isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Executes [code] and returns its captured output. Never throws — failures
  /// (unsupported platform, boot failure, timeout, Python exception) come back
  /// as a [PyodidePythonResult] with [PyodidePythonResult.error] set and the
  /// message mirrored into `stderr`, so the caller can always ack something.
  Future<PyodidePythonResult> run(
    String code, {
    Duration? timeout,
  }) {
    final completer = Completer<PyodidePythonResult>();
    // Tail the queue so runs never overlap on the shared WebView/runtime. Any
    // failure is converted into a result so the chain never carries an error.
    _queue = _queue.then((_) async {
      try {
        final result = await _runLocked(code, timeout ?? _defaultTimeout);
        if (!completer.isCompleted) completer.complete(result);
      } catch (error) {
        if (!completer.isCompleted) {
          completer.complete(
            PyodidePythonResult(stderr: '$error\n', error: '$error'),
          );
        }
      }
    });
    return completer.future;
  }

  /// Boots the Pyodide runtime ahead of time (idempotent, fire-and-forget).
  /// Called when the user enables the code interpreter so the first
  /// `execute:python` event doesn't pay the cold-start cost while the server
  /// waits on the ack.
  void warmUp() {
    if (!_isSupported) return;
    final ready = _ready;
    if (ready != null && (!ready.isCompleted || _controller != null)) {
      return;
    }
    // Swallow boot errors here; a later run() surfaces them as a result.
    unawaited(_ensureReady().then((_) {}, onError: (_, __) {}));
  }

  Future<PyodidePythonResult> _runLocked(String code, Duration timeout) async {
    if (!_isSupported) {
      const message =
          'Code execution is only available on iOS and Android in this build.';
      return const PyodidePythonResult(stderr: '$message\n', error: message);
    }

    try {
      // The timeout wraps the WHOLE operation — boot (which may fetch ~10 MB of
      // Pyodide from the CDN) AND execution — so we always ack the server before
      // its own call times out. Otherwise the server reports the request as a
      // dead session ("Client Session disconnected") in the code output.
      return await _execute(code).timeout(timeout);
    } on TimeoutException {
      // Boot or a runaway snippet exceeded the deadline; discard the instance so
      // the next run starts clean, and return a clear, actionable error.
      await _teardown();
      DebugLogger.warning(
        'pyodide-run-timeout',
        scope: 'tools/pyodide',
        data: {'timeoutSeconds': timeout.inSeconds},
      );
      final message =
          'Python did not respond within ${timeout.inSeconds}s. The on-device '
          'runtime may be unable to download Pyodide (check connectivity, or '
          'bundle it offline via tool/fetch_pyodide.dart).';
      return PyodidePythonResult(stderr: '$message\n', error: 'timeout');
    } catch (error, stackTrace) {
      await _teardown();
      DebugLogger.error(
        'pyodide-run-failed',
        scope: 'tools/pyodide',
        error: error,
        stackTrace: stackTrace,
      );
      final message = 'Python execution failed: $error';
      return PyodidePythonResult(stderr: '$message\n', error: message);
    }
  }

  /// Boots the runtime if needed and runs [code], returning the parsed result.
  /// Wrapped in a deadline by [_runLocked].
  Future<PyodidePythonResult> _execute(String code) async {
    final controller = await _ensureReady();
    final callResult = await controller.callAsyncJavaScript(
      functionBody: 'return await window.__conduitRunPython(code);',
      arguments: <String, dynamic>{'code': code},
    );

    if (callResult == null) {
      return const PyodidePythonResult(
        stderr: 'Python execution returned no result.\n',
        error: 'no-result',
      );
    }
    if (callResult.error != null) {
      final message = callResult.error.toString();
      return PyodidePythonResult(stderr: '$message\n', error: message);
    }

    final value = callResult.value;
    final map = value is Map ? value : const <dynamic, dynamic>{};
    return PyodidePythonResult(
      stdout: map['stdout']?.toString() ?? '',
      stderr: map['stderr']?.toString() ?? '',
      result: map['result'],
      error: map['error']?.toString(),
    );
  }

  /// Resolves the origin Pyodide is loaded from. Prefers a bundled offline
  /// distribution under [_assetDir] (served over an in-app localhost server);
  /// transparently falls back to the jsDelivr CDN when the assets are absent
  /// or the localhost server can't start. Cached after the first resolution.
  Future<String> _resolveBaseUrl() async {
    final cached = _resolvedBaseUrl;
    if (cached != null) return cached;

    String base = _cdnBase;
    if (!_forceCdn && await _hasBundledAssets()) {
      try {
        // Empty documentRoot so the served path equals the rootBundle asset
        // key exactly: the server loads `documentRoot + uriPathWithoutSlash`,
        // and `'' + 'assets/pyodide/pyodide.js'` is the real asset key (the
        // default './' would yield './assets/...', which rootBundle rejects).
        final server = InAppLocalhostServer(
          port: _localhostPort,
          documentRoot: '',
        );
        await server.start();
        _localhostServer = server;
        base = 'http://localhost:$_localhostPort/$_assetDir/';
        DebugLogger.info(
          'pyodide using bundled offline assets',
          scope: 'tools/pyodide',
          data: {'baseUrl': base},
        );
      } catch (error) {
        DebugLogger.warning(
          'pyodide-localhost-start-failed',
          scope: 'tools/pyodide',
          data: {'error': error.toString()},
        );
        base = _cdnBase;
      }
    } else {
      DebugLogger.info(
        'pyodide using CDN (no bundled assets)',
        scope: 'tools/pyodide',
        data: {'baseUrl': base},
      );
    }

    _resolvedBaseUrl = base;
    return base;
  }

  Future<bool> _hasBundledAssets() async {
    try {
      await rootBundle.load(_assetProbe);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<InAppWebViewController> _ensureReady() async {
    final existingController = _controller;
    final existingReady = _ready;
    if (existingController != null &&
        existingReady != null &&
        existingReady.isCompleted) {
      return existingController;
    }
    if (existingReady != null && !existingReady.isCompleted) {
      await existingReady.future.timeout(_bootTimeout);
      final controller = _controller;
      if (controller == null) {
        throw StateError('Pyodide controller unavailable after boot');
      }
      return controller;
    }

    final ready = Completer<void>();
    _ready = ready;

    final baseUrl = await _resolveBaseUrl();

    final webView = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: _bootstrapHtml,
        baseUrl: WebUri(baseUrl),
        mimeType: 'text/html',
        encoding: 'utf8',
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'conduitPyodideReady',
          callback: (args) {
            final ok = args.isNotEmpty && args.first == true;
            if (ready.isCompleted) return null;
            if (ok) {
              ready.complete();
            } else {
              final detail = args.length > 1 ? args[1]?.toString() : null;
              ready.completeError(
                StateError('Pyodide failed to load: ${detail ?? 'unknown'}'),
              );
            }
            return null;
          },
        );
      },
      onConsoleMessage: (controller, message) {
        if (message.messageLevel == ConsoleMessageLevel.ERROR) {
          DebugLogger.warning(
            'pyodide-console-error',
            scope: 'tools/pyodide',
            data: {'message': message.message},
          );
        }
      },
    );
    _webView = webView;

    try {
      await webView.run();
      await ready.future.timeout(_bootTimeout);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'pyodide-boot-failed',
        scope: 'tools/pyodide',
        error: error,
        stackTrace: stackTrace,
        data: {'baseUrl': baseUrl},
      );
      await _teardown();
      // If booting from bundled localhost assets failed (e.g. Android cleartext
      // policy blocks http://localhost), permanently fall back to the CDN so
      // the next attempt doesn't keep hitting the same wall.
      if (baseUrl != _cdnBase) {
        _forceCdn = true;
        _resolvedBaseUrl = null;
        final server = _localhostServer;
        _localhostServer = null;
        if (server != null) {
          try {
            await server.close();
          } catch (_) {}
        }
      }
      rethrow;
    }

    final controller = _controller;
    if (controller == null) {
      throw StateError('Pyodide controller unavailable after boot');
    }
    return controller;
  }

  Future<void> _teardown() async {
    final webView = _webView;
    _webView = null;
    _controller = null;
    _ready = null;
    if (webView != null) {
      try {
        await webView.dispose();
      } catch (_) {}
    }
  }

  /// Releases the hidden WebView, Pyodide runtime, and the bundled-asset
  /// localhost server. Safe to call when idle; the next [run] transparently
  /// re-boots.
  Future<void> dispose() async {
    await _teardown();
    final server = _localhostServer;
    _localhostServer = null;
    _resolvedBaseUrl = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {}
    }
  }

  /// HTML document hosting Pyodide. Served from the resolved base URL (bundled
  /// localhost assets or [_cdnBase]) so `pyodide.js` and its assets resolve
  /// same-origin (no CORS) and `loadPyodide()` auto-detects its indexURL.
  /// Exposes `window.__conduitRunPython(code)` returning
  /// `{stdout, stderr, result, error}`.
  static const String _bootstrapHtml = '''
<!DOCTYPE html>
<html>
  <head><meta charset="utf-8"></head>
  <body>
    <script src="pyodide.js"></script>
    <script>
      const readyPromise = (async () => {
        const pyodide = await loadPyodide();
        return pyodide;
      })();

      readyPromise
        .then(() => {
          window.flutter_inappwebview.callHandler('conduitPyodideReady', true);
        })
        .catch((e) => {
          window.flutter_inappwebview.callHandler(
            'conduitPyodideReady', false, String(e && e.message ? e.message : e));
        });

      // Mirrors the Open WebUI browser worker: route matplotlib figures to a
      // base64 data URI printed on stdout (the server detects these and turns
      // them into uploaded images). Only applied when the snippet touches
      // matplotlib so non-plot code stays lightweight.
      const MPL_PREAMBLE = `
import os
import base64
from io import BytesIO
os.environ["MPLBACKEND"] = "AGG"
import matplotlib.pyplot
def show(*, block=None):
    buf = BytesIO()
    matplotlib.pyplot.savefig(buf, format="png")
    buf.seek(0)
    img_str = base64.b64encode(buf.read()).decode('utf-8')
    matplotlib.pyplot.clf()
    buf.close()
    print(f"data:image/png;base64,{img_str}")
matplotlib.pyplot.show = show
`;

      window.__conduitRunPython = async (code) => {
        const pyodide = await readyPromise;
        let stdout = "";
        let stderr = "";
        let result = null;
        let error = null;
        pyodide.setStdout({ batched: (m) => { stdout += m + "\\n"; } });
        pyodide.setStderr({ batched: (m) => { stderr += m + "\\n"; } });
        try {
          if (code.indexOf("matplotlib") !== -1) {
            try {
              await pyodide.loadPackage("matplotlib");
              await pyodide.runPythonAsync(MPL_PREAMBLE);
            } catch (e) {
              // If matplotlib can't be loaded, fall through; the user's own
              // import will surface the real error during execution.
            }
          }
          try {
            await pyodide.loadPackagesFromImports(code);
          } catch (e) {
            // Missing/optional packages should not abort execution; the
            // import itself will raise inside Python if truly required.
          }
          let r = await pyodide.runPythonAsync(code);
          if (r && typeof r.toJs === "function") {
            try {
              const js = r.toJs({ dict_converter: Object.fromEntries });
              try { r.destroy(); } catch (e) {}
              r = js;
            } catch (e) {}
          }
          try {
            JSON.stringify(r);
            result = r === undefined ? null : r;
          } catch (e) {
            result = r === undefined || r === null ? null : String(r);
          }
        } catch (e) {
          error = e && e.message ? e.message : String(e);
          stderr += error + "\\n";
        } finally {
          try { pyodide.setStdout({}); } catch (e) {}
          try { pyodide.setStderr({}); } catch (e) {}
        }
        return { stdout: stdout, stderr: stderr, result: result, error: error };
      };
    </script>
  </body>
</html>
''';
}

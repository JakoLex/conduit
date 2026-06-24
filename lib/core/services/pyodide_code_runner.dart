import 'dart:async';

import 'package:flutter/foundation.dart';
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
/// Execution is serialized: a single headless WebView hosts one Pyodide
/// instance and runs snippets one at a time. A run that exceeds its timeout
/// tears the WebView down (a runaway sync loop blocks the JS thread and cannot
/// be interrupted without cross-origin isolation), so the next run re-boots a
/// fresh instance.
class PyodideCodeRunner {
  PyodideCodeRunner._();

  static final PyodideCodeRunner instance = PyodideCodeRunner._();

  /// Pinned Pyodide release. Bump deliberately — the indexURL is derived from
  /// the script location so the version must exist on the jsDelivr CDN.
  static const String _pyodideVersion = 'v0.26.4';
  static const String _cdnBase =
      'https://cdn.jsdelivr.net/pyodide/$_pyodideVersion/full/';

  static const Duration _defaultTimeout = Duration(seconds: 60);
  static const Duration _bootTimeout = Duration(seconds: 90);

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Completer<void>? _ready;

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
      final controller = await _ensureReady();
      final callResult = await controller
          .callAsyncJavaScript(
            functionBody: 'return await window.__conduitRunPython(code);',
            arguments: <String, dynamic>{'code': code},
          )
          .timeout(timeout);

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
    } on TimeoutException {
      // A runaway snippet blocks the JS thread; discard the instance so the
      // next run boots a clean one.
      await _teardown();
      final message =
          'Python execution timed out after ${timeout.inSeconds}s.';
      DebugLogger.warning(
        'pyodide-run-timeout',
        scope: 'tools/pyodide',
        data: {'timeoutSeconds': timeout.inSeconds},
      );
      return PyodidePythonResult(stderr: '$message\n', error: message);
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

    final webView = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: _bootstrapHtml,
        baseUrl: WebUri(_cdnBase),
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
      );
      await _teardown();
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

  /// Releases the hidden WebView and Pyodide runtime. Safe to call when idle;
  /// the next [run] transparently re-boots.
  Future<void> dispose() => _teardown();

  /// HTML document hosting Pyodide. Served from [_cdnBase] so `pyodide.js` and
  /// its assets resolve same-origin (no CORS) and `loadPyodide()` auto-detects
  /// its indexURL. Exposes `window.__conduitRunPython(code)` returning
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

import 'package:checks/checks.dart';
import 'package:conduit/core/services/pyodide_code_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PyodidePythonResult.toAck', () {
    test('acks exactly the keys Open WebUI expects for execute:python', () {
      const result = PyodidePythonResult(
        stdout: 'Hallo Welt!\n',
        stderr: '',
        result: null,
        // error is local-only diagnostics and must NOT be sent to the server.
        error: 'ignored',
      );

      final ack = result.toAck();

      check(ack.keys.toSet()).deepEquals({'stdout', 'stderr', 'result'});
      check(ack['stdout']).equals('Hallo Welt!\n');
      check(ack['stderr']).equals('');
      check(ack['result']).isNull();
    });

    test('preserves a non-null result value', () {
      const result = PyodidePythonResult(stdout: '', stderr: '', result: 42);

      check(result.toAck()['result']).equals(42);
    });
  });
}

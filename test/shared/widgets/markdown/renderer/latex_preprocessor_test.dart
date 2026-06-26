import 'package:checks/checks.dart';
import 'package:conduit/shared/widgets/markdown/renderer/latex_preprocessor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LatexPreprocessor.restorePlaceholders', () {
    test('round-trips inline and block placeholders to \$-delimited LaTeX', () {
      final pre = LatexPreprocessor();
      final extracted = pre.extract(r'Line $a^2$ and $$b^2$$ end.');

      check(pre.containsPlaceholder(extracted)).isTrue();

      final restored = pre.restorePlaceholders(extracted);

      check(pre.containsPlaceholder(restored)).isFalse();
      check(restored.contains(r'$a^2$')).isTrue();
      check(restored.contains(r'$$b^2$$')).isTrue();
    });

    test('leaves placeholder-free text untouched', () {
      final pre = LatexPreprocessor();
      check(pre.restorePlaceholders('no math here')).equals('no math here');
    });

    test(
      'restored text re-extracts cleanly in a fresh, unaware preprocessor',
      () {
        // Mirrors the reasoning/<details> bug: an extracted substring is
        // re-compiled by a different preprocessor that never registered the
        // outer keys. Restoring first lets the inner compile re-extract.
        final outer = LatexPreprocessor();
        final extracted = outer.extract(r'see $E=mc^2$ here');
        final restored = outer.restorePlaceholders(extracted);

        final inner = LatexPreprocessor();
        final reExtracted = inner.extract(restored);

        // The inner preprocessor now owns the expression (its own placeholder),
        // so it can restore/render it — no orphaned token.
        check(inner.containsPlaceholder(reExtracted)).isTrue();
        check(inner.inlineExpressions.values).contains('E=mc^2');
      },
    );
  });
}

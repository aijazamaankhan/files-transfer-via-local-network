import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanbeam/core/storage/json_store.dart';
import 'package:path/path.dart' as p;

void main() {
  test('rapid concurrent writes all succeed and the last value wins', () async {
    final tmp = await Directory.systemTemp.createTemp('js');
    final store = JsonFileStore(p.join(tmp.path, 'x.json'));
    final futures = <Future<void>>[];
    for (var i = 0; i < 200; i++) {
      futures.add(store.write({'i': i}));
      if (i % 7 == 0) await Future<void>.delayed(Duration.zero);
    }
    await Future.wait(futures);
    expect(await store.read(), {'i': 199});
    await tmp.delete(recursive: true);
  });
}

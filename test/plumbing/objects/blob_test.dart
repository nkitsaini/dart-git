import 'dart:convert';
import 'dart:io';

import 'package:file/local.dart';
import 'package:test/test.dart';

import 'package:dart_git/plumbing/objects/blob.dart';
import 'package:dart_git/storage/object_storage.dart';

void main() {
  test('Reads the blob file correctly', () async {
    const fs = LocalFileSystem();
    var objStorage = ObjectStorage('', fs);

    var obj = (await objStorage.readObjectFromPath('test/data/blob'))!;

    expect(obj is GitBlob, equals(true));
    expect(obj.serializeData(), equals(ascii.encode('FOO\n')));

    var fileRawBytes = await File('test/data/blob').readAsBytes();
    var fileBytesDefalted = zlib.decode(fileRawBytes);
    expect(obj.serialize(), equals(fileBytesDefalted));
  });
}

// @dart=2.9

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buffer/buffer.dart';
import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';
import 'package:quiver/core.dart';

import 'package:dart_git/ascii_helper.dart';
import 'package:dart_git/exceptions.dart';
import 'package:dart_git/git_hash.dart';
import 'package:dart_git/utils/file_mode.dart';

final _indexSignature = ascii.encode('DIRC');

class GitIndex {
  int versionNo;
  var entries = <GitIndexEntry>[];

  List<TreeEntry> cache = []; // cached tree extension
  EndOfIndexEntry endOfIndexEntry;

  GitIndex({@required this.versionNo});

  // FIXME: BytesDataReader can throw a range error!
  GitIndex.decode(List<int> bytes) {
    var reader = ByteDataReader(endian: Endian.big, copy: false);
    reader.add(bytes);

    // Read 12 byte header
    var sig = reader.read(4);
    if (sig.length != 4) {
      throw GitIndexCorruptedException('Invalid Signature lenght');
    }

    if (!_listEq(sig, _indexSignature)) {
      throw GitIndexCorruptedException('Invalid signature $sig');
    }

    versionNo = reader.readUint32();
    if (versionNo <= 1 || versionNo > 4) {
      throw Exception('GitIndexError: Version number not supported $versionNo');
    }

    // Read Index Entries
    var numEntries = reader.readUint32();
    for (var i = 0; i < numEntries; i++) {
      var lastEntry = i == 0 ? null : entries[i - 1];
      var entry =
          GitIndexEntry.fromBytes(versionNo, bytes.length, reader, lastEntry);
      entries.add(entry);
    }

    // Read Extensions
    List<int> extensionHeader;
    while (true) {
      extensionHeader = reader.read(4);
      if (!_parseExtension(extensionHeader, reader)) {
        break;
      }
    }

    var hashBytesBuilder = BytesBuilder(copy: false);
    hashBytesBuilder..add(extensionHeader)..add(reader.read(16));

    var expectedHash = GitHash.fromBytes(hashBytesBuilder.toBytes());
    var actualHash = GitHash.compute(
        bytes.sublist(0, bytes.length - 20)); // FIXME: Avoid this copy!
    if (expectedHash != actualHash) {
      print('ExpectedHash: $expectedHash');
      print('ActualHash:  $actualHash');
      throw GitIndexCorruptedException('Invalid Hash');
    }
  }

  static final _treeHeader = ascii.encode('TREE');
  static final _reucHeader = ascii.encode('REUC');
  static final _eoicHeader = ascii.encode('EOIE');

  bool _parseExtension(List<int> header, ByteDataReader reader) {
    if (_listEq(header, _treeHeader)) {
      var length = reader.readUint32();
      var data = reader.read(length);
      _parseCacheTreeExtension(data);
      return true;
    }

    if (_listEq(header, _eoicHeader)) {
      var length = reader.readUint32();
      var data = reader.read(length);
      _parseEndOfIndexEntryExtension(data);
      return true;
    }

    if (_listEq(header, _reucHeader)) {
      var length = reader.readUint32();
      reader.read(length); // Ignoring the data for now
      return true;
    }

    return false;
  }

  void _parseCacheTreeExtension(Uint8List data) {
    var pos = 0;
    while (pos < data.length) {
      var pathEndPos = data.indexOf(0, pos);
      if (pathEndPos == -1) {
        throw GitIndexCorruptedException('Git Cache Index corrupted');
      }
      var path = data.sublist(pos, pathEndPos);
      pos = pathEndPos + 1;

      var entryCountEndPos = data.indexOf(asciiHelper.space, pos);
      if (entryCountEndPos == -1) {
        throw GitIndexCorruptedException('Git Cache Index corrupted');
      }
      var entryCount = data.sublist(pos, entryCountEndPos);
      pos = entryCountEndPos + 1;
      assert(data[pos - 1] == asciiHelper.space);

      var numEntries = int.parse(ascii.decode(entryCount));
      if (numEntries == -1) {
        // Invalid entry
        continue;
      }

      var numSubtreeEndPos = data.indexOf(asciiHelper.newLine, pos);
      if (numSubtreeEndPos == -1) {
        throw GitIndexCorruptedException('Git Cache Index corrupted');
      }
      var numSubTree = data.sublist(pos, numSubtreeEndPos);
      pos = numSubtreeEndPos + 1;
      assert(data[pos - 1] == asciiHelper.newLine);

      var hashBytes = data.sublist(pos, pos + 20);
      pos += 20;

      var treeEntry = TreeEntry(
        path: utf8.decode(path),
        numEntries: numEntries,
        numSubTrees: int.parse(ascii.decode(numSubTree)),
        hash: GitHash.fromBytes(hashBytes),
      );
      cache.add(treeEntry);
    }
  }

  void _parseEndOfIndexEntryExtension(Uint8List data) {
    var reader = ByteDataReader(endian: Endian.big, copy: false);
    reader.add(data);

    if (endOfIndexEntry != null) {
      throw GitIndexCorruptedException(
          'Git Index "End of Index Extension" corrupted');
    }
    endOfIndexEntry = EndOfIndexEntry();
    endOfIndexEntry.offset = reader.readUint32();

    var bytes = reader.read(reader.remainingLength);
    if (bytes.length != 20) {
      throw GitIndexCorruptedException(
          'Git Index "End of Index Extension" hash corrupted');
    }
    endOfIndexEntry.hash = GitHash.fromBytes(bytes);
  }

  List<int> serialize() {
    // Do we support this version of the index?
    if (versionNo != 2) {
      throw Exception(
          'Git Index version $versionNo cannot be serialized. Only version 2 is supported');
    }

    var writer = ByteDataWriter();

    // Header
    writer.write(_indexSignature);
    writer.writeUint32(versionNo);
    writer.writeUint32(entries.length);

    // Entries
    entries.sort((a, b) => a.path.compareTo(b.path));
    entries.forEach((e) => writer.write(e.serialize()));

    // Footer
    var hash = GitHash.compute(writer.toBytes());
    writer.write(hash.bytes);

    return writer.toBytes();
  }

  static final _listEq = const ListEquality().equals;

  Future<void> addPath(String path, GitHash hash) async {
    var stat = await FileStat.stat(path);
    var entry = GitIndexEntry.fromFS(path, stat, hash);
    entries.add(entry);
  }

  Future<void> updatePath(String path, GitHash hash) async {
    var entry = entries.firstWhere((e) => e.path == path, orElse: () => null);
    if (entry == null) {
      var stat = await FileStat.stat(path);
      var entry = GitIndexEntry.fromFS(path, stat, hash);
      entries.add(entry);
      return;
    }

    var stat = await FileStat.stat(path);

    // Existing file
    if (entry != null) {
      entry.hash = hash;
      entry.fileSize = stat.size;

      entry.cTime = stat.changed;
      entry.mTime = stat.modified;
    }
  }

  Future<GitHash> removePath(String pathSpec) async {
    var i = entries.indexWhere((e) => e.path == pathSpec);
    if (i == -1) {
      return null;
    }

    var indexEntry = entries.removeAt(i);
    return indexEntry.hash;
  }
}

class GitIndexEntry {
  DateTime cTime;
  DateTime mTime;

  int dev;
  int ino;

  GitFileMode mode;

  int uid;
  int gid;

  int fileSize;
  GitHash hash;

  GitFileStage stage;

  String path;

  bool skipWorkTree = false;
  bool intentToAdd = false;

  GitIndexEntry({
    @required this.cTime,
    @required this.mTime,
    @required this.dev,
    @required this.ino,
    @required this.mode,
    @required this.uid,
    @required this.gid,
    @required this.fileSize,
    @required this.hash,
    this.stage = GitFileStage.Merged,
    @required this.path,
    @required this.skipWorkTree,
    @required this.intentToAdd,
  });

  GitIndexEntry.fromFS(String path, FileStat stat, GitHash hash) {
    cTime = stat.changed;
    mTime = stat.modified;
    mode = GitFileMode(stat.mode);

    // These don't seem to be exposed in Dart
    ino = 0;
    dev = 0;

    switch (stat.type) {
      case FileSystemEntityType.file:
        mode = GitFileMode.Regular;
        break;
      case FileSystemEntityType.directory:
        mode = GitFileMode.Dir;
        break;
      case FileSystemEntityType.link:
        mode = GitFileMode.Symlink;
        break;
    }

    // Don't seem accessible in Dart -https://github.com/dart-lang/sdk/issues/15078
    uid = 0;
    gid = 0;

    fileSize = stat.size;
    this.hash = hash;
    this.path = path;

    stage = GitFileStage(0);

    assert(!path.startsWith('/'));
  }

  GitIndexEntry.fromBytes(
    int versionNo,
    int indexFileSize,
    ByteDataReader reader,
    GitIndexEntry lastEntry,
  ) {
    var startingBytes = indexFileSize - reader.remainingLength;

    var ctimeSeconds = reader.readUint32();
    var ctimeNanoSeconds = reader.readUint32();

    cTime = DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true);
    cTime = cTime.add(Duration(seconds: ctimeSeconds));
    cTime = cTime.add(Duration(microseconds: ctimeNanoSeconds ~/ 1000));

    var mtimeSeconds = reader.readUint32();
    var mtimeNanoSeconds = reader.readUint32();

    mTime = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    mTime = mTime.add(Duration(seconds: mtimeSeconds));
    mTime = mTime.add(Duration(microseconds: mtimeNanoSeconds ~/ 1000));

    dev = reader.readUint32();
    ino = reader.readUint32();

    // Mode
    mode = GitFileMode(reader.readUint32());

    uid = reader.readUint32();
    gid = reader.readUint32();

    fileSize = reader.readUint32();
    hash = GitHash.fromBytes(reader.read(20));

    var flags = reader.readUint16();
    stage = GitFileStage((flags >> 12) & 0x3);

    intentToAdd = false;
    skipWorkTree = false;

    const hasExtendedFlag = 0x4000;
    if (flags & hasExtendedFlag != 0) {
      if (versionNo <= 2) {
        throw Exception('Index version 2 must not have an extended flag');
      }

      var extended = reader.readUint16(); // extra Flags

      const intentToAddMask = 1 << 13;
      const skipWorkTreeMask = 1 << 14;

      intentToAdd = (extended & intentToAddMask) > 0;
      skipWorkTree = (extended & skipWorkTreeMask) > 0;
    }

    // Read name
    switch (versionNo) {
      case 2:
      case 3:
        const nameMask = 0xfff;
        var len = flags & nameMask;
        path = utf8.decode(reader.read(len));
        break;

      case 4:
        var l = _readVariableWidthInt(reader);
        var base = '';
        if (lastEntry != null) {
          base = lastEntry.path.substring(0, lastEntry.path.length - l);
        }
        var name = _readUntil(reader, 0x00);
        path = base + utf8.decode(name);
        break;

      default:
        throw Exception('Index version not supported');
    }

    // Discard Padding
    if (versionNo == 4) {
      return;
    }
    var endingBytes = indexFileSize - reader.remainingLength;
    var entrySize = endingBytes - startingBytes;
    var padLength = 8 - (entrySize % 8);
    reader.read(padLength);
  }

  Uint8List serialize() {
    if (intentToAdd || skipWorkTree) {
      throw Exception('Index Entry version not supported');
    }

    var writer = ByteDataWriter(endian: Endian.big);

    cTime = cTime.toUtc();
    writer.writeUint32(cTime.millisecondsSinceEpoch ~/ 1000);
    writer.writeUint32((cTime.millisecond * 1000 + cTime.microsecond) * 1000);

    mTime = mTime.toUtc();
    writer.writeUint32(mTime.millisecondsSinceEpoch ~/ 1000);
    writer.writeUint32((mTime.millisecond * 1000 + mTime.microsecond) * 1000);

    writer.writeUint32(dev);
    writer.writeUint32(ino);

    writer.writeUint32(mode.val);

    writer.writeUint32(uid);
    writer.writeUint32(gid);
    writer.writeUint32(fileSize);

    writer.write(hash.bytes);

    var flags = (stage.val & 0x3) << 12;
    const nameMask = 0xfff;

    var pathUtf8 = utf8.encode(path);
    if (pathUtf8.length < nameMask) {
      flags |= pathUtf8.length;
    } else {
      flags |= nameMask;
    }

    writer.writeUint16(flags);
    writer.write(pathUtf8); // This is a problem!

    // Add padding
    const entryHeaderLength = 62;
    var wrote = entryHeaderLength + pathUtf8.length;
    var padLen = 8 - wrote % 8;
    writer.write(Uint8List(padLen));

    return writer.toBytes();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GitIndexEntry &&
          runtimeType == other.runtimeType &&
          cTime == other.cTime &&
          mTime == other.mTime &&
          dev == other.dev &&
          ino == other.ino &&
          uid == other.uid &&
          gid == other.gid &&
          fileSize == other.fileSize &&
          hash == other.hash &&
          stage == other.stage &&
          path == other.path &&
          intentToAdd == other.intentToAdd &&
          skipWorkTree == other.skipWorkTree;

  @override
  int get hashCode => hashObjects(serialize());

  @override
  String toString() {
    return 'GitIndexEntry{cTime: $cTime, mTime: $mTime, dev: $dev, ino: $ino, uid: $uid, gid: $gid, fileSize: $fileSize, hash: $hash, stage: $stage, path: $path}';
  }
}

class TreeEntry extends Equatable {
  final String path;
  final int numEntries;
  final int numSubTrees;
  final GitHash hash;

  const TreeEntry({this.path, this.numEntries, this.numSubTrees, this.hash});

  @override
  List<Object> get props => [path, numEntries, numSubTrees, hash];

  @override
  bool get stringify => true;
}

/// EndOfIndexEntry is the End of Index Entry (EOIE) is used to locate the end of
/// the variable length index entries and the beginning of the extensions. Code
/// can take advantage of this to quickly locate the index extensions without
/// having to parse through all of the index entries.
///
///  Because it must be able to be loaded before the variable length cache
///  entries and other index extensions, this extension must be written last.
class EndOfIndexEntry {
  int offset;
  GitHash hash;
}

class GitFileStage extends Equatable {
  final int val;

  const GitFileStage(this.val);

  static const Merged = GitFileStage(1);
  static const AncestorMode = GitFileStage(1);
  static const OurMode = GitFileStage(2);
  static const TheirMode = GitFileStage(3);

  @override
  List<Object> get props => [val];

  @override
  bool get stringify => true;
}

// ReadVariableWidthInt reads and returns an int in Git VLQ special format:
//
// Ordinary VLQ has some redundancies, example:  the number 358 can be
// encoded as the 2-octet VLQ 0x8166 or the 3-octet VLQ 0x808166 or the
// 4-octet VLQ 0x80808166 and so forth.
//
// To avoid these redundancies, the VLQ format used in Git removes this
// prepending redundancy and extends the representable range of shorter
// VLQs by adding an offset to VLQs of 2 or more octets in such a way
// that the lowest possible value for such an (N+1)-octet VLQ becomes
// exactly one more than the maximum possible value for an N-octet VLQ.
// In particular, since a 1-octet VLQ can store a maximum value of 127,
// the minimum 2-octet VLQ (0x8000) is assigned the value 128 instead of
// 0. Conversely, the maximum value of such a 2-octet VLQ (0xff7f) is
// 16511 instead of just 16383. Similarly, the minimum 3-octet VLQ
// (0x808000) has a value of 16512 instead of zero, which means
// that the maximum 3-octet VLQ (0xffff7f) is 2113663 instead of
// just 2097151.  And so forth.
//
// This is how the offset is saved in C:
//
//     dheader[pos] = ofs & 127;
//     while (ofs >>= 7)
//         dheader[--pos] = 128 | (--ofs & 127);
//

final _maskContinue = 128; // 1000 000
final _maskLength = 127; // 0111 1111
final _lengthBits = 7; // subsequent bytes has 7 bits to store the length

int _readVariableWidthInt(ByteDataReader file) {
  var c = file.readInt8();

  var v = (c & _maskLength);
  while (c & _maskContinue > 0) {
    v++;

    c = file.readInt8();

    v = (v << _lengthBits) + (c & _maskLength);
  }

  return v;
}

List<int> _readUntil(ByteDataReader file, int r) {
  var l = <int>[];
  while (true) {
    var c = file.readInt8();
    if (c == r) {
      return l;
    }
    l.add(c);
  }
}

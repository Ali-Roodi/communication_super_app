import 'dart:typed_data';

/// BLAKE3 (default hash mode, extendable output), in pure Dart.
///
/// A port of the BLAKE3 reference implementation
/// (github.com/BLAKE3-team/BLAKE3, `reference_impl/reference_impl.rs`). It
/// exists for one caller — the inter-organizational activation code
/// (`ActivationCode`), which has to agree byte for byte with the mentor's
/// Windows code generator and with the `Blake3.java` the earlier S2MS app
/// shipped. The tests pin it to the official test vectors *and* to outputs of
/// that Java class, so neither can drift.
///
/// Only the plain hash is implemented: keyed hashing and key derivation have no
/// caller, and an unexercised mode is where a port quietly goes wrong.
///
/// Word arithmetic is done on Dart's 64-bit `int` and masked back to 32 bits
/// after every addition and rotation. This file is Android-only code (the app
/// has no web target), where `int` is a true 64-bit integer.
class Blake3 {
  Blake3._();

  /// Hashes [input] and returns the first [outputLength] bytes of the output.
  ///
  /// BLAKE3 is an extendable-output function: a shorter output is a prefix of
  /// a longer one, which is exactly what `hexdigest(n)` in the Java class
  /// returns.
  static Uint8List hash(List<int> input, {int outputLength = 32}) {
    if (outputLength < 0) {
      throw ArgumentError.value(outputLength, 'outputLength', 'is negative');
    }
    final hasher = _Hasher()..update(input);
    return hasher.finalize(outputLength);
  }

  /// [hash] as lowercase hex — the same text `Blake3.hexdigest(n)` produces.
  static String hexDigest(List<int> input, {int outputLength = 32}) {
    final bytes = hash(input, outputLength: outputLength);
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }
}

const int _mask32 = 0xFFFFFFFF;
const int _blockLen = 64;
const int _chunkLen = 1024;

const int _chunkStart = 1 << 0;
const int _chunkEnd = 1 << 1;
const int _parent = 1 << 2;
const int _root = 1 << 3;

const List<int> _iv = [
  0x6A09E667,
  0xBB67AE85,
  0x3C6EF372,
  0xA54FF53A,
  0x510E527F,
  0x9B05688C,
  0x1F83D9AB,
  0x5BE0CD19,
];

const List<int> _msgPermutation = [
  2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8, //
];

int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & _mask32;

void _g(List<int> s, int a, int b, int c, int d, int mx, int my) {
  s[a] = (s[a] + s[b] + mx) & _mask32;
  s[d] = _rotr(s[d] ^ s[a], 16);
  s[c] = (s[c] + s[d]) & _mask32;
  s[b] = _rotr(s[b] ^ s[c], 12);
  s[a] = (s[a] + s[b] + my) & _mask32;
  s[d] = _rotr(s[d] ^ s[a], 8);
  s[c] = (s[c] + s[d]) & _mask32;
  s[b] = _rotr(s[b] ^ s[c], 7);
}

void _round(List<int> s, List<int> m) {
  // Columns.
  _g(s, 0, 4, 8, 12, m[0], m[1]);
  _g(s, 1, 5, 9, 13, m[2], m[3]);
  _g(s, 2, 6, 10, 14, m[4], m[5]);
  _g(s, 3, 7, 11, 15, m[6], m[7]);
  // Diagonals.
  _g(s, 0, 5, 10, 15, m[8], m[9]);
  _g(s, 1, 6, 11, 12, m[10], m[11]);
  _g(s, 2, 7, 8, 13, m[12], m[13]);
  _g(s, 3, 4, 9, 14, m[14], m[15]);
}

List<int> _permute(List<int> m) =>
    List<int>.generate(16, (i) => m[_msgPermutation[i]]);

/// The compression function: 16 output words.
List<int> _compress(
  List<int> chainingValue,
  List<int> blockWords,
  int counter,
  int blockLen,
  int flags,
) {
  final state = <int>[
    ...chainingValue,
    _iv[0],
    _iv[1],
    _iv[2],
    _iv[3],
    counter & _mask32,
    (counter >>> 32) & _mask32,
    blockLen,
    flags,
  ];
  var block = blockWords;
  for (var r = 0; r < 7; r++) {
    _round(state, block);
    if (r < 6) block = _permute(block);
  }
  for (var i = 0; i < 8; i++) {
    state[i] ^= state[i + 8];
    state[i + 8] ^= chainingValue[i];
  }
  return state;
}

/// A 64-byte block as sixteen little-endian words; missing bytes are zero.
List<int> _wordsFromBlock(Uint8List block) {
  final data = ByteData.sublistView(block);
  return List<int>.generate(16, (i) => data.getUint32(i * 4, Endian.little));
}

/// The state needed to produce either a chaining value or root output bytes.
class _Output {
  _Output(
    this.inputChainingValue,
    this.blockWords,
    this.counter,
    this.blockLen,
    this.flags,
  );

  final List<int> inputChainingValue;
  final List<int> blockWords;
  final int counter;
  final int blockLen;
  final int flags;

  List<int> chainingValue() => _compress(
    inputChainingValue,
    blockWords,
    counter,
    blockLen,
    flags,
  ).sublist(0, 8);

  Uint8List rootOutputBytes(int length) {
    final out = Uint8List(length);
    final view = ByteData.sublistView(out);
    var written = 0;
    var outputBlockCounter = 0;
    while (written < length) {
      final words = _compress(
        inputChainingValue,
        blockWords,
        outputBlockCounter,
        blockLen,
        flags | _root,
      );
      for (final word in words) {
        if (written >= length) break;
        final remaining = length - written;
        if (remaining >= 4) {
          view.setUint32(written, word, Endian.little);
          written += 4;
        } else {
          for (var i = 0; i < remaining; i++) {
            out[written++] = (word >>> (8 * i)) & 0xFF;
          }
        }
      }
      outputBlockCounter++;
    }
    return out;
  }
}

class _ChunkState {
  _ChunkState(this.chainingValue, this.chunkCounter, this.flags);

  List<int> chainingValue;
  final int chunkCounter;
  final int flags;
  final Uint8List block = Uint8List(_blockLen);
  int blockLen = 0;
  int blocksCompressed = 0;

  int get length => _blockLen * blocksCompressed + blockLen;

  int get _startFlag => blocksCompressed == 0 ? _chunkStart : 0;

  void update(List<int> input, int start, int end) {
    var offset = start;
    while (offset < end) {
      // A full block is only compressed once more input follows it: the last
      // block of a chunk carries CHUNK_END, so it must wait for [output].
      if (blockLen == _blockLen) {
        chainingValue = _compress(
          chainingValue,
          _wordsFromBlock(block),
          chunkCounter,
          _blockLen,
          flags | _startFlag,
        ).sublist(0, 8);
        blocksCompressed++;
        block.fillRange(0, _blockLen, 0);
        blockLen = 0;
      }
      final want = _blockLen - blockLen;
      final take = (end - offset) < want ? (end - offset) : want;
      block.setRange(blockLen, blockLen + take, input, offset);
      blockLen += take;
      offset += take;
    }
  }

  _Output output() => _Output(
    chainingValue,
    _wordsFromBlock(block),
    chunkCounter,
    blockLen,
    flags | _startFlag | _chunkEnd,
  );
}

_Output _parentOutput(
  List<int> left,
  List<int> right,
  List<int> key,
  int flags,
) => _Output(key, [...left, ...right], 0, _blockLen, _parent | flags);

class _Hasher {
  _Hasher() : _chunkState = _ChunkState(_iv, 0, 0);

  static const List<int> _key = _iv;
  static const int _flags = 0;

  _ChunkState _chunkState;
  final List<List<int>> _cvStack = [];

  void _addChunkChainingValue(List<int> newCv, int totalChunks) {
    // Merge completed subtrees: one merge per trailing zero bit of the total
    // number of chunks so far.
    var cv = newCv;
    var total = totalChunks;
    while (total & 1 == 0) {
      cv = _parentOutput(
        _cvStack.removeLast(),
        cv,
        _key,
        _flags,
      ).chainingValue();
      total >>= 1;
    }
    _cvStack.add(cv);
  }

  void update(List<int> input) {
    var offset = 0;
    while (offset < input.length) {
      // A full chunk is only finalized once more input follows it, for the
      // same reason as a full block in [_ChunkState.update].
      if (_chunkState.length == _chunkLen) {
        final chunkCv = _chunkState.output().chainingValue();
        final totalChunks = _chunkState.chunkCounter + 1;
        _addChunkChainingValue(chunkCv, totalChunks);
        _chunkState = _ChunkState(_key, totalChunks, _flags);
      }
      final want = _chunkLen - _chunkState.length;
      final remaining = input.length - offset;
      final take = remaining < want ? remaining : want;
      _chunkState.update(input, offset, offset + take);
      offset += take;
    }
  }

  Uint8List finalize(int outputLength) {
    var output = _chunkState.output();
    for (var i = _cvStack.length - 1; i >= 0; i--) {
      output = _parentOutput(_cvStack[i], output.chainingValue(), _key, _flags);
    }
    return output.rootOutputBytes(outputLength);
  }
}

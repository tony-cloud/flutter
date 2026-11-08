// Copyright 2026 The Open Shorebird Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Ed25519 signature verification (RFC 8032 section 5.1.7), used only to
/// authenticate Open Shorebird artifact catalogs.
///
/// Verification handles public data only, so it has no secret-dependent
/// timing to protect. It rejects non-canonical point encodings and a scalar
/// `S >= L`, and checks `[S]B == R + [k]A`. The same algorithm is implemented in
/// shorebird-workspace `scripts/artifact_catalog.py`; both are tested against
/// the RFC 8032 vectors.
library;

import 'package:crypto/crypto.dart' show sha512;

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _l = (BigInt.one << 252) + BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d = (BigInt.from(-121665) * _inv(BigInt.from(121666))) % _p;
final BigInt _sqrtM1 = BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p);
final BigInt _two = BigInt.two;

BigInt _inv(BigInt x) => x.modPow(_p - _two, _p);

/// A point in extended twisted Edwards coordinates (X, Y, Z, T).
typedef _Point = (BigInt, BigInt, BigInt, BigInt);

_Point _add(_Point p1, _Point p2) {
  final BigInt a = ((p1.$2 - p1.$1) * (p2.$2 - p2.$1)) % _p;
  final BigInt b = ((p1.$2 + p1.$1) * (p2.$2 + p2.$1)) % _p;
  final BigInt c = (_two * p1.$4 * p2.$4 * _d) % _p;
  final BigInt d = (_two * p1.$3 * p2.$3) % _p;
  final BigInt e = b - a, f = d - c, g = d + c, h = b + a;
  return ((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Point _mul(BigInt scalar, _Point point) {
  _Point result = (BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
  var s = scalar;
  var q = point;
  while (s > BigInt.zero) {
    if (s.isOdd) {
      result = _add(result, q);
    }
    q = _add(q, q);
    s = s >> 1;
  }
  return result;
}

bool _equal(_Point p1, _Point p2) =>
    (p1.$1 * p2.$3 - p2.$1 * p1.$3) % _p == BigInt.zero &&
    (p1.$2 * p2.$3 - p2.$2 * p1.$3) % _p == BigInt.zero;

BigInt? _recoverX(BigInt y, int sign) {
  if (y >= _p) {
    return null;
  }
  final BigInt x2 = ((y * y - BigInt.one) * _inv(_d * y * y + BigInt.one)) % _p;
  if (x2 == BigInt.zero) {
    return sign == 1 ? null : BigInt.zero;
  }
  BigInt x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) {
    x = (x * _sqrtM1) % _p;
  }
  if ((x * x - x2) % _p != BigInt.zero) {
    return null;
  }
  if ((x.isOdd ? 1 : 0) != sign) {
    x = _p - x;
  }
  return x;
}

final _Point _base = () {
  final BigInt y = (BigInt.from(4) * _inv(BigInt.from(5))) % _p;
  final BigInt x = _recoverX(y, 0)!;
  return (x, y, BigInt.one, (x * y) % _p);
}();

BigInt _littleEndian(List<int> bytes) {
  BigInt result = BigInt.zero;
  for (int i = bytes.length - 1; i >= 0; i--) {
    result = (result << 8) | BigInt.from(bytes[i]);
  }
  return result;
}

_Point? _decompress(List<int> bytes) {
  if (bytes.length != 32) {
    return null;
  }
  BigInt y = _littleEndian(bytes);
  final int sign = (bytes[31] >> 7) & 1;
  y = y & ((BigInt.one << 255) - BigInt.one);
  final BigInt? x = _recoverX(y, sign);
  if (x == null) {
    return null;
  }
  return (x, y, BigInt.one, (x * y) % _p);
}

/// Whether [signature] is a valid Ed25519 signature of [message] by the
/// 32-byte [publicKey].
bool ed25519Verify(List<int> publicKey, List<int> message, List<int> signature) {
  if (publicKey.length != 32 || signature.length != 64) {
    return false;
  }
  final _Point? a = _decompress(publicKey);
  final _Point? r = _decompress(signature.sublist(0, 32));
  if (a == null || r == null) {
    return false;
  }
  final BigInt s = _littleEndian(signature.sublist(32));
  if (s >= _l) {
    return false;
  }
  final List<int> digest = sha512.convert(<int>[
    ...signature.sublist(0, 32),
    ...publicKey,
    ...message,
  ]).bytes;
  final BigInt k = _littleEndian(digest) % _l;
  return _equal(_mul(s, _base), _add(r, _mul(k, a)));
}

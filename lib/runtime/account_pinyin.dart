import 'dart:ffi';
import 'dart:io';

/// Transliterate the complete observed account using macOS Core Foundation.
/// This does not construct nicknames, alternate identities, or alias lists.
class AccountPinyin {
  static final _cache = <String, String?>{};
  static final _native = Platform.isMacOS ? _CoreFoundationLatin() : null;

  static bool contains(String account, String requested) {
    if (!RegExp(r"^[A-Za-z][A-Za-z0-9 _.'-]*$").hasMatch(requested)) {
      return false;
    }
    final query = _compact(requested);
    if (query.isEmpty) return false;
    try {
      if (!_cache.containsKey(account)) {
        if (_cache.length >= 256) _cache.remove(_cache.keys.first);
        final text = _native?.latin(account);
        _cache[account] = text == null ? null : _compact(text);
      }
      return _cache[account]?.contains(query) == true;
    } catch (_) {
      // Literal account matching remains available if a system binding fails.
      return false;
    }
  }

  static String _compact(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

class _CoreFoundationLatin {
  final _cf = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
  final _system = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');

  late final _allocate = _system.lookupFunction<
      Pointer<Void> Function(IntPtr, IntPtr),
      Pointer<Void> Function(int, int)>('calloc');
  late final _free = _system.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('free');
  late final _create = _cf.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, IntPtr),
      Pointer<Void> Function(Pointer<Void>, int)>('CFStringCreateMutable');
  late final _append = _cf.lookupFunction<
      Void Function(Pointer<Void>, Pointer<Uint16>, IntPtr),
      void Function(
          Pointer<Void>, Pointer<Uint16>, int)>('CFStringAppendCharacters');
  late final _transform = _cf.lookupFunction<
      Uint8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint8),
      int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
          int)>('CFStringTransform');
  late final _length = _cf.lookupFunction<IntPtr Function(Pointer<Void>),
      int Function(Pointer<Void>)>('CFStringGetLength');
  late final _character = _cf.lookupFunction<
      Uint16 Function(Pointer<Void>, IntPtr),
      int Function(Pointer<Void>, int)>('CFStringGetCharacterAtIndex');
  late final _release = _cf.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('CFRelease');
  late final _toLatin =
      _cf.lookup<Pointer<Void>>('kCFStringTransformToLatin').value;
  late final _stripDiacritics =
      _cf.lookup<Pointer<Void>>('kCFStringTransformStripDiacritics').value;

  String? latin(String text) {
    if (text.isEmpty) return '';
    final units = text.codeUnits;
    final memory = _allocate(units.length, 2);
    if (memory == nullptr) return null;
    Pointer<Void> mutable = nullptr;
    try {
      final characters = memory.cast<Uint16>();
      characters.asTypedList(units.length).setAll(0, units);
      mutable = _create(nullptr, 0);
      if (mutable == nullptr) return null;
      _append(mutable, characters, units.length);
      if (_transform(mutable, nullptr, _toLatin, 0) == 0 ||
          _transform(mutable, nullptr, _stripDiacritics, 0) == 0) {
        return null;
      }
      final count = _length(mutable);
      return String.fromCharCodes(
          List.generate(count, (index) => _character(mutable, index)));
    } finally {
      if (mutable != nullptr) _release(mutable);
      _free(memory);
    }
  }
}

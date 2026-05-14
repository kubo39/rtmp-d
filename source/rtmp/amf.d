module rtmp.amf;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.array : Appender;

enum Amf0Type : ubyte {
    number = 0x00,
    boolean = 0x01,
    string_ = 0x02,
    object = 0x03,
    null_ = 0x05,
    undefined = 0x06,
    ecmaArray = 0x08,
    objectEnd = 0x09,
    strictArray = 0x0a,
    longString = 0x0c,
}

struct AmfKeyValue {
    string key;
    AmfValue value;
}

struct AmfObject {
    private AmfKeyValue[] entries_;

    this(AmfKeyValue[] entries) {
        entries_ = entries;
    }

    inout(AmfKeyValue)[] entries() inout return {
        return entries_;
    }

    AmfValue* opBinaryRight(string op : "in")(string key) return {
        foreach (ref e; entries_) {
            if (e.key == key)
                return &e.value;
        }
        return null;
    }

    void put(string key, AmfValue value) {
        foreach (ref e; entries_) {
            if (e.key == key) {
                e.value = value;
                return;
            }
        }
        entries_ ~= AmfKeyValue(key, value);
    }

    size_t length() const {
        return entries_.length;
    }

    bool opEquals(const AmfObject other) const {
        if (entries_.length != other.entries_.length)
            return false;
        foreach (i, ref e; entries_) {
            if (e.key != other.entries_[i].key || e.value != other.entries_[i].value)
                return false;
        }
        return true;
    }

    size_t toHash() const nothrow @safe {
        size_t h = 0;
        foreach (ref e; entries_) {
            h ^= hashOf(e.key);
            h ^= hashOf(e.value.kind);
        }
        return h;
    }
}

struct AmfValue {
    enum Kind {
        number,
        boolean,
        string_,
        object,
        null_,
        undefined,
        ecmaArray,
        strictArray,
        longString,
    }

    Kind kind;

    private double number_;
    private bool boolean_;
    private string str_;
    private AmfObject object_;
    private AmfValue[] array_;

    this(double v) { kind = Kind.number; number_ = v; }
    this(bool v) { kind = Kind.boolean; boolean_ = v; }
    this(string v) { kind = Kind.string_; str_ = v; }
    this(AmfObject v) { kind = Kind.object; object_ = v; }
    this(AmfValue[] v) { kind = Kind.strictArray; array_ = v; }

    static AmfValue null_() { AmfValue v; v.kind = Kind.null_; return v; }
    static AmfValue undefined() { AmfValue v; v.kind = Kind.undefined; return v; }

    static AmfValue ecmaArray(AmfObject obj) {
        AmfValue v;
        v.kind = Kind.ecmaArray;
        v.object_ = obj;
        return v;
    }

    static AmfValue longString(string s) {
        AmfValue v;
        v.kind = Kind.longString;
        v.str_ = s;
        return v;
    }

    double number() const { return number_; }
    bool boolean() const { return boolean_; }
    string str() const { return str_; }
    inout(AmfObject) object() inout { return object_; }
    inout(AmfValue)[] array() inout { return array_; }

    bool opEquals(const AmfValue other) const {
        if (kind != other.kind)
            return false;
        final switch (kind) {
            case Kind.number: return number_ == other.number_;
            case Kind.boolean: return boolean_ == other.boolean_;
            case Kind.string_: return str_ == other.str_;
            case Kind.longString: return str_ == other.str_;
            case Kind.object: return object_ == other.object_;
            case Kind.ecmaArray: return object_ == other.object_;
            case Kind.strictArray: return array_ == other.array_;
            case Kind.null_: return true;
            case Kind.undefined: return true;
        }
    }

    size_t toHash() const nothrow @safe {
        size_t h = hashOf(kind);
        final switch (kind) {
            case Kind.number: h ^= hashOf(number_); break;
            case Kind.boolean: h ^= hashOf(boolean_); break;
            case Kind.string_: h ^= hashOf(str_); break;
            case Kind.longString: h ^= hashOf(str_); break;
            case Kind.object: h ^= object_.toHash(); break;
            case Kind.ecmaArray: h ^= object_.toHash(); break;
            case Kind.strictArray:
                foreach (ref v; array_)
                    h ^= v.toHash();
                break;
            case Kind.null_: break;
            case Kind.undefined: break;
        }
        return h;
    }
}

class AmfDecodeException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// --- Encoding ---

ubyte[] encode(const AmfValue value) {
    auto buf = Appender!(ubyte[])();
    encodeValue(buf, value);
    return buf[];
}

ubyte[] encodeAll(const(AmfValue)[] values) {
    auto buf = Appender!(ubyte[])();
    foreach (ref v; values)
        encodeValue(buf, v);
    return buf[];
}

private void encodeValue(ref Appender!(ubyte[]) buf, const AmfValue value) {
    final switch (value.kind) {
        case AmfValue.Kind.number:
            buf ~= Amf0Type.number;
            buf ~= toNetworkOrder(value.number_)[];
            break;
        case AmfValue.Kind.boolean:
            buf ~= Amf0Type.boolean;
            buf ~= value.boolean_ ? ubyte(0x01) : ubyte(0x00);
            break;
        case AmfValue.Kind.string_:
            buf ~= Amf0Type.string_;
            encodeUtf8(buf, value.str_);
            break;
        case AmfValue.Kind.longString:
            buf ~= Amf0Type.longString;
            encodeLongUtf8(buf, value.str_);
            break;
        case AmfValue.Kind.object:
            buf ~= Amf0Type.object;
            encodeObjectEntries(buf, value.object_);
            break;
        case AmfValue.Kind.null_:
            buf ~= Amf0Type.null_;
            break;
        case AmfValue.Kind.undefined:
            buf ~= Amf0Type.undefined;
            break;
        case AmfValue.Kind.ecmaArray:
            buf ~= Amf0Type.ecmaArray;
            auto len = cast(uint) value.object_.length;
            buf ~= nativeToBigEndian(len)[];
            encodeObjectEntries(buf, value.object_);
            break;
        case AmfValue.Kind.strictArray:
            buf ~= Amf0Type.strictArray;
            auto len = cast(uint) value.array_.length;
            buf ~= nativeToBigEndian(len)[];
            foreach (ref elem; value.array_)
                encodeValue(buf, elem);
            break;
    }
}

private void encodeUtf8(ref Appender!(ubyte[]) buf, string s) {
    auto len = cast(ushort) s.length;
    buf ~= nativeToBigEndian(len)[];
    buf ~= cast(const(ubyte)[]) s;
}

private void encodeLongUtf8(ref Appender!(ubyte[]) buf, string s) {
    auto len = cast(uint) s.length;
    buf ~= nativeToBigEndian(len)[];
    buf ~= cast(const(ubyte)[]) s;
}

private void encodeObjectEntries(ref Appender!(ubyte[]) buf, const AmfObject obj) {
    foreach (ref entry; obj.entries) {
        encodeUtf8(buf, entry.key);
        encodeValue(buf, entry.value);
    }
    buf ~= ubyte(0x00);
    buf ~= ubyte(0x00);
    buf ~= ubyte(0x09);
}

private ubyte[8] toNetworkOrder(double value) {
    ulong bits = *cast(const(ulong)*)&value;
    return nativeToBigEndian(bits);
}

// --- Decoding ---

struct DecodeResult {
    AmfValue value;
    size_t bytesConsumed;
}

DecodeResult decode(const(ubyte)[] data) {
    size_t pos = 0;
    auto value = decodeValue(data, pos);
    return DecodeResult(value, pos);
}

AmfValue[] decodeAll(const(ubyte)[] data) {
    AmfValue[] results;
    size_t pos = 0;
    while (pos < data.length)
        results ~= decodeValue(data, pos);
    return results;
}

private AmfValue decodeValue(const(ubyte)[] data, ref size_t pos) {
    if (pos >= data.length)
        throw new AmfDecodeException("unexpected end of data");

    auto marker = cast(Amf0Type) data[pos];
    pos++;

    switch (marker) {
        case Amf0Type.number:
            return AmfValue(decodeNumber(data, pos));
        case Amf0Type.boolean:
            return AmfValue(decodeBoolean(data, pos));
        case Amf0Type.string_:
            return AmfValue(decodeUtf8String(data, pos));
        case Amf0Type.longString:
            return AmfValue.longString(decodeLongUtf8String(data, pos));
        case Amf0Type.object:
            return AmfValue(decodeObject(data, pos));
        case Amf0Type.null_:
            return AmfValue.null_();
        case Amf0Type.undefined:
            return AmfValue.undefined();
        case Amf0Type.ecmaArray:
            return decodeEcmaArray(data, pos);
        case Amf0Type.strictArray:
            return decodeStrictArray(data, pos);
        default:
            throw new AmfDecodeException("unknown AMF0 type marker: " ~ formatHex(cast(ubyte) marker));
    }
}

private double decodeNumber(const(ubyte)[] data, ref size_t pos) {
    ensureAvailable(data, pos, 8);
    ubyte[8] bytes = data[pos .. pos + 8];
    pos += 8;
    ulong bits = bigEndianToNative!ulong(bytes);
    return *cast(double*)&bits;
}

private bool decodeBoolean(const(ubyte)[] data, ref size_t pos) {
    ensureAvailable(data, pos, 1);
    auto val = data[pos] != 0;
    pos++;
    return val;
}

private string decodeUtf8String(const(ubyte)[] data, ref size_t pos) {
    ensureAvailable(data, pos, 2);
    ubyte[2] lenBytes = data[pos .. pos + 2];
    const len = bigEndianToNative!ushort(lenBytes);
    pos += 2;
    ensureAvailable(data, pos, len);
    auto str = cast(string) data[pos .. pos + len].dup;
    pos += len;
    return str;
}

private string decodeLongUtf8String(const(ubyte)[] data, ref size_t pos) {
    ensureAvailable(data, pos, 4);
    ubyte[4] lenBytes = data[pos .. pos + 4];
    const len = bigEndianToNative!uint(lenBytes);
    pos += 4;
    ensureAvailable(data, pos, len);
    auto str = cast(string) data[pos .. pos + len].dup;
    pos += len;
    return str;
}

private AmfObject decodeObject(const(ubyte)[] data, ref size_t pos) {
    AmfKeyValue[] entries;
    while (true) {
        if (isObjectEnd(data, pos)) {
            pos += 3;
            break;
        }
        auto key = decodeUtf8String(data, pos);
        auto value = decodeValue(data, pos);
        entries ~= AmfKeyValue(key, value);
    }
    return AmfObject(entries);
}

private AmfValue decodeEcmaArray(const(ubyte)[] data, ref size_t pos) {
    ensureAvailable(data, pos, 4);
    pos += 4; // count is approximate; actual end is ObjectEnd marker
    auto obj = decodeObject(data, pos);
    return AmfValue.ecmaArray(obj);
}

private AmfValue decodeStrictArray(const(ubyte)[] data, ref size_t pos) {
    ensureAvailable(data, pos, 4);
    ubyte[4] lenBytes = data[pos .. pos + 4];
    const count = bigEndianToNative!uint(lenBytes);
    pos += 4;
    AmfValue[] elements;
    elements.reserve(count);
    foreach (_; 0 .. count)
        elements ~= decodeValue(data, pos);
    return AmfValue(elements);
}

private bool isObjectEnd(const(ubyte)[] data, size_t pos) {
    return pos + 3 <= data.length
        && data[pos] == 0x00
        && data[pos + 1] == 0x00
        && data[pos + 2] == 0x09;
}

private void ensureAvailable(const(ubyte)[] data, size_t pos, size_t needed) {
    if (pos + needed > data.length)
        throw new AmfDecodeException("unexpected end of data: need "
            ~ formatUint(needed) ~ " bytes at position " ~ formatUint(pos));
}

private string formatHex(ubyte v) {
    immutable hexDigits = "0123456789abcdef";
    return "0x" ~ [hexDigits[v >> 4], hexDigits[v & 0x0f]];
}

private string formatUint(size_t v) {
    if (v == 0) return "0";
    char[] buf;
    while (v > 0) {
        buf ~= cast(char)('0' + v % 10);
        v /= 10;
    }
    char[] result;
    foreach_reverse (c; buf)
        result ~= c;
    return cast(string) result;
}

unittest {
    // Number round-trip
    auto numVal = AmfValue(42.5);
    auto encoded = encode(numVal);
    const decoded = decode(encoded);
    assert(decoded.value == numVal);
    assert(decoded.bytesConsumed == encoded.length);
}

unittest {
    // Boolean round-trip
    auto trueVal = AmfValue(true);
    auto falseVal = AmfValue(false);
    assert(decode(encode(trueVal)).value == trueVal);
    assert(decode(encode(falseVal)).value == falseVal);
}

unittest {
    // String round-trip
    auto strVal = AmfValue("hello");
    assert(decode(encode(strVal)).value == strVal);

    // Empty string
    auto emptyStr = AmfValue("");
    assert(decode(encode(emptyStr)).value == emptyStr);
}

unittest {
    // Null and Undefined
    auto nullVal = AmfValue.null_();
    auto undefVal = AmfValue.undefined();
    assert(decode(encode(nullVal)).value.kind == AmfValue.Kind.null_);
    assert(decode(encode(undefVal)).value.kind == AmfValue.Kind.undefined);
}

unittest {
    // Object round-trip
    auto obj = AmfObject([
        AmfKeyValue("app", AmfValue("live")),
        AmfKeyValue("flashVer", AmfValue("FMLE/3.0")),
        AmfKeyValue("tcUrl", AmfValue("rtmp://localhost/live")),
    ]);
    auto objVal = AmfValue(obj);
    const decoded = decode(encode(objVal));
    assert(decoded.value == objVal);
}

unittest {
    // Nested object
    auto inner = AmfObject([
        AmfKeyValue("width", AmfValue(1920.0)),
        AmfKeyValue("height", AmfValue(1080.0)),
    ]);
    auto outer = AmfObject([
        AmfKeyValue("name", AmfValue("test")),
        AmfKeyValue("video", AmfValue(inner)),
    ]);
    auto val = AmfValue(outer);
    assert(decode(encode(val)).value == val);
}

unittest {
    // ECMA Array round-trip
    auto obj = AmfObject([
        AmfKeyValue("duration", AmfValue(0.0)),
        AmfKeyValue("width", AmfValue(1280.0)),
    ]);
    auto ecma = AmfValue.ecmaArray(obj);
    const decoded = decode(encode(ecma));
    assert(decoded.value.kind == AmfValue.Kind.ecmaArray);
    assert(decoded.value.object == obj);
}

unittest {
    // Strict Array round-trip
    auto arr = AmfValue([
        AmfValue(1.0),
        AmfValue("two"),
        AmfValue(true),
    ]);
    assert(decode(encode(arr)).value == arr);
}

unittest {
    // Long String round-trip
    char[] longChars;
    longChars.length = 70_000;
    longChars[] = 'x';
    auto longStr = AmfValue.longString(cast(string) longChars);
    const decoded = decode(encode(longStr));
    assert(decoded.value.kind == AmfValue.Kind.longString);
    assert(decoded.value.str == longStr.str);
}

unittest {
    // Multiple values (connect command pattern)
    auto cmd = AmfValue("connect");
    auto txId = AmfValue(1.0);
    auto cmdObj = AmfValue(AmfObject([
        AmfKeyValue("app", AmfValue("live")),
        AmfKeyValue("tcUrl", AmfValue("rtmp://localhost/live")),
        AmfKeyValue("fpad", AmfValue(false)),
        AmfKeyValue("audioCodecs", AmfValue(3191.0)),
        AmfKeyValue("videoCodecs", AmfValue(252.0)),
    ]));
    auto encoded = encodeAll([cmd, txId, cmdObj]);
    auto decoded = decodeAll(encoded);
    assert(decoded.length == 3);
    assert(decoded[0] == cmd);
    assert(decoded[1] == txId);
    assert(decoded[2] == cmdObj);
}

unittest {
    import std.exception : assertThrown;
    assertThrown!AmfDecodeException(decode([]));
}

unittest {
    import std.exception : assertThrown;
    assertThrown!AmfDecodeException(decode([0x00, 0x01, 0x02]));
}

unittest {
    import std.exception : assertThrown;
    assertThrown!AmfDecodeException(decode([0xff]));
}

unittest {
    // AmfObject.put and lookup
    auto obj = AmfObject();
    obj.put("key1", AmfValue(1.0));
    obj.put("key2", AmfValue("val"));
    assert(obj.length == 2);
    assert(("key1" in obj) !is null);
    assert((*("key1" in obj)) == AmfValue(1.0));
    assert(("missing" in obj) is null);

    // Update existing key
    obj.put("key1", AmfValue(2.0));
    assert(obj.length == 2);
    assert((*("key1" in obj)) == AmfValue(2.0));
}

unittest {
    // Number: special values
    auto posZero = AmfValue(0.0);
    assert(decode(encode(posZero)).value == posZero);

    auto negVal = AmfValue(-123.456);
    assert(decode(encode(negVal)).value == negVal);
}

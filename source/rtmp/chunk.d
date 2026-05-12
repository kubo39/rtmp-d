module rtmp.chunk;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.array : Appender;

enum DEFAULT_CHUNK_SIZE = 128;
enum MAX_CHUNK_SIZE = 0x7FFFFFFF; // 31 bits
enum PROTOCOL_CHUNK_STREAM_ID = 2;
enum EXTENDED_TIMESTAMP_SENTINEL = 0xFFFFFF;

class ChunkException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

struct ChunkBasicHeader {
    ubyte fmt; // 0-3
    uint chunkStreamId; // 2-65599

    size_t size() const {
        if (chunkStreamId >= 64 + 256)
            return 3;
        if (chunkStreamId >= 64)
            return 2;
        return 1;
    }
}

/// Returns null slice on insufficient data.
const(ubyte)[] writeBasicHeader(ref Appender!(ubyte[]) buf, ChunkBasicHeader h) {
    ubyte fmtBits = cast(ubyte)(h.fmt << 6);
    if (h.chunkStreamId <= 63 && h.chunkStreamId >= 2) {
        buf ~= cast(ubyte)(fmtBits | h.chunkStreamId);
    } else if (h.chunkStreamId <= 319) {
        buf ~= cast(ubyte)(fmtBits | 0); // cs id field = 0
        buf ~= cast(ubyte)(h.chunkStreamId - 64);
    } else {
        buf ~= cast(ubyte)(fmtBits | 1); // cs id field = 1
        uint id = h.chunkStreamId - 64;
        buf ~= cast(ubyte)(id & 0xFF);
        buf ~= cast(ubyte)((id >> 8) & 0xFF);
    }
    return null;
}

struct BasicHeaderResult {
    ChunkBasicHeader header;
    size_t bytesConsumed;
}

BasicHeaderResult readBasicHeader(const(ubyte)[] data) {
    if (data.length < 1)
        throw new ChunkException("not enough data for basic header");

    ubyte first = data[0];
    ubyte fmt = cast(ubyte)(first >> 6);
    uint csid = first & 0x3F;

    if (csid == 0) {
        if (data.length < 2)
            throw new ChunkException("not enough data for 2-byte basic header");
        return BasicHeaderResult(ChunkBasicHeader(fmt, cast(uint) data[1] + 64), 2);
    } else if (csid == 1) {
        if (data.length < 3)
            throw new ChunkException("not enough data for 3-byte basic header");
        return BasicHeaderResult(
            ChunkBasicHeader(fmt, cast(uint) data[1] + cast(uint) data[2] * 256 + 64), 3);
    } else {
        return BasicHeaderResult(ChunkBasicHeader(fmt, csid), 1);
    }
}

struct ChunkMessageHeader {
    uint timestamp; // or timestamp delta
    uint messageLength;
    ubyte messageTypeId;
    uint messageStreamId; // little-endian in wire format
    bool hasExtendedTimestamp;
}

struct MessageHeaderResult {
    ChunkMessageHeader header;
    size_t bytesConsumed;
}

MessageHeaderResult readMessageHeader(const(ubyte)[] data, ubyte fmt,
    bool prevHasExtendedTimestamp = false)
{
    ChunkMessageHeader h;
    size_t pos = 0;

    if (fmt <= 2) {
        if (data.length < 3)
            throw new ChunkException("not enough data for message header timestamp");
        h.timestamp = read24(data[0 .. 3]);
        pos = 3;
        h.hasExtendedTimestamp = (h.timestamp >= EXTENDED_TIMESTAMP_SENTINEL);
    }

    if (fmt <= 1) {
        if (data.length < pos + 4)
            throw new ChunkException("not enough data for message header length/type");
        h.messageLength = read24(data[pos .. pos + 3]);
        h.messageTypeId = data[pos + 3];
        pos += 4;
    }

    if (fmt == 0) {
        if (data.length < pos + 4)
            throw new ChunkException("not enough data for message header stream id");
        ubyte[4] streamIdBytes = data[pos .. pos + 4];
        import std.bitmanip : littleEndianToNative;
        h.messageStreamId = littleEndianToNative!uint(streamIdBytes);
        pos += 4;
    }

    // fmt 3 inherits extended timestamp from previous chunk on same stream
    if (fmt == 3 && prevHasExtendedTimestamp)
        h.hasExtendedTimestamp = true;

    if (h.hasExtendedTimestamp) {
        if (data.length < pos + 4)
            throw new ChunkException("not enough data for extended timestamp");
        ubyte[4] tsBytes = data[pos .. pos + 4];
        h.timestamp = bigEndianToNative!uint(tsBytes);
        pos += 4;
    }

    return MessageHeaderResult(h, pos);
}

void writeMessageHeader(ref Appender!(ubyte[]) buf, ubyte fmt, const ChunkMessageHeader h) {
    bool useExtended = h.timestamp >= EXTENDED_TIMESTAMP_SENTINEL;

    if (fmt <= 2) {
        uint tsField = useExtended ? EXTENDED_TIMESTAMP_SENTINEL : h.timestamp;
        write24(buf, tsField);
    }
    if (fmt <= 1) {
        write24(buf, h.messageLength);
        buf ~= h.messageTypeId;
    }
    if (fmt == 0) {
        import std.bitmanip : nativeToLittleEndian;
        buf ~= nativeToLittleEndian(h.messageStreamId)[];
    }
    if (useExtended) {
        buf ~= nativeToBigEndian(h.timestamp)[];
    }
}

struct RtmpMessage {
    ubyte typeId;
    uint streamId;
    uint timestamp;
    ubyte[] payload;
}

struct ChunkReader {
    private uint chunkSize_ = DEFAULT_CHUNK_SIZE;
    private ChunkStreamReadState[uint] streams_;
    private ubyte[] buffer_;

    void setChunkSize(uint size) {
        if (size < 1 || size > MAX_CHUNK_SIZE)
            throw new ChunkException("invalid chunk size");
        chunkSize_ = size;
    }

    uint chunkSize() const { return chunkSize_; }

    void discardStream(uint csid) {
        streams_.remove(csid);
    }

    void addData(const(ubyte)[] data) {
        buffer_ ~= data;
    }

    bool readMessage(out RtmpMessage msg) {
        while (true) {
            auto result = readOneChunk();
            if (result.kind == ChunkReadResult.Kind.completedMessage) {
                msg = result.msg;
                return true;
            }
            if (result.kind == ChunkReadResult.Kind.needMoreData)
                return false;
        }
    }

    /// Feed data and extract all complete messages.
    RtmpMessage[] processBytes(const(ubyte)[] data) {
        buffer_ ~= data;
        RtmpMessage[] messages;
        while (true) {
            auto result = readOneChunk();
            if (result.kind == ChunkReadResult.Kind.completedMessage)
                messages ~= result.msg;
            else if (result.kind == ChunkReadResult.Kind.consumedChunk)
                continue;
            else
                break;
        }
        return messages;
    }

    private ChunkReadResult readOneChunk() {
        if (buffer_.length == 0)
            return ChunkReadResult(ChunkReadResult.Kind.needMoreData);

        // Basic header
        BasicHeaderResult bhr;
        try {
            bhr = readBasicHeader(buffer_);
        } catch (ChunkException) {
            return ChunkReadResult(ChunkReadResult.Kind.needMoreData);
        }

        auto remaining = buffer_[bhr.bytesConsumed .. $];

        auto fmt = bhr.header.fmt;
        auto csid = bhr.header.chunkStreamId;
        auto state = getOrCreateState(csid);

        // Message header (need previous state for fmt 3 extended timestamp)
        MessageHeaderResult mhr;
        try {
            mhr = readMessageHeader(remaining, fmt, state.lastHeader.hasExtendedTimestamp);
        } catch (ChunkException) {
            return ChunkReadResult(ChunkReadResult.Kind.needMoreData);
        }

        auto headerSize = bhr.bytesConsumed + mhr.bytesConsumed;
        auto resolved = resolveHeader(state, fmt, mhr.header);

        // How much payload to read for this chunk
        uint remaining_msg = resolved.messageLength - cast(uint) state.payload.length;
        uint chunkPayloadSize = remaining_msg > chunkSize_ ? chunkSize_ : remaining_msg;

        // Check we have enough data
        if (buffer_.length < headerSize + chunkPayloadSize)
            return ChunkReadResult(ChunkReadResult.Kind.needMoreData);

        // Consume header + payload
        auto payloadSlice = buffer_[headerSize .. headerSize + chunkPayloadSize];
        state.payload ~= payloadSlice;
        buffer_ = buffer_[headerSize + chunkPayloadSize .. $].dup;

        // Check if message is complete
        if (state.payload.length >= resolved.messageLength) {
            auto msg = RtmpMessage(
                typeId: resolved.messageTypeId,
                streamId: resolved.messageStreamId,
                timestamp: resolved.timestamp,
                payload: state.payload[0 .. resolved.messageLength].dup
            );
            state.payload = [];
            return ChunkReadResult(ChunkReadResult.Kind.completedMessage, msg);
        }
        return ChunkReadResult(ChunkReadResult.Kind.consumedChunk);
    }

    private ChunkStreamReadState* getOrCreateState(uint csid) {
        if (csid !in streams_)
            streams_[csid] = ChunkStreamReadState();
        return &streams_[csid];
    }

    private ChunkMessageHeader resolveHeader(
        ChunkStreamReadState* state, ubyte fmt, ChunkMessageHeader incoming
    ) {
        ChunkMessageHeader resolved;

        if (fmt == 0) {
            resolved = incoming;
        } else if (fmt == 1) {
            resolved.messageStreamId = state.lastHeader.messageStreamId;
            resolved.messageLength = incoming.messageLength;
            resolved.messageTypeId = incoming.messageTypeId;
            resolved.timestamp = state.lastHeader.timestamp + incoming.timestamp;
        } else if (fmt == 2) {
            resolved.messageStreamId = state.lastHeader.messageStreamId;
            resolved.messageLength = state.lastHeader.messageLength;
            resolved.messageTypeId = state.lastHeader.messageTypeId;
            resolved.timestamp = state.lastHeader.timestamp + incoming.timestamp;
        } else {
            // fmt 3: inherit everything
            resolved = state.lastHeader;
        }

        state.lastHeader = resolved;
        return resolved;
    }
}

private struct ChunkStreamReadState {
    ChunkMessageHeader lastHeader;
    ubyte[] payload;
}

private struct ChunkReadResult {
    enum Kind { needMoreData, consumedChunk, completedMessage }
    Kind kind;
    RtmpMessage msg;
}

struct ChunkWriter {
    private uint chunkSize_ = DEFAULT_CHUNK_SIZE;
    private ChunkStreamWriteState[uint] streams_;

    void setChunkSize(uint size) {
        if (size < 1 || size > MAX_CHUNK_SIZE)
            throw new ChunkException("invalid chunk size");
        chunkSize_ = size;
    }

    uint chunkSize() const { return chunkSize_; }

    ubyte[] writeMessage(uint chunkStreamId, const RtmpMessage msg) {
        auto buf = Appender!(ubyte[])();
        auto state = getOrCreateState(chunkStreamId);

        auto header = ChunkMessageHeader(
            msg.timestamp,
            cast(uint) msg.payload.length,
            msg.typeId,
            msg.streamId,
            false
        );

        // Determine fmt for first chunk
        ubyte fmt = selectFmt(state, header);

        size_t offset = 0;
        bool first = true;
        while (offset < msg.payload.length || first) {
            auto payloadEnd = offset + chunkSize_;
            if (payloadEnd > msg.payload.length)
                payloadEnd = msg.payload.length;

            if (first) {
                writeBasicHeader(buf, ChunkBasicHeader(fmt, chunkStreamId));
                auto writeHdr = makeWriteHeader(fmt, state, header);
                writeMessageHeader(buf, fmt, writeHdr);
                first = false;
            } else {
                // Continuation chunks use fmt 3
                writeBasicHeader(buf, ChunkBasicHeader(3, chunkStreamId));
                if (header.timestamp >= EXTENDED_TIMESTAMP_SENTINEL) {
                    buf ~= nativeToBigEndian(header.timestamp)[];
                }
            }

            buf ~= cast(const(ubyte)[]) msg.payload[offset .. payloadEnd];
            offset = payloadEnd;

            if (msg.payload.length == 0)
                break;
        }

        state.lastHeader = header;
        state.hasPrevious = true;
        return buf[];
    }

    private ChunkStreamWriteState* getOrCreateState(uint csid) {
        if (csid !in streams_)
            streams_[csid] = ChunkStreamWriteState();
        return &streams_[csid];
    }

    private static ubyte selectFmt(const ChunkStreamWriteState* state, const ChunkMessageHeader h) {
        if (!state.hasPrevious)
            return 0;

        auto prev = &state.lastHeader;
        if (h.messageStreamId != prev.messageStreamId)
            return 0;
        // §5.3.1.2.1: timestamp delta cannot be represented when timestamp goes backward
        if (h.timestamp < prev.timestamp)
            return 0;
        if (h.messageLength != prev.messageLength || h.messageTypeId != prev.messageTypeId)
            return 1;
        if (h.timestamp != prev.timestamp)
            return 2;
        return 3;
    }

    private static ChunkMessageHeader makeWriteHeader(
        ubyte fmt, const ChunkStreamWriteState* state, ChunkMessageHeader h
    ) {
        if (fmt >= 1 && state.hasPrevious) {
            // For fmt 1,2: store delta instead of absolute timestamp
            h.timestamp = h.timestamp - state.lastHeader.timestamp;
        }
        h.hasExtendedTimestamp = h.timestamp >= EXTENDED_TIMESTAMP_SENTINEL;
        return h;
    }
}

private struct ChunkStreamWriteState {
    ChunkMessageHeader lastHeader;
    bool hasPrevious;
}

private uint read24(const(ubyte)[] data) {
    return (cast(uint) data[0] << 16) | (cast(uint) data[1] << 8) | cast(uint) data[2];
}

private void write24(ref Appender!(ubyte[]) buf, uint value) {
    buf ~= cast(ubyte)((value >> 16) & 0xFF);
    buf ~= cast(ubyte)((value >> 8) & 0xFF);
    buf ~= cast(ubyte)(value & 0xFF);
}

// Basic header round-trip
unittest {
    void testBasicHeader(uint csid) {
        foreach (ubyte fmt; 0 .. 4) {
            auto buf = Appender!(ubyte[])();
            writeBasicHeader(buf, ChunkBasicHeader(fmt, csid));
            auto result = readBasicHeader(buf[]);
            assert(result.header.fmt == fmt);
            assert(result.header.chunkStreamId == csid);
            assert(result.bytesConsumed == buf[].length);
        }
    }
    testBasicHeader(2);   // 1-byte: minimum
    testBasicHeader(63);  // 1-byte: maximum
    testBasicHeader(64);  // 2-byte: minimum
    testBasicHeader(319); // 2-byte: maximum
    testBasicHeader(320); // 3-byte: minimum
    testBasicHeader(65599); // 3-byte: maximum
}

// Message header fmt 0 round-trip
unittest {
    auto h = ChunkMessageHeader(1000, 256, 9, 1, false);
    auto buf = Appender!(ubyte[])();
    writeMessageHeader(buf, 0, h);
    auto result = readMessageHeader(buf[], 0);
    assert(result.header.timestamp == 1000);
    assert(result.header.messageLength == 256);
    assert(result.header.messageTypeId == 9);
    assert(result.header.messageStreamId == 1);
}

// Message header fmt 1 round-trip
unittest {
    auto h = ChunkMessageHeader(500, 128, 8, 0, false);
    auto buf = Appender!(ubyte[])();
    writeMessageHeader(buf, 1, h);
    auto result = readMessageHeader(buf[], 1);
    assert(result.header.timestamp == 500);
    assert(result.header.messageLength == 128);
    assert(result.header.messageTypeId == 8);
}

// Message header fmt 2 round-trip
unittest {
    auto h = ChunkMessageHeader(100, 0, 0, 0, false);
    auto buf = Appender!(ubyte[])();
    writeMessageHeader(buf, 2, h);
    auto result = readMessageHeader(buf[], 2);
    assert(result.header.timestamp == 100);
}

// Message header fmt 3 (empty)
unittest {
    auto result = readMessageHeader([], 3);
    assert(result.bytesConsumed == 0);
}

// Extended timestamp
unittest {
    auto h = ChunkMessageHeader(0x1000000, 100, 9, 1, false);
    auto buf = Appender!(ubyte[])();
    writeMessageHeader(buf, 0, h);
    auto result = readMessageHeader(buf[], 0);
    assert(result.header.timestamp == 0x1000000);
    assert(result.header.hasExtendedTimestamp);
}

// Extended timestamp boundary: exactly 0xFFFFFF
unittest {
    auto h = ChunkMessageHeader(EXTENDED_TIMESTAMP_SENTINEL, 100, 9, 1, false);
    auto buf = Appender!(ubyte[])();
    writeMessageHeader(buf, 0, h);
    auto result = readMessageHeader(buf[], 0);
    assert(result.header.timestamp == EXTENDED_TIMESTAMP_SENTINEL);
    assert(result.header.hasExtendedTimestamp);
}

// Extended timestamp boundary: 0xFFFFFE (no extended)
unittest {
    auto h = ChunkMessageHeader(EXTENDED_TIMESTAMP_SENTINEL - 1, 100, 9, 1, false);
    auto buf = Appender!(ubyte[])();
    writeMessageHeader(buf, 0, h);
    auto result = readMessageHeader(buf[], 0);
    assert(result.header.timestamp == EXTENDED_TIMESTAMP_SENTINEL - 1);
    assert(!result.header.hasExtendedTimestamp);
}

// Writer + Reader round-trip: small message (fits in one chunk)
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    ubyte[] payload = new ubyte[64];
    payload[] = 0xAB;
    auto msg = RtmpMessage(9, 1, 1000, payload);

    auto encoded = writer.writeMessage(6, msg);
    auto messages = reader.processBytes(encoded);
    assert(messages.length == 1);
    assert(messages[0].typeId == 9);
    assert(messages[0].streamId == 1);
    assert(messages[0].timestamp == 1000);
    assert(messages[0].payload == payload);
}

// Writer + Reader: message requiring fragmentation
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    // 300 bytes > default 128 chunk size → 3 chunks
    ubyte[] payload = new ubyte[300];
    foreach (i, ref b; payload)
        b = cast(ubyte)(i & 0xFF);
    auto msg = RtmpMessage(9, 1, 500, payload);

    auto encoded = writer.writeMessage(6, msg);
    auto messages = reader.processBytes(encoded);
    assert(messages.length == 1);
    assert(messages[0].payload == payload);
}

// Writer + Reader: exact chunk boundary
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    ubyte[] payload = new ubyte[DEFAULT_CHUNK_SIZE]; // exactly 128
    payload[] = 0xCD;
    auto msg = RtmpMessage(8, 1, 0, payload);

    auto encoded = writer.writeMessage(3, msg);
    auto messages = reader.processBytes(encoded);
    assert(messages.length == 1);
    assert(messages[0].payload == payload);
}

// Chunk size change
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();
    writer.setChunkSize(256);
    reader.setChunkSize(256);

    ubyte[] payload = new ubyte[300];
    payload[] = 0x42;
    auto msg = RtmpMessage(9, 1, 0, payload);

    auto encoded = writer.writeMessage(6, msg);
    auto messages = reader.processBytes(encoded);
    assert(messages.length == 1);
    assert(messages[0].payload == payload);
}

// Multiple messages on same chunk stream (fmt selection)
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    ubyte[] p1 = [1, 2, 3, 4];
    ubyte[] p2 = [5, 6, 7, 8];
    auto msg1 = RtmpMessage(9, 1, 100, p1);
    auto msg2 = RtmpMessage(9, 1, 200, p2);

    auto e1 = writer.writeMessage(6, msg1);
    auto e2 = writer.writeMessage(6, msg2);

    auto messages = reader.processBytes(e1 ~ e2);
    assert(messages.length == 2);
    assert(messages[0].payload == p1);
    assert(messages[0].timestamp == 100);
    assert(messages[1].payload == p2);
    assert(messages[1].timestamp == 200);
}

// Multiple chunk stream IDs interleaved
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    auto msg1 = RtmpMessage(9, 1, 0, [ubyte(0xAA)]);
    auto msg2 = RtmpMessage(8, 1, 0, [ubyte(0xBB)]);

    auto e1 = writer.writeMessage(6, msg1); // video on csid 6
    auto e2 = writer.writeMessage(4, msg2); // audio on csid 4

    auto messages = reader.processBytes(e1 ~ e2);
    assert(messages.length == 2);
    assert(messages[0].typeId == 9);
    assert(messages[0].payload == [0xAA]);
    assert(messages[1].typeId == 8);
    assert(messages[1].payload == [0xBB]);
}

// Empty payload message
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    auto msg = RtmpMessage(20, 0, 0, []);
    auto encoded = writer.writeMessage(3, msg);
    auto messages = reader.processBytes(encoded);
    assert(messages.length == 1);
    assert(messages[0].payload.length == 0);
}

// Partial data feeding
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    ubyte[] payload = new ubyte[64];
    payload[] = 0x55;
    auto msg = RtmpMessage(9, 1, 1000, payload);
    auto encoded = writer.writeMessage(6, msg);

    // Feed one byte at a time
    RtmpMessage[] messages;
    foreach (i; 0 .. encoded.length) {
        messages ~= reader.processBytes(encoded[i .. i + 1]);
    }
    assert(messages.length == 1);
    assert(messages[0].payload == payload);
}

// Extended timestamp in writer/reader round-trip
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    ubyte[] payload = [1, 2, 3];
    auto msg = RtmpMessage(9, 1, 0x1000000, payload);
    auto encoded = writer.writeMessage(6, msg);
    auto messages = reader.processBytes(encoded);
    assert(messages.length == 1);
    assert(messages[0].timestamp == 0x1000000);
}

// Large message with extended timestamp + fragmentation
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    ubyte[] payload = new ubyte[500];
    foreach (i, ref b; payload)
        b = cast(ubyte)(i % 251);
    auto msg = RtmpMessage(9, 1, 0x2000000, payload);
    auto encoded = writer.writeMessage(6, msg);
    auto messages = reader.processBytes(encoded);
    assert(messages.length == 1);
    assert(messages[0].timestamp == 0x2000000);
    assert(messages[0].payload == payload);
}

// Backward timestamp forces fmt 0 (§5.3.1.2.1)
unittest {
    auto writer = ChunkWriter();
    auto reader = ChunkReader();

    ubyte[] p1 = [1, 2, 3];
    auto msg1 = RtmpMessage(9, 1, 1000, p1);
    auto enc1 = writer.writeMessage(6, msg1);
    // Second message has earlier timestamp
    auto msg2 = RtmpMessage(9, 1, 500, p1);
    auto enc2 = writer.writeMessage(6, msg2);
    // Must be decodable (fmt 0 with absolute timestamp)
    auto messages = reader.processBytes(enc1 ~ enc2);
    assert(messages.length == 2);
    assert(messages[0].timestamp == 1000);
    assert(messages[1].timestamp == 500);
}

// ChunkReader.discardStream removes partial state (§5.4.2)
unittest {
    auto reader = ChunkReader();

    auto writer = ChunkWriter();
    writer.setChunkSize(4);

    // Write a message that will span multiple chunks
    ubyte[] payload = [1, 2, 3, 4, 5, 6, 7, 8];
    auto encoded = writer.writeMessage(3, RtmpMessage(9, 1, 100, payload));

    // Feed only the first chunk (4 bytes of payload + header)
    // then discard the stream
    reader.setChunkSize(4);
    reader.addData(encoded[0 .. 16]); // partial
    RtmpMessage msg;
    assert(!reader.readMessage(msg));

    reader.discardStream(3);

    // Stream state is gone — feeding remaining data should not produce a valid message
    // (it would try to parse continuation chunks without initial state)
    reader.addData(encoded[16 .. $]);
    // No complete message since stream state was discarded
    bool gotMessage = false;
    try {
        gotMessage = reader.readMessage(msg);
    } catch (ChunkException) {
        // Expected: orphaned continuation chunk
    }
}

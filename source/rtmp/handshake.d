/**
 * RTMP handshake (client and server).
 *
 * Implements the simple RTMP 1.0 handshake (§5.2) with the three-packet
 * exchange: C0/C1, S0/S1/S2, C2.
 *
 * License:   $(HTTP boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
 * Authors:   Hiroki Noda
 * See_Also:  $(LINK2 https://veovera.github.io/enhanced-rtmp/docs/legacy/rtmp-v1-0-spec.pdf, RTMP 1.0 Specification)
 */
module rtmp.handshake;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.conv : to;

enum RTMP_VERSION = 3;
enum HANDSHAKE_SIZE = 1536;
enum RANDOM_SIZE = HANDSHAKE_SIZE - 8; // 1528 bytes

class HandshakeException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

struct HandshakeResult {
    enum Kind { needMoreData, sendData, done }

    Kind kind;
    const(ubyte)[] data;

    static HandshakeResult needMoreData() {
        return HandshakeResult(Kind.needMoreData);
    }

    static HandshakeResult sendData(const(ubyte)[] data) {
        return HandshakeResult(Kind.sendData, data);
    }

    static HandshakeResult done() {
        return HandshakeResult(Kind.done);
    }
}

// --- Server Handshake ---

struct ServerHandshake {
    private enum State { waitC0C1, waitC2, done }

    private State state_ = State.waitC0C1;
    private ubyte[] buffer_;
    private ubyte[HANDSHAKE_SIZE] s1Data_;
    private ubyte[HANDSHAKE_SIZE] c1Data_;
    private uint delegate() timeSource_;

    this(uint delegate() timeSource) {
        timeSource_ = timeSource;
    }

    static ServerHandshake create() {
        return ServerHandshake(null);
    }

    bool done() const { return state_ == State.done; }

    HandshakeResult processBytes(const(ubyte)[] data) {
        buffer_ ~= data;

        final switch (state_) {
            case State.waitC0C1:
                return processC0C1();
            case State.waitC2:
                return processC2();
            case State.done:
                return HandshakeResult.done();
        }
    }

    private HandshakeResult processC0C1() {
        enum needed = 1 + HANDSHAKE_SIZE; // C0 (1) + C1 (1536)
        if (buffer_.length < needed)
            return HandshakeResult.needMoreData();

        // C0: version check
        const version_ = buffer_[0];
        if (version_ != RTMP_VERSION)
            throw new HandshakeException(
                "unsupported RTMP version: " ~ version_.to!string);

        // C1: store for S2 echo
        c1Data_[] = buffer_[1 .. 1 + HANDSHAKE_SIZE];

        // Generate S0 + S1 + S2
        ubyte[] response;
        response.reserve(1 + HANDSHAKE_SIZE * 2);

        // S0
        response ~= RTMP_VERSION;

        // S1: time(4) + zero(4) + random(1528)
        const s1Time = currentTime();
        s1Data_[0 .. 4] = nativeToBigEndian(s1Time)[];
        s1Data_[4 .. 8] = [0, 0, 0, 0];
        generateRandom(s1Data_[8 .. HANDSHAKE_SIZE]);
        response ~= s1Data_[];

        // S2: echo of C1 with time2
        ubyte[HANDSHAKE_SIZE] s2;
        // time: copy C1's timestamp
        s2[0 .. 4] = c1Data_[0 .. 4];
        // time2: timestamp when C1 was read (§5.2.4)
        const c1ReadTime = currentTime();
        s2[4 .. 8] = nativeToBigEndian(c1ReadTime)[];
        // random echo: copy C1's random data
        s2[8 .. HANDSHAKE_SIZE] = c1Data_[8 .. HANDSHAKE_SIZE];
        response ~= s2[];

        // Consume processed bytes
        buffer_ = buffer_[needed .. $].dup;
        state_ = State.waitC2;
        return HandshakeResult.sendData(response);
    }

    private HandshakeResult processC2() {
        if (buffer_.length < HANDSHAKE_SIZE)
            return HandshakeResult.needMoreData();

        // Validate C2: random echo should match S1's random data
        const c2RandomEcho = buffer_[8 .. HANDSHAKE_SIZE];
        if (c2RandomEcho != s1Data_[8 .. HANDSHAKE_SIZE])
            throw new HandshakeException("C2 random echo mismatch");

        buffer_ = buffer_[HANDSHAKE_SIZE .. $].dup;
        state_ = State.done;
        return HandshakeResult.done();
    }

    const(ubyte)[] remainingBytes() const {
        return buffer_;
    }

    private uint currentTime() {
        if (timeSource_ !is null)
            return timeSource_();
        return 0;
    }
}

// --- Client Handshake ---

struct ClientHandshake {
    private enum State { sendC0C1, waitS0S1S2, done }

    private State state_ = State.sendC0C1;
    private ubyte[] buffer_;
    private ubyte[HANDSHAKE_SIZE] c1Data_;
    private uint delegate() timeSource_;

    this(uint delegate() timeSource) {
        timeSource_ = timeSource;
    }

    static ClientHandshake create() {
        return ClientHandshake(null);
    }

    bool done() const { return state_ == State.done; }

    ubyte[] generateC0C1() {
        ubyte[] packet;
        packet.reserve(1 + HANDSHAKE_SIZE);

        // C0
        packet ~= RTMP_VERSION;

        // C1: time(4) + zero(4) + random(1528)
        const clientTime = currentTime();
        c1Data_[0 .. 4] = nativeToBigEndian(clientTime)[];
        c1Data_[4 .. 8] = [0, 0, 0, 0];
        generateRandom(c1Data_[8 .. HANDSHAKE_SIZE]);
        packet ~= c1Data_[];

        state_ = State.waitS0S1S2;
        return packet;
    }

    /// Process received bytes from server. Returns C2 to send, or needMoreData.
    HandshakeResult processBytes(const(ubyte)[] data) {
        buffer_ ~= data;

        final switch (state_) {
            case State.sendC0C1:
                return HandshakeResult.needMoreData();
            case State.waitS0S1S2:
                return processS0S1S2();
            case State.done:
                return HandshakeResult.done();
        }
    }

    private HandshakeResult processS0S1S2() {
        enum needed = 1 + HANDSHAKE_SIZE * 2; // S0(1) + S1(1536) + S2(1536)
        if (buffer_.length < needed)
            return HandshakeResult.needMoreData();

        // S0: version check
        const version_ = buffer_[0];
        if (version_ != RTMP_VERSION)
            throw new HandshakeException(
                "unsupported RTMP version: " ~ version_.to!string);

        // S1: store for reference
        auto s1 = buffer_[1 .. 1 + HANDSHAKE_SIZE];

        // S2: validate random echo matches C1
        auto s2 = buffer_[1 + HANDSHAKE_SIZE .. 1 + HANDSHAKE_SIZE * 2];
        const s2RandomEcho = s2[8 .. HANDSHAKE_SIZE];
        if (s2RandomEcho != c1Data_[8 .. HANDSHAKE_SIZE])
            throw new HandshakeException("S2 random echo mismatch");

        // Generate C2: echo of S1
        ubyte[] c2;
        c2.length = HANDSHAKE_SIZE;
        // time: S1's timestamp
        c2[0 .. 4] = s1[0 .. 4];
        // time2: timestamp when S1 was read (§5.2.4)
        const clientTime = currentTime();
        c2[4 .. 8] = nativeToBigEndian(clientTime)[];
        // random echo: S1's random data
        c2[8 .. HANDSHAKE_SIZE] = s1[8 .. HANDSHAKE_SIZE];

        buffer_ = buffer_[needed .. $].dup;
        state_ = State.done;
        return HandshakeResult.sendData(c2);
    }

    const(ubyte)[] remainingBytes() const {
        return buffer_;
    }

    private uint currentTime() {
        if (timeSource_ !is null)
            return timeSource_();
        return 0;
    }
}

// --- Utilities ---

private void generateRandom(ubyte[] dest) {
    import std.random : Xorshift128, unpredictableSeed, uniform;
    auto rng = Xorshift128(unpredictableSeed);
    foreach (ref b; dest)
        b = uniform!ubyte(rng);
}

@("Full client-server handshake")
unittest {
    auto server = ServerHandshake.create();
    auto client = ClientHandshake.create();

    // Client generates C0+C1
    auto c0c1 = client.generateC0C1();
    assert(c0c1.length == 1 + HANDSHAKE_SIZE);
    assert(c0c1[0] == RTMP_VERSION);

    // Server processes C0+C1, returns S0+S1+S2
    auto serverResult = server.processBytes(c0c1);
    assert(serverResult.kind == HandshakeResult.Kind.sendData);
    assert(serverResult.data.length == 1 + HANDSHAKE_SIZE * 2);
    assert(!server.done);

    // Client processes S0+S1+S2, returns C2
    auto clientResult = client.processBytes(serverResult.data);
    assert(clientResult.kind == HandshakeResult.Kind.sendData);
    assert(clientResult.data.length == HANDSHAKE_SIZE);
    assert(client.done);

    // Server processes C2
    const serverFinal = server.processBytes(clientResult.data);
    assert(serverFinal.kind == HandshakeResult.Kind.done);
    assert(server.done);
}

@("Partial data: feed bytes one at a time to server")
unittest {
    auto server = ServerHandshake.create();

    // Build C0+C1
    ubyte[] c0c1;
    c0c1 ~= RTMP_VERSION;
    ubyte[HANDSHAKE_SIZE] c1;
    c1[0 .. 4] = nativeToBigEndian(uint(0))[];
    c1[4 .. 8] = [0, 0, 0, 0];
    c1[8 .. $] = 0xAB;
    c0c1 ~= c1[];

    // Feed one byte at a time until we get a response
    HandshakeResult result;
    size_t i;
    for (i = 0; i < c0c1.length; i++) {
        result = server.processBytes(c0c1[i .. i + 1]);
        if (result.kind != HandshakeResult.Kind.needMoreData)
            break;
    }
    assert(i + 1 == c0c1.length); // response on last byte
    assert(result.kind == HandshakeResult.Kind.sendData);
}

@("Server rejects wrong C0 version")
unittest {
    import std.exception : assertThrown;
    auto server = ServerHandshake.create();
    ubyte[] badC0C1;
    badC0C1.length = 1 + HANDSHAKE_SIZE;
    badC0C1[0] = 4; // wrong version

    assertThrown!HandshakeException(server.processBytes(badC0C1));
}

@("Client rejects wrong S0 version")
unittest {
    import std.exception : assertThrown;
    auto client = ClientHandshake.create();
    client.generateC0C1();

    ubyte[] badS0S1S2;
    badS0S1S2.length = 1 + HANDSHAKE_SIZE * 2;
    badS0S1S2[0] = 5; // wrong version

    assertThrown!HandshakeException(client.processBytes(badS0S1S2));
}

@("Server rejects C2 with wrong random echo")
unittest {
    import std.exception : assertThrown;
    auto server = ServerHandshake.create();

    ubyte[] c0c1;
    c0c1 ~= RTMP_VERSION;
    ubyte[HANDSHAKE_SIZE] c1;
    c1[] = 0x42;
    c0c1 ~= c1[];

    const result = server.processBytes(c0c1);
    assert(result.kind == HandshakeResult.Kind.sendData);

    ubyte[HANDSHAKE_SIZE] badC2;
    badC2[] = 0xFF; // does not match S1

    assertThrown!HandshakeException(server.processBytes(badC2[]));
}

@("Client rejects S2 with wrong random echo")
unittest {
    import std.exception : assertThrown;
    auto client = ClientHandshake.create();
    client.generateC0C1();

    ubyte[] s0s1s2;
    s0s1s2 ~= RTMP_VERSION; // S0
    ubyte[HANDSHAKE_SIZE] s1;
    s1[] = 0x42;
    s0s1s2 ~= s1[]; // S1
    ubyte[HANDSHAKE_SIZE] s2;
    s2[] = 0xFF; // wrong random echo
    s0s1s2 ~= s2[]; // S2

    assertThrown!HandshakeException(client.processBytes(s0s1s2));
}

@("Remaining bytes are preserved after handshake")
unittest {
    auto server = ServerHandshake.create();
    auto client = ClientHandshake.create();

    auto c0c1 = client.generateC0C1();
    auto serverResult = server.processBytes(c0c1);
    const clientResult = client.processBytes(serverResult.data);

    // Append extra bytes after C2
    ubyte[] c2WithExtra = clientResult.data.dup ~ [ubyte(0xDE), ubyte(0xAD)];
    server.processBytes(c2WithExtra);
    assert(server.done);
    assert(server.remainingBytes == [0xDE, 0xAD]);
}

@("Time source delegate is called")
unittest {
    uint callCount = 0;
    auto server = ServerHandshake(() { callCount++; return uint(12_345); });
    auto client = ClientHandshake(() { return uint(67_890); });

    auto c0c1 = client.generateC0C1();
    server.processBytes(c0c1);
    assert(callCount > 0);
}

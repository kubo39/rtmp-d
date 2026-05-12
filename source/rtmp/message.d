module rtmp.message;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.array : Appender;
import rtmp.amf;
import rtmp.chunk : RtmpMessage;

enum COMMAND_CSID = 3;
enum AUDIO_CSID = 4;
enum VIDEO_CSID = 6;
enum STREAM_COMMAND_CSID = 8;

enum MessageTypeId : ubyte {
    setChunkSize = 1,
    abort = 2,
    acknowledgement = 3,
    userControl = 4,
    windowAckSize = 5,
    setPeerBandwidth = 6,
    audio = 8,
    video = 9,
    dataAmf0 = 18,
    commandAmf0 = 20,
    aggregate = 22,
}

// --- Protocol Control Messages ---

enum BandwidthLimitType : ubyte {
    hard = 0,
    soft = 1,
    dynamic = 2,
}

struct SetChunkSize {
    uint chunkSize;
}

struct AbortMessage {
    uint chunkStreamId;
}

struct Acknowledgement {
    uint sequenceNumber;
}

struct WindowAckSize {
    uint size;
}

struct SetPeerBandwidth {
    uint windowSize;
    BandwidthLimitType limitType;
}

class MessageException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// Protocol control message encoding

ubyte[] encodeSetChunkSize(uint chunkSize) {
    return nativeToBigEndian(chunkSize & 0x7FFFFFFF)[].dup;
}

SetChunkSize decodeSetChunkSize(const(ubyte)[] payload) {
    if (payload.length < 4)
        throw new MessageException("SetChunkSize payload too short");
    ubyte[4] bytes = payload[0 .. 4];
    uint val = bigEndianToNative!uint(bytes) & 0x7FFFFFFF;
    return SetChunkSize(val);
}

ubyte[] encodeAbort(uint chunkStreamId) {
    return nativeToBigEndian(chunkStreamId)[].dup;
}

AbortMessage decodeAbort(const(ubyte)[] payload) {
    if (payload.length < 4)
        throw new MessageException("Abort payload too short");
    ubyte[4] bytes = payload[0 .. 4];
    return AbortMessage(bigEndianToNative!uint(bytes));
}

ubyte[] encodeAcknowledgement(uint seqNum) {
    return nativeToBigEndian(seqNum)[].dup;
}

Acknowledgement decodeAcknowledgement(const(ubyte)[] payload) {
    if (payload.length < 4)
        throw new MessageException("Acknowledgement payload too short");
    ubyte[4] bytes = payload[0 .. 4];
    return Acknowledgement(bigEndianToNative!uint(bytes));
}

ubyte[] encodeWindowAckSize(uint size) {
    return nativeToBigEndian(size)[].dup;
}

WindowAckSize decodeWindowAckSize(const(ubyte)[] payload) {
    if (payload.length < 4)
        throw new MessageException("WindowAckSize payload too short");
    ubyte[4] bytes = payload[0 .. 4];
    return WindowAckSize(bigEndianToNative!uint(bytes));
}

ubyte[] encodeSetPeerBandwidth(uint windowSize, BandwidthLimitType limitType) {
    ubyte[5] result;
    result[0 .. 4] = nativeToBigEndian(windowSize);
    result[4] = cast(ubyte) limitType;
    return result[].dup;
}

SetPeerBandwidth decodeSetPeerBandwidth(const(ubyte)[] payload) {
    if (payload.length < 5)
        throw new MessageException("SetPeerBandwidth payload too short");
    ubyte[4] bytes = payload[0 .. 4];
    return SetPeerBandwidth(
        bigEndianToNative!uint(bytes),
        cast(BandwidthLimitType) payload[4]
    );
}

// --- User Control Events ---

enum UserControlEventType : ushort {
    streamBegin = 0,
    streamEOF = 1,
    streamDry = 2,
    setBufferLength = 3,
    streamIsRecorded = 4,
    pingRequest = 6,
    pingResponse = 7,
}

struct UserControlEvent {
    UserControlEventType eventType;
    uint streamId;     // for stream events
    uint bufferLength; // for SetBufferLength
    uint timestamp;    // for Ping
}

ubyte[] encodeUserControl(UserControlEvent ev) {
    auto buf = Appender!(ubyte[])();
    buf ~= nativeToBigEndian(cast(ushort) ev.eventType)[];
    final switch (ev.eventType) {
        case UserControlEventType.streamBegin:
        case UserControlEventType.streamEOF:
        case UserControlEventType.streamDry:
        case UserControlEventType.streamIsRecorded:
            buf ~= nativeToBigEndian(ev.streamId)[];
            break;
        case UserControlEventType.setBufferLength:
            buf ~= nativeToBigEndian(ev.streamId)[];
            buf ~= nativeToBigEndian(ev.bufferLength)[];
            break;
        case UserControlEventType.pingRequest:
        case UserControlEventType.pingResponse:
            buf ~= nativeToBigEndian(ev.timestamp)[];
            break;
    }
    return buf[];
}

UserControlEvent decodeUserControl(const(ubyte)[] payload) {
    if (payload.length < 6)
        throw new MessageException("UserControl payload too short");
    ubyte[2] typeBytes = payload[0 .. 2];
    auto eventType = cast(UserControlEventType) bigEndianToNative!ushort(typeBytes);
    ubyte[4] data1 = payload[2 .. 6];
    uint val1 = bigEndianToNative!uint(data1);

    auto ev = UserControlEvent(eventType: eventType);

    switch (eventType) {
        case UserControlEventType.streamBegin:
        case UserControlEventType.streamEOF:
        case UserControlEventType.streamDry:
        case UserControlEventType.streamIsRecorded:
            ev.streamId = val1;
            break;
        case UserControlEventType.setBufferLength:
            ev.streamId = val1;
            if (payload.length < 10)
                throw new MessageException("SetBufferLength payload too short");
            ubyte[4] data2 = payload[6 .. 10];
            ev.bufferLength = bigEndianToNative!uint(data2);
            break;
        case UserControlEventType.pingRequest:
        case UserControlEventType.pingResponse:
            ev.timestamp = val1;
            break;
        default:
            break;
    }
    return ev;
}

// --- Command Messages (AMF0, type 20) ---

struct CommandMessage {
    string commandName;
    double transactionId;
    AmfValue commandObject; // usually Object or Null
    AmfValue[] args;
}

CommandMessage decodeCommand(const(ubyte)[] payload) {
    auto values = decodeAll(payload);
    if (values.length < 3)
        throw new MessageException("command message requires at least 3 AMF values");

    if (values[0].kind != AmfValue.Kind.string_)
        throw new MessageException("command name must be a string");
    if (values[1].kind != AmfValue.Kind.number)
        throw new MessageException("transaction ID must be a number");

    return CommandMessage(
        commandName: values[0].str,
        transactionId: values[1].number,
        commandObject: values[2],
        args: values.length > 3 ? values[3 .. $] : null,
    );
}

ubyte[] encodeCommand(CommandMessage cmd) {
    AmfValue[] buf;
    buf.reserve(3 + cmd.args.length);
    buf ~= AmfValue(cmd.commandName);
    buf ~= AmfValue(cmd.transactionId);
    buf ~= cmd.commandObject;
    foreach (ref a; cmd.args)
        buf ~= a;
    return encodeAll(buf);
}

// --- Typed Command Structs ---

struct ConnectCommand {
    double transactionId = 1.0;
    AmfObject commandObject;
}

ConnectCommand decodeConnect(CommandMessage cmd) {
    if (cmd.commandObject.kind != AmfValue.Kind.object)
        throw new MessageException("connect command object must be an Object");
    return ConnectCommand(transactionId: cmd.transactionId, commandObject: cmd.commandObject.object);
}

struct CreateStreamCommand {
    double transactionId;
}

CreateStreamCommand decodeCreateStream(CommandMessage cmd) {
    return CreateStreamCommand(transactionId: cmd.transactionId);
}

enum PublishingType {
    live,
    record,
    append,
}

struct PublishCommand {
    double transactionId;
    string publishingName;
    PublishingType publishingType = PublishingType.live;
}

PublishCommand decodePublish(CommandMessage cmd) {
    auto pub = PublishCommand(transactionId: cmd.transactionId);
    if (cmd.args.length >= 1 && cmd.args[0].kind == AmfValue.Kind.string_)
        pub.publishingName = cmd.args[0].str;
    if (cmd.args.length >= 2 && cmd.args[1].kind == AmfValue.Kind.string_) {
        switch (cmd.args[1].str) {
            case "record": pub.publishingType = PublishingType.record; break;
            case "append": pub.publishingType = PublishingType.append; break;
            default: pub.publishingType = PublishingType.live; break;
        }
    }
    return pub;
}

struct PlayCommand {
    double transactionId;
    string streamName;
    double start = -2.0;    // -2 = live or recorded, -1 = live only
    double duration = -1.0;  // -1 = live or until end
    bool reset = true;
}

PlayCommand decodePlay(CommandMessage cmd) {
    auto play = PlayCommand(transactionId: cmd.transactionId);
    if (cmd.args.length >= 1 && cmd.args[0].kind == AmfValue.Kind.string_)
        play.streamName = cmd.args[0].str;
    if (cmd.args.length >= 2 && cmd.args[1].kind == AmfValue.Kind.number)
        play.start = cmd.args[1].number;
    if (cmd.args.length >= 3 && cmd.args[2].kind == AmfValue.Kind.number)
        play.duration = cmd.args[2].number;
    if (cmd.args.length >= 4 && cmd.args[3].kind == AmfValue.Kind.boolean)
        play.reset = cmd.args[3].boolean;
    return play;
}

struct DeleteStreamCommand {
    double transactionId;
    double streamId;
}

DeleteStreamCommand decodeDeleteStream(CommandMessage cmd) {
    DeleteStreamCommand del;
    del.transactionId = cmd.transactionId;
    if (cmd.args.length >= 1 && cmd.args[0].kind == AmfValue.Kind.number)
        del.streamId = cmd.args[0].number;
    return del;
}

ubyte[] encodeResultResponse(double transactionId, AmfValue properties, AmfValue info) {
    return encodeCommand(CommandMessage(
        commandName: "_result", transactionId: transactionId, commandObject: properties, args: [info]
    ));
}

ubyte[] encodeErrorResponse(double transactionId, AmfValue properties, AmfValue info) {
    return encodeCommand(CommandMessage(
        commandName: "_error", transactionId: transactionId, commandObject: properties, args: [info]
    ));
}

ubyte[] encodeOnStatus(AmfObject infoObject) {
    return encodeCommand(CommandMessage(
        commandName: "onStatus", transactionId: 0.0, commandObject: AmfValue.null_(), args: [AmfValue(infoObject)]
    ));
}

/// Build an onStatus info object with standard fields.
AmfObject makeStatusInfo(string level, string code, string description) {
    return AmfObject([
        AmfKeyValue("level", AmfValue(level)),
        AmfKeyValue("code", AmfValue(code)),
        AmfKeyValue("description", AmfValue(description)),
    ]);
}

//  Data Messages (AMF0, type 18)
struct DataMessage {
    string handler; // e.g. "@setDataFrame", "onMetaData"
    AmfValue[] values;
}

DataMessage decodeDataMessage(const(ubyte)[] payload) {
    auto values = decodeAll(payload);
    if (values.length < 1)
        throw new MessageException("data message requires at least 1 AMF value");
    if (values[0].kind != AmfValue.Kind.string_)
        throw new MessageException("data message handler must be a string");
    return DataMessage(
        handler: values[0].str,
        values: values.length > 1 ? values[1 .. $] : null,
    );
}

ubyte[] encodeDataMessage(DataMessage dm) {
    AmfValue[] all;
    all.reserve(1 + dm.values.length);
    all ~= AmfValue(dm.handler);
    foreach (ref v; dm.values)
        all ~= v;
    return encodeAll(all);
}

RtmpMessage makeProtocolControlMessage(ubyte typeId, uint timestamp, const(ubyte)[] payload) {
    return RtmpMessage(typeId: typeId, streamId: 0, timestamp: timestamp, payload: payload.dup);
}

RtmpMessage makeCommandRtmpMessage(uint streamId, uint timestamp, const(ubyte)[] payload) {
    return RtmpMessage(typeId: MessageTypeId.commandAmf0, streamId: streamId, timestamp: timestamp, payload: payload.dup);
}

// Protocol Control Messages round-trip
unittest {
    auto scs = decodeSetChunkSize(encodeSetChunkSize(4096));
    assert(scs.chunkSize == 4096);

    // Bit 31 masked off
    auto scs2 = decodeSetChunkSize(encodeSetChunkSize(0xFFFFFFFF));
    assert(scs2.chunkSize == 0x7FFFFFFF);
}

unittest {
    auto ab = decodeAbort(encodeAbort(42));
    assert(ab.chunkStreamId == 42);
}

unittest {
    auto ack = decodeAcknowledgement(encodeAcknowledgement(123456));
    assert(ack.sequenceNumber == 123456);
}

unittest {
    auto was = decodeWindowAckSize(encodeWindowAckSize(2500000));
    assert(was.size == 2500000);
}

unittest {
    auto spb = decodeSetPeerBandwidth(
        encodeSetPeerBandwidth(5000000, BandwidthLimitType.dynamic));
    assert(spb.windowSize == 5000000);
    assert(spb.limitType == BandwidthLimitType.dynamic);
}

// User Control Events round-trip
unittest {
    auto ev = UserControlEvent(UserControlEventType.streamBegin);
    ev.streamId = 1;
    auto decoded = decodeUserControl(encodeUserControl(ev));
    assert(decoded.eventType == UserControlEventType.streamBegin);
    assert(decoded.streamId == 1);
}

unittest {
    auto ev = UserControlEvent(UserControlEventType.setBufferLength);
    ev.streamId = 1;
    ev.bufferLength = 3000;
    auto decoded = decodeUserControl(encodeUserControl(ev));
    assert(decoded.eventType == UserControlEventType.setBufferLength);
    assert(decoded.streamId == 1);
    assert(decoded.bufferLength == 3000);
}

unittest {
    auto ev = UserControlEvent(UserControlEventType.pingRequest);
    ev.timestamp = 12345;
    auto decoded = decodeUserControl(encodeUserControl(ev));
    assert(decoded.eventType == UserControlEventType.pingRequest);
    assert(decoded.timestamp == 12345);
}

// Command Messages
unittest {
    // connect command round-trip
    auto cmdObj = AmfObject([
        AmfKeyValue("app", AmfValue("live")),
        AmfKeyValue("tcUrl", AmfValue("rtmp://localhost/live")),
        AmfKeyValue("fpad", AmfValue(false)),
        AmfKeyValue("audioCodecs", AmfValue(3191.0)),
        AmfKeyValue("videoCodecs", AmfValue(252.0)),
    ]);
    auto cmd = CommandMessage("connect", 1.0, AmfValue(cmdObj), []);
    auto encoded = encodeCommand(cmd);
    auto decoded = decodeCommand(encoded);
    assert(decoded.commandName == "connect");
    assert(decoded.transactionId == 1.0);
    assert(decoded.commandObject.kind == AmfValue.Kind.object);

    auto conn = decodeConnect(decoded);
    assert(conn.transactionId == 1.0);
    assert(("app" in conn.commandObject) !is null);
    assert((*("app" in conn.commandObject)) == AmfValue("live"));
}

unittest {
    // createStream round-trip
    auto cmd = CommandMessage("createStream", 2.0, AmfValue.null_(), []);
    auto decoded = decodeCommand(encodeCommand(cmd));
    assert(decoded.commandName == "createStream");
    auto cs = decodeCreateStream(decoded);
    assert(cs.transactionId == 2.0);
}

unittest {
    // publish command
    auto cmd = CommandMessage("publish", 3.0, AmfValue.null_(), [
        AmfValue("mystream"), AmfValue("live"),
    ]);
    auto decoded = decodeCommand(encodeCommand(cmd));
    auto pub = decodePublish(decoded);
    assert(pub.publishingName == "mystream");
    assert(pub.publishingType == PublishingType.live);
}

unittest {
    // play command with all params
    auto cmd = CommandMessage("play", 4.0, AmfValue.null_(), [
        AmfValue("stream1"), AmfValue(0.0), AmfValue(-1.0), AmfValue(false),
    ]);
    auto decoded = decodeCommand(encodeCommand(cmd));
    auto play = decodePlay(decoded);
    assert(play.streamName == "stream1");
    assert(play.start == 0.0);
    assert(play.duration == -1.0);
    assert(play.reset == false);
}

unittest {
    // deleteStream
    auto cmd = CommandMessage("deleteStream", 5.0, AmfValue.null_(), [
        AmfValue(1.0),
    ]);
    auto decoded = decodeCommand(encodeCommand(cmd));
    auto del = decodeDeleteStream(decoded);
    assert(del.streamId == 1.0);
}

// Response builders
unittest {
    // _result response
    auto props = AmfValue(AmfObject([
        AmfKeyValue("fmsVer", AmfValue("FMS/3,0,1,123")),
    ]));
    auto info = AmfValue(AmfObject([
        AmfKeyValue("code", AmfValue("NetConnection.Connect.Success")),
        AmfKeyValue("level", AmfValue("status")),
    ]));
    auto encoded = encodeResultResponse(1.0, props, info);
    auto decoded = decodeCommand(encoded);
    assert(decoded.commandName == "_result");
    assert(decoded.transactionId == 1.0);
}

unittest {
    // onStatus
    auto status = makeStatusInfo("status", "NetStream.Publish.Start", "Publishing started");
    auto encoded = encodeOnStatus(status);
    auto decoded = decodeCommand(encoded);
    assert(decoded.commandName == "onStatus");
    assert(decoded.transactionId == 0.0);
    assert(decoded.args.length == 1);
    assert(decoded.args[0].kind == AmfValue.Kind.object);
    auto obj = decoded.args[0].object;
    assert((*("code" in obj)) == AmfValue("NetStream.Publish.Start"));
}

// Data Messages
unittest {
    auto dm = DataMessage("@setDataFrame", [
        AmfValue("onMetaData"),
        AmfValue(AmfObject([
            AmfKeyValue("duration", AmfValue(0.0)),
            AmfKeyValue("width", AmfValue(1920.0)),
            AmfKeyValue("height", AmfValue(1080.0)),
        ])),
    ]);
    auto encoded = encodeDataMessage(dm);
    auto decoded = decodeDataMessage(encoded);
    assert(decoded.handler == "@setDataFrame");
    assert(decoded.values.length == 2);
    assert(decoded.values[0] == AmfValue("onMetaData"));
}

// Error cases
unittest {
    import std.exception : assertThrown;
    assertThrown!MessageException(decodeSetChunkSize([]));
}

unittest {
    import std.exception : assertThrown;
    assertThrown!MessageException(decodeCommand(encode(AmfValue("only_one"))));
}

unittest {
    import std.exception : assertThrown;
    assertThrown!MessageException(decodeUserControl([0x00]));
}

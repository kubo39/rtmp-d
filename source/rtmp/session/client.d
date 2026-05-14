/**
 * RTMP client session.
 *
 * Drives the client-side state machine: handshake, connect, createStream,
 * publish, and play. Transport-agnostic — caller feeds raw bytes in and
 * sends the returned bytes out.
 *
 * License:   $(HTTP boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
 * Authors:   Hiroki Noda
 * See_Also:  rtmp.session.server
 */
module rtmp.session.client;

import std.array : Appender;
import rtmp.amf;
import rtmp.handshake;
import rtmp.chunk;
import rtmp.message;
import rtmp.session.handler;

struct ClientSession {
    private enum State {
        init_,
        handshaking,
        connected,
        waitConnectResult,
        ready,
    }

    private State state_ = State.init_;
    private ClientHandshake handshake_;
    private ChunkReader reader_;
    private ChunkWriter writer_;

    private double nextTxId_ = 1.0;
    private bool connected_;
    private uint lastCreatedStreamId_;

    private uint peerWindowAckSize_ = 0;
    private uint bytesReceived_ = 0;
    private uint lastAckSent_ = 0;

    static ClientSession create() {
        ClientSession s;
        return s;
    }

    bool isConnected() const { return connected_; }
    bool isReady() const { return state_ == State.ready; }
    uint lastCreatedStreamId() const { return lastCreatedStreamId_; }

    ubyte[] startHandshake() {
        handshake_ = ClientHandshake.create();
        state_ = State.handshaking;
        return handshake_.generateC0C1();
    }

    ubyte[] processBytes(const(ubyte)[] data) {
        if (state_ == State.handshaking) {
            const result = handshake_.processBytes(data);
            ubyte[] output;
            if (result.kind == HandshakeResult.Kind.sendData)
                output = result.data.dup;
            if (handshake_.done) {
                state_ = State.connected;
                auto remaining = handshake_.remainingBytes();
                if (remaining.length > 0)
                    output ~= processMessages(remaining);
            }
            return output;
        }
        return processMessages(data);
    }

    ubyte[] connect(string app, string tcUrl) {
        if (state_ != State.connected)
            throw new SessionException("invalid state for connect");
        auto cmdObj = AmfObject([
            AmfKeyValue("app", AmfValue(app)),
            AmfKeyValue("tcUrl", AmfValue(tcUrl)),
        ]);
        auto payload = encodeCommand(CommandMessage(
            commandName: "connect", transactionId: nextTxId_++, commandObject: AmfValue(cmdObj)));
        state_ = State.waitConnectResult;
        return writeCommand(0, payload);
    }

    ubyte[] createStream() {
        if (state_ != State.ready)
            throw new SessionException("not ready");
        auto payload = encodeCommand(CommandMessage(
            commandName: "createStream", transactionId: nextTxId_++, commandObject: AmfValue.null_()));
        return writeCommand(0, payload);
    }

    ubyte[] publish(uint streamId, string name, string type) {
        if (state_ != State.ready)
            throw new SessionException("not ready");
        auto payload = encodeCommand(CommandMessage(
            commandName: "publish", transactionId: 0.0,
            commandObject: AmfValue.null_(),
            args: [AmfValue(name), AmfValue(type)]));
        auto msg = RtmpMessage(
            typeId: cast(ubyte) MessageTypeId.commandAmf0,
            streamId: streamId, timestamp: 0, payload: payload);
        return writer_.writeMessage(STREAM_COMMAND_CSID, msg);
    }

    ubyte[] play(uint streamId, string name) {
        if (state_ != State.ready)
            throw new SessionException("not ready");
        auto payload = encodeCommand(CommandMessage(
            commandName: "play", transactionId: 0.0,
            commandObject: AmfValue.null_(),
            args: [AmfValue(name)]));
        auto msg = RtmpMessage(
            typeId: cast(ubyte) MessageTypeId.commandAmf0,
            streamId: streamId, timestamp: 0, payload: payload);
        return writer_.writeMessage(STREAM_COMMAND_CSID, msg);
    }

    ubyte[] sendAudio(uint streamId, uint timestamp, const(ubyte)[] payload) {
        auto msg = RtmpMessage(
            typeId: cast(ubyte) MessageTypeId.audio,
            streamId: streamId, timestamp: timestamp, payload: payload.dup);
        return writer_.writeMessage(AUDIO_CSID, msg);
    }

    ubyte[] sendVideo(uint streamId, uint timestamp, const(ubyte)[] payload) {
        auto msg = RtmpMessage(
            typeId: cast(ubyte) MessageTypeId.video,
            streamId: streamId, timestamp: timestamp, payload: payload.dup);
        return writer_.writeMessage(VIDEO_CSID, msg);
    }

    private ubyte[] processMessages(const(ubyte)[] data) {
        auto output = Appender!(ubyte[])();
        bytesReceived_ += cast(uint) data.length;
        reader_.addData(data);
        RtmpMessage msg;
        while (reader_.readMessage(msg)) {
            if (msg.typeId == MessageTypeId.setChunkSize)
                reader_.setChunkSize(decodeSetChunkSize(msg.payload).chunkSize);
            output ~= handleMessage(msg);
        }
        if (peerWindowAckSize_ > 0 && bytesReceived_ - lastAckSent_ >= peerWindowAckSize_) {
            output ~= writeProtocolControl(MessageTypeId.acknowledgement,
                encodeAcknowledgement(bytesReceived_));
            lastAckSent_ = bytesReceived_;
        }
        return output[];
    }

    private ubyte[] handleMessage(RtmpMessage msg) {
        switch (msg.typeId) {
            case MessageTypeId.setChunkSize:
                return null;
            case MessageTypeId.windowAckSize:
                peerWindowAckSize_ = decodeWindowAckSize(msg.payload).size;
                return null;
            case MessageTypeId.setPeerBandwidth:
                auto spb = decodeSetPeerBandwidth(msg.payload);
                return writeProtocolControl(MessageTypeId.windowAckSize,
                    encodeWindowAckSize(spb.windowSize));
            case MessageTypeId.commandAmf0:
                return handleCommand(msg);
            case MessageTypeId.userControl:
                return handleUserControl(msg.payload);
            default:
                return null;
        }
    }

    private ubyte[] handleUserControl(const(ubyte)[] payload) {
        auto ev = decodeUserControl(payload);
        if (ev.eventType == UserControlEventType.pingRequest) {
            auto pong = UserControlEvent(eventType: UserControlEventType.pingResponse, timestamp: ev.timestamp);
            return writeProtocolControl(MessageTypeId.userControl,
                encodeUserControl(pong));
        }
        return null;
    }

    private ubyte[] handleCommand(RtmpMessage msg) {
        auto cmd = decodeCommand(msg.payload);

        if (cmd.commandName == "_result") {
            if (state_ == State.waitConnectResult) {
                connected_ = true;
                state_ = State.ready;
            } else if (cmd.args.length > 0 && cmd.args[0].kind == AmfValue.Kind.number) {
                lastCreatedStreamId_ = cast(uint) cmd.args[0].number;
            }
        }
        return null;
    }

    private ubyte[] writeCommand(uint streamId, ubyte[] payload) {
        auto msg = RtmpMessage(
            typeId: cast(ubyte) MessageTypeId.commandAmf0,
            streamId: streamId, timestamp: 0, payload: payload);
        return writer_.writeMessage(COMMAND_CSID, msg);
    }

    private ubyte[] writeProtocolControl(MessageTypeId typeId, ubyte[] payload) {
        auto msg = RtmpMessage(typeId: cast(ubyte) typeId, streamId: 0, timestamp: 0, payload: payload);
        return writer_.writeMessage(PROTOCOL_CHUNK_STREAM_ID, msg);
    }
}

@("Client handshake")
unittest {
    auto client = ClientSession.create();
    auto c0c1 = client.startHandshake();
    assert(c0c1.length == 1 + HANDSHAKE_SIZE);
    assert(c0c1[0] == RTMP_VERSION);
}

@("Client state validation")
unittest {
    auto client = ClientSession.create();

    import std.exception : assertThrown;
    assertThrown!SessionException(client.connect("live", "rtmp://localhost/live"));
}

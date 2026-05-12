module rtmp.session.server;

import std.array : Appender;
import rtmp.amf;
import rtmp.handshake;
import rtmp.chunk;
import rtmp.message;
import rtmp.session.handler;
private enum SERVER_CHUNK_SIZE = 4096;
private enum DEFAULT_WINDOW_ACK_SIZE = 2500000;
private enum DEFAULT_PEER_BANDWIDTH = 2500000;

struct ServerSession {
    private enum State {
        handshaking,
        waitConnect,
        ready,
    }

    private State state_ = State.handshaking;
    private ServerHandshake handshake_;
    private ChunkReader reader_;
    private ChunkWriter writer_;
    private ServerHandler handler_;

    private uint peerWindowAckSize_ = 0;
    private uint ownWindowAckSize_ = DEFAULT_WINDOW_ACK_SIZE;
    private uint peerBandwidth_ = DEFAULT_PEER_BANDWIDTH;
    private uint bytesReceived_ = 0;
    private uint lastAckSent_ = 0;
    private uint nextStreamId_ = 1;

    this(ServerHandler handler) {
        handler_ = handler;
        handshake_ = ServerHandshake.create();
    }

    bool isReady() const { return state_ == State.ready; }

    ubyte[] processBytes(const(ubyte)[] data) {
        auto output = Appender!(ubyte[])();

        if (state_ == State.handshaking) {
            auto result = handshake_.processBytes(data);
            if (result.kind == HandshakeResult.Kind.sendData)
                output ~= result.data;
            if (handshake_.done) {
                state_ = State.waitConnect;
                auto remaining = handshake_.remainingBytes();
                if (remaining.length > 0)
                    output ~= processMessages(remaining);
            }
            return output[];
        }

        output ~= processMessages(data);
        return output[];
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
            case MessageTypeId.acknowledgement:
                return null;
            case MessageTypeId.abort:
                auto abortMsg = decodeAbort(msg.payload);
                reader_.discardStream(abortMsg.chunkStreamId);
                return null;
            case MessageTypeId.windowAckSize:
                peerWindowAckSize_ = decodeWindowAckSize(msg.payload).size;
                return null;
            case MessageTypeId.userControl:
                return handleUserControl(msg.payload);
            case MessageTypeId.commandAmf0:
                return handleCommand(msg);
            case MessageTypeId.dataAmf0:
                handleData(msg);
                return null;
            case MessageTypeId.audio:
                if (handler_ !is null)
                    handler_.onAudio(msg.streamId, msg.timestamp, msg.payload);
                return null;
            case MessageTypeId.video:
                if (handler_ !is null)
                    handler_.onVideo(msg.streamId, msg.timestamp, msg.payload);
                return null;
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

        switch (cmd.commandName) {
            case "connect":
                if (state_ != State.waitConnect)
                    throw new SessionException("unexpected connect");
                return handleConnect(cmd);
            case "createStream":
                if (state_ != State.ready)
                    throw new SessionException("not connected");
                return handleCreateStream(cmd, msg.streamId);
            case "publish":
                if (state_ != State.ready)
                    throw new SessionException("not connected");
                return handlePublish(cmd, msg.streamId);
            case "play":
                if (state_ != State.ready)
                    throw new SessionException("not connected");
                return handlePlay(cmd, msg.streamId);
            case "deleteStream":
                if (state_ != State.ready)
                    throw new SessionException("not connected");
                return handleDeleteStream(cmd, msg.streamId);
            default:
                return null;
        }
    }

    private ubyte[] handleConnect(CommandMessage cmd) {
        auto output = Appender!(ubyte[])();
        auto connectCmd = decodeConnect(cmd);

        bool accepted = handler_ is null || handler_.onConnect(connectCmd);

        if (!accepted) {
            auto info = AmfValue(AmfObject([
                AmfKeyValue("level", AmfValue("error")),
                AmfKeyValue("code", AmfValue("NetConnection.Connect.Rejected")),
                AmfKeyValue("description", AmfValue("Connection rejected.")),
            ]));
            output ~= writeCommand(0,
                encodeErrorResponse(cmd.transactionId, AmfValue.null_(), info));
            return output[];
        }

        output ~= writeProtocolControl(MessageTypeId.windowAckSize,
            encodeWindowAckSize(ownWindowAckSize_));

        output ~= writeProtocolControl(MessageTypeId.setPeerBandwidth,
            encodeSetPeerBandwidth(peerBandwidth_, BandwidthLimitType.hard));

        output ~= writeProtocolControl(MessageTypeId.setChunkSize,
            encodeSetChunkSize(SERVER_CHUNK_SIZE));
        writer_.setChunkSize(SERVER_CHUNK_SIZE);

        auto streamBegin = UserControlEvent(eventType: UserControlEventType.streamBegin, streamId: 0);
        output ~= writeProtocolControl(MessageTypeId.userControl,
            encodeUserControl(streamBegin));

        auto props = AmfValue(AmfObject([
            AmfKeyValue("fmsVer", AmfValue("FMS/3,0,1,123")),
            AmfKeyValue("capabilities", AmfValue(31.0)),
        ]));
        auto info = AmfValue(AmfObject([
            AmfKeyValue("level", AmfValue("status")),
            AmfKeyValue("code", AmfValue("NetConnection.Connect.Success")),
            AmfKeyValue("description", AmfValue("Connection succeeded.")),
            AmfKeyValue("objectEncoding", AmfValue(0.0)),
        ]));
        output ~= writeCommand(0,
            encodeResultResponse(cmd.transactionId, props, info));

        state_ = State.ready;
        return output[];
    }

    private ubyte[] handleCreateStream(CommandMessage cmd, uint msgStreamId) {
        auto cs = decodeCreateStream(cmd);
        uint newStreamId = nextStreamId_++;

        if (handler_ !is null)
            handler_.onCreateStream(newStreamId);

        return writeCommand(msgStreamId,
            encodeResultResponse(cs.transactionId, AmfValue.null_(),
                AmfValue(cast(double) newStreamId)));
    }

    private ubyte[] handlePublish(CommandMessage cmd, uint msgStreamId) {
        auto pub = decodePublish(cmd);

        if (handler_ !is null)
            handler_.onPublish(msgStreamId, pub);

        return writeCommand(msgStreamId,
            encodeOnStatus(makeStatusInfo(
                "status", "NetStream.Publish.Start", "Publishing started")));
    }

    private ubyte[] handlePlay(CommandMessage cmd, uint msgStreamId) {
        auto output = Appender!(ubyte[])();
        auto play = decodePlay(cmd);

        if (handler_ !is null)
            handler_.onPlay(msgStreamId, play);

        // §7.2.2.1: StreamIsRecorded
        auto streamIsRecorded = UserControlEvent(eventType: UserControlEventType.streamIsRecorded, streamId: msgStreamId);
        output ~= writeProtocolControl(MessageTypeId.userControl,
            encodeUserControl(streamIsRecorded));

        // §7.2.2.1: StreamBegin
        auto streamBegin = UserControlEvent(eventType: UserControlEventType.streamBegin, streamId: msgStreamId);
        output ~= writeProtocolControl(MessageTypeId.userControl,
            encodeUserControl(streamBegin));

        // §7.2.2.1: Play.Reset when reset flag is true
        if (play.reset) {
            output ~= writeCommand(msgStreamId,
                encodeOnStatus(makeStatusInfo(
                    "status", "NetStream.Play.Reset", "Playing and resetting")));
        }

        output ~= writeCommand(msgStreamId,
            encodeOnStatus(makeStatusInfo(
                "status", "NetStream.Play.Start", "Playing started")));

        return output[];
    }

    private ubyte[] handleDeleteStream(CommandMessage cmd, uint msgStreamId) {
        auto del = decodeDeleteStream(cmd);
        if (handler_ !is null)
            handler_.onDeleteStream(cast(uint) del.streamId);
        return null;
    }

    private void handleData(RtmpMessage msg) {
        if (handler_ !is null)
            handler_.onData(msg.streamId, msg.timestamp, decodeDataMessage(msg.payload));
    }

    private ubyte[] writeProtocolControl(MessageTypeId typeId, ubyte[] payload) {
        auto msg = RtmpMessage(typeId: cast(ubyte) typeId, streamId: 0, timestamp: 0, payload: payload);
        return writer_.writeMessage(PROTOCOL_CHUNK_STREAM_ID, msg);
    }

    private ubyte[] writeCommand(uint streamId, ubyte[] payload) {
        auto msg = RtmpMessage(typeId: cast(ubyte) MessageTypeId.commandAmf0, streamId: streamId, timestamp: 0, payload: payload);
        return writer_.writeMessage(COMMAND_CSID, msg);
    }
}

version(unittest)
{
    private class TestServerHandler : ServerHandler {
        bool connectCalled;
        bool rejectConnect;
        uint lastCreatedStream;
        string lastPublishName;
        string lastPlayName;
        uint lastDeletedStream;
        ubyte[][] receivedAudio;
        ubyte[][] receivedVideo;

        bool onConnect(ConnectCommand cmd) {
            connectCalled = true;
            return !rejectConnect;
        }

        void onCreateStream(uint streamId) {
            lastCreatedStream = streamId;
        }

        void onPublish(uint streamId, PublishCommand cmd) {
            lastPublishName = cmd.publishingName;
        }

        void onPlay(uint streamId, PlayCommand cmd) {
            lastPlayName = cmd.streamName;
        }

        void onDeleteStream(uint streamId) {
            lastDeletedStream = streamId;
        }

        void onAudio(uint streamId, uint timestamp, const(ubyte)[] payload) {
            receivedAudio ~= payload.dup;
        }

        void onVideo(uint streamId, uint timestamp, const(ubyte)[] payload) {
            receivedVideo ~= payload.dup;
        }

        void onData(uint streamId, uint timestamp, DataMessage data) {}
}

    private RtmpMessage[] parseResponse(ref ChunkReader reader, const(ubyte)[] data) {
        reader.addData(data);
        RtmpMessage[] msgs;
        RtmpMessage msg;
        while (reader.readMessage(msg)) {
            if (msg.typeId == MessageTypeId.setChunkSize)
                reader.setChunkSize(decodeSetChunkSize(msg.payload).chunkSize);
            msgs ~= msg;
        }
        return msgs;
    }
}

// Full flow: handshake → connect → createStream → publish
unittest {
    auto handler = new TestServerHandler();
    auto server = ServerSession(handler);
    auto clientHS = ClientHandshake.create();
    auto clientWriter = ChunkWriter();
    auto clientReader = ChunkReader();

    // Handshake
    auto c0c1 = clientHS.generateC0C1();
    auto s0s1s2 = server.processBytes(c0c1);
    assert(s0s1s2.length == 1 + HANDSHAKE_SIZE * 2);

    auto hsResult = clientHS.processBytes(s0s1s2);
    assert(hsResult.kind == HandshakeResult.Kind.sendData);

    auto afterC2 = server.processBytes(hsResult.data);

    // Connect
    auto connectPayload = encodeCommand(CommandMessage(
        "connect", 1.0, AmfValue(AmfObject([
            AmfKeyValue("app", AmfValue("live")),
        ])), null));
    auto connectChunks = clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, connectPayload));

    auto connectResponse = server.processBytes(connectChunks);
    assert(connectResponse.length > 0);
    assert(handler.connectCalled);
    assert(server.isReady);

    auto responses = parseResponse(clientReader, connectResponse);
    assert(responses.length == 5);
    assert(responses[0].typeId == MessageTypeId.windowAckSize);
    assert(responses[1].typeId == MessageTypeId.setPeerBandwidth);
    assert(responses[2].typeId == MessageTypeId.setChunkSize);
    assert(responses[3].typeId == MessageTypeId.userControl);
    assert(responses[4].typeId == MessageTypeId.commandAmf0);

    auto resultCmd = decodeCommand(responses[4].payload);
    assert(resultCmd.commandName == "_result");
    assert(resultCmd.transactionId == 1.0);

    // CreateStream
    auto csPayload = encodeCommand(CommandMessage(
        "createStream", 2.0, AmfValue.null_(), null));
    auto csChunks = clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, csPayload));

    auto csResponse = server.processBytes(csChunks);
    auto csMessages = parseResponse(clientReader, csResponse);
    assert(csMessages.length == 1);
    auto csResult = decodeCommand(csMessages[0].payload);
    assert(csResult.commandName == "_result");
    assert(csResult.args[0].number == 1.0);
    assert(handler.lastCreatedStream == 1);

    // Publish
    auto pubPayload = encodeCommand(CommandMessage(
        "publish", 3.0, AmfValue.null_(), [AmfValue("mystream"), AmfValue("live")]));
    auto pubChunks = clientWriter.writeMessage(8,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 1, 0, pubPayload));

    auto pubResponse = server.processBytes(pubChunks);
    assert(handler.lastPublishName == "mystream");

    auto pubMessages = parseResponse(clientReader, pubResponse);
    assert(pubMessages.length == 1);
    auto statusCmd = decodeCommand(pubMessages[0].payload);
    assert(statusCmd.commandName == "onStatus");
}

// Connect rejection
unittest {
    auto handler = new TestServerHandler();
    handler.rejectConnect = true;
    auto server = ServerSession(handler);
    auto clientHS = ClientHandshake.create();
    auto clientWriter = ChunkWriter();
    auto clientReader = ChunkReader();

    auto c0c1 = clientHS.generateC0C1();
    auto s0s1s2 = server.processBytes(c0c1);
    auto hsResult = clientHS.processBytes(s0s1s2);
    server.processBytes(hsResult.data);

    auto connectPayload = encodeCommand(CommandMessage(
        "connect", 1.0, AmfValue(AmfObject([
            AmfKeyValue("app", AmfValue("live")),
        ])), null));
    auto connectChunks = clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, connectPayload));

    auto response = server.processBytes(connectChunks);
    auto messages = parseResponse(clientReader, response);
    assert(messages.length == 1);
    auto cmd = decodeCommand(messages[0].payload);
    assert(cmd.commandName == "_error");
    assert(!server.isReady);
}

// Ping auto-response
unittest {
    auto handler = new TestServerHandler();
    auto server = ServerSession(handler);
    auto clientHS = ClientHandshake.create();
    auto clientWriter = ChunkWriter();
    auto clientReader = ChunkReader();

    // Complete handshake + connect
    auto c0c1 = clientHS.generateC0C1();
    auto s0s1s2 = server.processBytes(c0c1);
    auto hsResult = clientHS.processBytes(s0s1s2);
    server.processBytes(hsResult.data);

    auto connectPayload = encodeCommand(CommandMessage(
        "connect", 1.0, AmfValue(AmfObject([
            AmfKeyValue("app", AmfValue("live")),
        ])), null));
    auto connectResponse = server.processBytes(clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, connectPayload)));
    parseResponse(clientReader, connectResponse);

    // Send PingRequest
    auto pingEv = UserControlEvent(UserControlEventType.pingRequest);
    pingEv.timestamp = 12345;
    auto pingPayload = encodeUserControl(pingEv);
    auto pingChunks = clientWriter.writeMessage(PROTOCOL_CHUNK_STREAM_ID,
        RtmpMessage(cast(ubyte) MessageTypeId.userControl, 0, 0, pingPayload));

    auto pingResponse = server.processBytes(pingChunks);
    auto msgs = parseResponse(clientReader, pingResponse);
    assert(msgs.length == 1);
    assert(msgs[0].typeId == MessageTypeId.userControl);
    auto pong = decodeUserControl(msgs[0].payload);
    assert(pong.eventType == UserControlEventType.pingResponse);
    assert(pong.timestamp == 12345);
}

// Audio/Video forwarding to handler
unittest {
    auto handler = new TestServerHandler();
    auto server = ServerSession(handler);
    auto clientHS = ClientHandshake.create();
    auto clientWriter = ChunkWriter();

    // Handshake + connect
    auto c0c1 = clientHS.generateC0C1();
    auto s0s1s2 = server.processBytes(c0c1);
    auto hsResult = clientHS.processBytes(s0s1s2);
    server.processBytes(hsResult.data);

    auto connectPayload = encodeCommand(CommandMessage(
        "connect", 1.0, AmfValue(AmfObject([
            AmfKeyValue("app", AmfValue("live")),
        ])), null));
    server.processBytes(clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, connectPayload)));

    // CreateStream
    auto csPayload = encodeCommand(CommandMessage(
        "createStream", 2.0, AmfValue.null_(), null));
    server.processBytes(clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, csPayload)));

    // Publish
    auto pubPayload = encodeCommand(CommandMessage(
        "publish", 3.0, AmfValue.null_(), [AmfValue("test"), AmfValue("live")]));
    server.processBytes(clientWriter.writeMessage(8,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 1, 0, pubPayload)));

    // Send audio
    ubyte[] audioData = [0xAF, 0x01, 0x02, 0x03];
    server.processBytes(clientWriter.writeMessage(4,
        RtmpMessage(cast(ubyte) MessageTypeId.audio, 1, 100, audioData)));
    assert(handler.receivedAudio.length == 1);
    assert(handler.receivedAudio[0] == audioData);

    // Send video
    ubyte[] videoData = [0x17, 0x01, 0x00, 0x00, 0x00];
    server.processBytes(clientWriter.writeMessage(6,
        RtmpMessage(cast(ubyte) MessageTypeId.video, 1, 100, videoData)));
    assert(handler.receivedVideo.length == 1);
    assert(handler.receivedVideo[0] == videoData);
}

// Invalid state: command before connect
unittest {
    import std.exception : assertThrown;
    auto handler = new TestServerHandler();
    auto server = ServerSession(handler);
    auto clientHS = ClientHandshake.create();
    auto clientWriter = ChunkWriter();

    auto c0c1 = clientHS.generateC0C1();
    auto s0s1s2 = server.processBytes(c0c1);
    auto hsResult = clientHS.processBytes(s0s1s2);
    server.processBytes(hsResult.data);

    auto csPayload = encodeCommand(CommandMessage(
        "createStream", 1.0, AmfValue.null_(), null));
    auto csChunks = clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, csPayload));

    assertThrown!SessionException(server.processBytes(csChunks));
}

// Play command handling
unittest {
    auto handler = new TestServerHandler();
    auto server = ServerSession(handler);
    auto clientHS = ClientHandshake.create();
    auto clientWriter = ChunkWriter();
    auto clientReader = ChunkReader();

    // Handshake + connect + createStream
    auto c0c1 = clientHS.generateC0C1();
    auto s0s1s2 = server.processBytes(c0c1);
    auto hsResult = clientHS.processBytes(s0s1s2);
    server.processBytes(hsResult.data);

    auto connectPayload = encodeCommand(CommandMessage(
        "connect", 1.0, AmfValue(AmfObject([
            AmfKeyValue("app", AmfValue("live")),
        ])), null));
    auto connectResponse = server.processBytes(clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, connectPayload)));
    parseResponse(clientReader, connectResponse);

    auto csPayload = encodeCommand(CommandMessage(
        "createStream", 2.0, AmfValue.null_(), null));
    auto csResponse = server.processBytes(clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, csPayload)));
    parseResponse(clientReader, csResponse);

    // Play
    auto playPayload = encodeCommand(CommandMessage(
        "play", 4.0, AmfValue.null_(), [AmfValue("stream1")]));
    auto playChunks = clientWriter.writeMessage(8,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 1, 0, playPayload));

    auto playResponse = server.processBytes(playChunks);
    assert(handler.lastPlayName == "stream1");

    auto playMsgs = parseResponse(clientReader, playResponse);
    // StreamIsRecorded + StreamBegin + Play.Reset + Play.Start
    assert(playMsgs.length == 4);
    assert(playMsgs[0].typeId == MessageTypeId.userControl);
    auto isRecorded = decodeUserControl(playMsgs[0].payload);
    assert(isRecorded.eventType == UserControlEventType.streamIsRecorded);
    assert(playMsgs[1].typeId == MessageTypeId.userControl);
    auto begin = decodeUserControl(playMsgs[1].payload);
    assert(begin.eventType == UserControlEventType.streamBegin);
    assert(playMsgs[2].typeId == MessageTypeId.commandAmf0);
    auto resetCmd = decodeCommand(playMsgs[2].payload);
    assert(resetCmd.commandName == "onStatus");
    assert(playMsgs[3].typeId == MessageTypeId.commandAmf0);
    auto startCmd = decodeCommand(playMsgs[3].payload);
    assert(startCmd.commandName == "onStatus");
}

// DeleteStream
unittest {
    auto handler = new TestServerHandler();
    auto server = ServerSession(handler);
    auto clientHS = ClientHandshake.create();
    auto clientWriter = ChunkWriter();
    auto clientReader = ChunkReader();

    // Handshake + connect + createStream
    auto c0c1 = clientHS.generateC0C1();
    auto s0s1s2 = server.processBytes(c0c1);
    auto hsResult = clientHS.processBytes(s0s1s2);
    server.processBytes(hsResult.data);

    auto connectPayload = encodeCommand(CommandMessage(
        "connect", 1.0, AmfValue(AmfObject([
            AmfKeyValue("app", AmfValue("live")),
        ])), null));
    auto connectResponse = server.processBytes(clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, connectPayload)));
    parseResponse(clientReader, connectResponse);

    auto csPayload = encodeCommand(CommandMessage(
        "createStream", 2.0, AmfValue.null_(), null));
    server.processBytes(clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, csPayload)));

    // DeleteStream
    auto delPayload = encodeCommand(CommandMessage(
        "deleteStream", 3.0, AmfValue.null_(), [AmfValue(1.0)]));
    auto delChunks = clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, delPayload));

    auto delResponse = server.processBytes(delChunks);
    assert(handler.lastDeletedStream == 1);
}

// No handler (null): auto-accept everything
unittest {
    auto server = ServerSession(null);
    auto clientHS = ClientHandshake.create();
    auto clientWriter = ChunkWriter();
    auto clientReader = ChunkReader();

    auto c0c1 = clientHS.generateC0C1();
    auto s0s1s2 = server.processBytes(c0c1);
    auto hsResult = clientHS.processBytes(s0s1s2);
    server.processBytes(hsResult.data);

    auto connectPayload = encodeCommand(CommandMessage(
        "connect", 1.0, AmfValue(AmfObject([
            AmfKeyValue("app", AmfValue("live")),
        ])), null));
    auto connectChunks = clientWriter.writeMessage(3,
        RtmpMessage(cast(ubyte) MessageTypeId.commandAmf0, 0, 0, connectPayload));

    auto response = server.processBytes(connectChunks);
    assert(server.isReady);
    auto msgs = parseResponse(clientReader, response);
    assert(msgs.length == 5);
    auto resultCmd = decodeCommand(msgs[4].payload);
    assert(resultCmd.commandName == "_result");
}

// Integration: full ServerSession + ClientSession flow
unittest {
    import rtmp.session.client : ClientSession;

    auto handler = new TestServerHandler();
    auto server = ServerSession(handler);
    auto client = ClientSession.create();

    // Handshake
    auto c0c1 = client.startHandshake();
    auto s0s1s2 = server.processBytes(c0c1);
    auto c2 = client.processBytes(s0s1s2);
    server.processBytes(c2);

    // Connect
    auto connectBytes = client.connect("live", "rtmp://localhost/live");
    auto connectResponse = server.processBytes(connectBytes);
    auto ackBytes = client.processBytes(connectResponse);
    if (ackBytes.length > 0)
        server.processBytes(ackBytes);

    assert(client.isConnected);
    assert(client.isReady);
    assert(server.isReady);

    // CreateStream
    auto csBytes = client.createStream();
    auto csResponse = server.processBytes(csBytes);
    client.processBytes(csResponse);

    assert(client.lastCreatedStreamId == 1);
    assert(handler.lastCreatedStream == 1);

    // Publish
    auto pubBytes = client.publish(1, "mystream", "live");
    auto pubResponse = server.processBytes(pubBytes);
    client.processBytes(pubResponse);

    assert(handler.lastPublishName == "mystream");

    // Send audio
    ubyte[] audioData = [0xAF, 0x01, 0x02];
    auto audioBytes = client.sendAudio(1, 100, audioData);
    server.processBytes(audioBytes);
    assert(handler.receivedAudio.length == 1);
    assert(handler.receivedAudio[0] == audioData);

    // Send video
    ubyte[] videoData = [0x17, 0x01, 0x00];
    auto videoBytes = client.sendVideo(1, 200, videoData);
    server.processBytes(videoBytes);
    assert(handler.receivedVideo.length == 1);
    assert(handler.receivedVideo[0] == videoData);
}

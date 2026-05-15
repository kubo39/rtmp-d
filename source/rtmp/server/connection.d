/**
 * Per-connection handler for the vibe-core server.
 *
 * Implements ServerHandler to route incoming publisher data into a
 * StreamManager, and Subscriber to receive distributed media from a
 * publisher's stream.
 *
 * License:   $(HTTP boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
 * Authors:   Hiroki Noda
 * See_Also:  rtmp.server.server, rtmp.server.stream_manager
 */
module rtmp.server.connection;

import rtmp.chunk : ChunkWriter, RtmpMessage, PROTOCOL_CHUNK_STREAM_ID;
import rtmp.message;
import rtmp.session.handler : ServerHandler, Reply;
import rtmp.server.stream_manager : StreamManager, Subscriber;

class ConnectionHandler : ServerHandler, Subscriber {
    private StreamManager streamManager_;
    private ChunkWriter mediaWriter_;
    private ubyte[][] writeQueue_;
    private string publishingStream_;
    private string playingStream_;
    private uint playStreamId_;

    this(StreamManager streamManager) {
        streamManager_ = streamManager;
        mediaWriter_.setChunkSize(4096);
    }

    Reply onConnect(ConnectCommand cmd) {
        return Reply.accept();
    }

    void onCreateStream(uint streamId) {}

    Reply onPublish(uint streamId, PublishCommand cmd) {
        if (cmd.publishingName.length == 0)
            return Reply.reject("NetStream.Publish.BadName", "Stream name required.");
        if (!streamManager_.publish(cmd.publishingName))
            return Reply.reject("NetStream.Publish.BadName", "Stream already publishing.");
        publishingStream_ = cmd.publishingName;
        return Reply.accept();
    }

    Reply onPlay(uint streamId, PlayCommand cmd) {
        if (cmd.streamName.length == 0)
            return Reply.reject("NetStream.Play.StreamNotFound", "Stream name required.");
        streamManager_.subscribe(cmd.streamName, this);
        playingStream_ = cmd.streamName;
        playStreamId_ = streamId;
        return Reply.accept();
    }

    void onDeleteStream(uint streamId) {
        cleanup();
    }

    void onAudio(uint streamId, uint timestamp, const(ubyte)[] payload) {
        if (publishingStream_.length == 0)
            return;
        auto stream = streamManager_.getStream(publishingStream_);
        if (stream !is null)
            stream.distribute(MessageTypeId.audio, timestamp, payload);
    }

    void onVideo(uint streamId, uint timestamp, const(ubyte)[] payload) {
        if (publishingStream_.length == 0)
            return;
        auto stream = streamManager_.getStream(publishingStream_);
        if (stream !is null)
            stream.distribute(MessageTypeId.video, timestamp, payload);
    }

    void onData(uint streamId, uint timestamp, DataMessage data) {}

    void enqueueMedia(const(ubyte)[] data) {
        writeQueue_ ~= data.dup;
    }

    bool hasQueuedData() const {
        return writeQueue_.length > 0;
    }

    ubyte[][] drainWriteQueue() {
        auto queued = writeQueue_;
        writeQueue_ = null;
        return queued;
    }

    void cleanup() {
        if (publishingStream_.length > 0) {
            streamManager_.unpublish(publishingStream_);
            publishingStream_ = null;
        }
        if (playingStream_.length > 0) {
            streamManager_.unsubscribe(playingStream_, this);
            playingStream_ = null;
        }
    }
}

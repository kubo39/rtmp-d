/**
 * Server-side session callbacks.
 *
 * Defines the ServerHandler interface that applications implement to react
 * to incoming RTMP commands (connect, publish, play, ...) and media data.
 *
 * License:   $(HTTP boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
 * Authors:   Hiroki Noda
 * See_Also:  rtmp.session.server
 */
module rtmp.session.handler;

import rtmp.message;

class SessionException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

interface ServerHandler {
    bool onConnect(ConnectCommand cmd);
    void onCreateStream(uint streamId);
    void onPublish(uint streamId, PublishCommand cmd);
    void onPlay(uint streamId, PlayCommand cmd);
    void onDeleteStream(uint streamId);
    void onAudio(uint streamId, uint timestamp, const(ubyte)[] payload);
    void onVideo(uint streamId, uint timestamp, const(ubyte)[] payload);
    void onData(uint streamId, uint timestamp, DataMessage data);
}

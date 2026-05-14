/**
 * vibe-core based RTMP server.
 *
 * Listens for TCP connections on a configured port and spawns a fiber
 * per connection. Glue code between the protocol library and vibe-core.
 *
 * License:   $(HTTP boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
 * Authors:   Hiroki Noda
 * See_Also:  rtmp.server.connection, rtmp.server.stream_manager
 */
module rtmp.server.server;

import vibe.core.net : listenTCP, TCPConnection;
import vibe.core.core : runTask, yield;
import vibe.core.stream : IOMode;

import rtmp.session.server : ServerSession;
import rtmp.server.stream_manager : StreamManager;
import rtmp.server.connection : ConnectionHandler;

private void nothrowCleanup(ConnectionHandler handler) @trusted nothrow {
    try {
        handler.cleanup();
    } catch (Exception) {}
}

private void writerTask(TCPConnection conn, ConnectionHandler handler, bool* running) @trusted nothrow {
    try {
        while (*running && conn.connected) {
            auto queued = handler.drainWriteQueue();
            foreach (chunk; queued) {
                conn.write(cast(const(ubyte)[]) chunk);
            }
            yield();
        }
    } catch (Exception) {
        *running = false;
    }
}

struct RtmpServerConfig {
    string host = "0.0.0.0";
    ushort port = 1935;
}

class RtmpServer {
    private StreamManager streamManager_;
    private RtmpServerConfig config_;

    this(RtmpServerConfig config = RtmpServerConfig.init) {
        config_ = config;
        streamManager_ = new StreamManager();
    }

    void listen() {
        listenTCP(config_.port, &handleConnection, config_.host);
    }

    private void handleConnection(TCPConnection conn) @trusted nothrow {
        try {
            auto handler = new ConnectionHandler(streamManager_);
            auto session = ServerSession(handler);
            bool running = true;

            runTask(&writerTask, conn, handler, &running);

            scope(exit) {
                running = false;
                if (conn.connected)
                    conn.close();
                nothrowCleanup(handler);
            }

            try {
                ubyte[4096] buf;
                while (running && conn.connected) {
                    auto n = conn.read(buf[], IOMode.once);
                    if (n == 0)
                        break;
                    auto response = session.processBytes(buf[0 .. n]);
                    if (response.length > 0)
                        conn.write(response);
                }
            } catch (Exception) {
            }
        } catch (Exception) {
        }
    }
}

/**
 * vibe-core based RTMP server subpackage.
 *
 * Reference server implementation built on top of the rtmp-d protocol
 * library. Provides TCP listening, per-connection session handling, and
 * stream routing.
 *
 * License:   $(HTTP boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
 * Authors:   Hiroki Noda
 */
module rtmp.server;

public import rtmp.server.stream_manager;
public import rtmp.server.connection;
public import rtmp.server.server;

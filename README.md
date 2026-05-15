# rtmp-d

> **Status: Experimental** — This project is under active development. API may change without notice and is not yet ready for production use.

A [RTMP 1.0 protocol](https://veovera.github.io/enhanced-rtmp/docs/legacy/rtmp-v1-0-spec.pdf) library for D.

## Features

- AMF0 encoding/decoding
- RTMP handshake (client & server)
- Chunk stream reader/writer
- RTMP message encoding/decoding (protocol control, user control, command, audio/video, data)
- Session management (ClientSession & ServerSession)

### rtmp-d:server

vibe-core based RTMP server implementation.

- Per-connection session handling
- Stream routing (1 publisher : N subscribers)
- Publisher disconnect notification (StreamEOF)

## Usage

### Protocol library

```d
import rtmp.session;

// Client
auto client = ClientSession.create();
auto c0c1 = client.startHandshake();

// Server
auto handler = new MyServerHandler();
auto session = ServerSession(handler);
auto response = session.processBytes(incomingData);
```

### Server

```d
import rtmp.server;

auto listener = listenRTMP(RtmpServerConfig(port: 1935));
scope(exit) listener.stopListening();
// Call runApplication() from vibe-core to start the event loop
```

## Building

```sh
# Build protocol library
dub build

# Build server subpackage
dub build rtmp-d:server

# Run tests
dub test
```

## License

[Boost Software License 1.0](LICENSE)

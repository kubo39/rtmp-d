/**
 * Stream routing between publishers and subscribers.
 *
 * Maps stream names to a single publisher and N subscribers. Media
 * messages from the publisher are distributed to all subscribers via the
 * Subscriber interface.
 *
 * License:   $(HTTP boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
 * Authors:   Hiroki Noda
 * See_Also:  rtmp.server.server, rtmp.server.connection
 */
module rtmp.server.stream_manager;

import rtmp.chunk : ChunkWriter, RtmpMessage, PROTOCOL_CHUNK_STREAM_ID;
import rtmp.message;

interface Subscriber {
    void enqueueMedia(const(ubyte)[] data);
}

class Stream {
    private bool hasPublisher_;
    private Subscriber[] subscribers_;

    bool hasPublisher() const {
        return hasPublisher_;
    }

    size_t subscriberCount() const {
        return subscribers_.length;
    }

    bool empty() const {
        return !hasPublisher_ && subscribers_.length == 0;
    }

    void distribute(ubyte typeId, uint timestamp, const(ubyte)[] payload) {
        if (subscribers_.length == 0)
            return;
        auto writer = ChunkWriter();
        writer.setChunkSize(4096);
        const csid = (typeId == MessageTypeId.audio) ? AUDIO_CSID : VIDEO_CSID;
        auto msg = RtmpMessage(typeId: typeId, streamId: 1, timestamp: timestamp, payload: payload.dup);
        auto encoded = writer.writeMessage(csid, msg);
        foreach (sub; subscribers_)
            sub.enqueueMedia(encoded);
    }

    void removeSubscriber(Subscriber sub) {
        Subscriber[] remaining;
        foreach (s; subscribers_) {
            if (s !is sub)
                remaining ~= s;
        }
        subscribers_ = remaining;
    }
}

class StreamManager {
    private Stream[string] streams_;

    bool publish(string name) {
        if (name in streams_) {
            auto stream = streams_[name];
            if (stream.hasPublisher())
                return false;
            stream.hasPublisher_ = true;
            return true;
        }
        auto stream = new Stream();
        stream.hasPublisher_ = true;
        streams_[name] = stream;
        return true;
    }

    bool subscribe(string name, Subscriber subscriber) {
        if (name !in streams_)
            streams_[name] = new Stream();
        streams_[name].subscribers_ ~= subscriber;
        return true;
    }

    void unpublish(string name) {
        if (name !in streams_)
            return;
        auto stream = streams_[name];
        stream.hasPublisher_ = false;
        // Notify subscribers with StreamEOF
        if (stream.subscribers_.length > 0) {
            auto eof = UserControlEvent(eventType: UserControlEventType.streamEOF, streamId: 1);
            auto payload = encodeUserControl(eof);
            auto writer = ChunkWriter();
            auto msg = RtmpMessage(
                typeId: cast(ubyte) MessageTypeId.userControl,
                streamId: 0, timestamp: 0, payload: payload);
            auto encoded = writer.writeMessage(PROTOCOL_CHUNK_STREAM_ID, msg);
            foreach (sub; stream.subscribers_)
                sub.enqueueMedia(encoded);
        }
        if (stream.empty())
            streams_.remove(name);
    }

    void unsubscribe(string name, Subscriber subscriber) {
        if (name !in streams_)
            return;
        auto stream = streams_[name];
        stream.removeSubscriber(subscriber);
        if (stream.empty())
            streams_.remove(name);
    }

    Stream getStream(string name) {
        if (auto p = name in streams_)
            return *p;
        return null;
    }

    size_t streamCount() const {
        return streams_.length;
    }
}

version(unittest)
{
    private class MockSubscriber : Subscriber {
        ubyte[][] received;
        void enqueueMedia(const(ubyte)[] data) {
            received ~= data.dup;
        }
    }
}

@("Publish creates a new stream")
unittest {
    auto mgr = new StreamManager();
    assert(mgr.publish("live/test"));
    assert(mgr.streamCount() == 1);
    auto stream = mgr.getStream("live/test");
    assert(stream !is null);
    assert(stream.hasPublisher());
}

@("Duplicate publish rejected")
unittest {
    auto mgr = new StreamManager();
    assert(mgr.publish("live/test"));
    assert(!mgr.publish("live/test"));
}

@("Subscribe to non-existent stream creates it")
unittest {
    auto mgr = new StreamManager();
    auto sub = new MockSubscriber();
    assert(mgr.subscribe("live/test", sub));
    assert(mgr.streamCount() == 1);
    auto stream = mgr.getStream("live/test");
    assert(stream !is null);
    assert(!stream.hasPublisher());
    assert(stream.subscriberCount() == 1);
}

@("Publish after subscribe joins existing stream")
unittest {
    auto mgr = new StreamManager();
    auto sub = new MockSubscriber();
    mgr.subscribe("live/test", sub);
    assert(mgr.publish("live/test"));
    auto stream = mgr.getStream("live/test");
    assert(stream.hasPublisher());
    assert(stream.subscriberCount() == 1);
}

@("Distribute forwards to all subscribers")
unittest {
    auto mgr = new StreamManager();
    auto sub1 = new MockSubscriber();
    auto sub2 = new MockSubscriber();
    mgr.publish("live/test");
    mgr.subscribe("live/test", sub1);
    mgr.subscribe("live/test", sub2);

    auto stream = mgr.getStream("live/test");
    ubyte[] payload = [0xAF, 0x01, 0x02, 0x03];
    stream.distribute(MessageTypeId.audio, 100, payload);

    assert(sub1.received.length == 1);
    assert(sub2.received.length == 1);
    // Both get the same chunk-encoded bytes
    assert(sub1.received[0] == sub2.received[0]);
    assert(sub1.received[0].length > 0);
}

@("Distribute with no subscribers is a no-op")
unittest {
    auto mgr = new StreamManager();
    mgr.publish("live/test");
    auto stream = mgr.getStream("live/test");
    stream.distribute(MessageTypeId.video, 0, [0x17, 0x00]);
    // No crash, no data sent
}

@("Unpublish notifies subscribers with StreamEOF")
unittest {
    auto mgr = new StreamManager();
    auto sub = new MockSubscriber();
    mgr.publish("live/test");
    mgr.subscribe("live/test", sub);

    mgr.unpublish("live/test");

    assert(sub.received.length == 1);
    assert(sub.received[0].length > 0);
    // Stream should still exist (subscriber remains)
    assert(mgr.streamCount() == 1);
    auto stream = mgr.getStream("live/test");
    assert(!stream.hasPublisher());
}

@("Unpublish with no subscribers removes stream")
unittest {
    auto mgr = new StreamManager();
    mgr.publish("live/test");
    mgr.unpublish("live/test");
    assert(mgr.streamCount() == 0);
    assert(mgr.getStream("live/test") is null);
}

@("Unsubscribe removes subscriber")
unittest {
    auto mgr = new StreamManager();
    auto sub1 = new MockSubscriber();
    auto sub2 = new MockSubscriber();
    mgr.publish("live/test");
    mgr.subscribe("live/test", sub1);
    mgr.subscribe("live/test", sub2);

    mgr.unsubscribe("live/test", sub1);
    auto stream = mgr.getStream("live/test");
    assert(stream.subscriberCount() == 1);
}

@("Unsubscribe last subscriber + no publisher removes stream")
unittest {
    auto mgr = new StreamManager();
    auto sub = new MockSubscriber();
    mgr.subscribe("live/test", sub);
    mgr.unsubscribe("live/test", sub);
    assert(mgr.streamCount() == 0);
}

@("Multiple streams are independent")
unittest {
    auto mgr = new StreamManager();
    auto sub1 = new MockSubscriber();
    auto sub2 = new MockSubscriber();

    mgr.publish("stream_a");
    mgr.publish("stream_b");
    mgr.subscribe("stream_a", sub1);
    mgr.subscribe("stream_b", sub2);

    auto streamA = mgr.getStream("stream_a");
    streamA.distribute(MessageTypeId.audio, 0, [0x01]);

    assert(sub1.received.length == 1);
    assert(sub2.received.length == 0);
}

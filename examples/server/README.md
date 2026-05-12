# RTMP Server Example

A simple RTMP server using the rtmp-d library. It relays published streams to all subscribed clients.

## Build

```
dub build rtmp-d:example-server
```

## Run

```
./rtmp-server
```

Listens on `0.0.0.0:1935` by default.

## Usage

### Publish

Send a test pattern with FFmpeg:

```
ffmpeg -f lavfi -i testsrc=duration=30:size=320x240:rate=15 \
       -f lavfi -i sine=frequency=440:duration=30 \
       -c:v flv1 -c:a aac \
       -f flv rtmp://localhost:1935/live/test
```

Stream from a camera/microphone:

```
ffmpeg -f v4l2 -i /dev/video0 -f pulse -i default \
       -c:v flv1 -c:a aac \
       -f flv rtmp://localhost:1935/live/test
```

### Subscribe

In another terminal, play the stream with FFplay:

```
ffplay rtmp://localhost:1935/live/test
```

Or save to a file:

```
ffmpeg -i rtmp://localhost:1935/live/test -c copy output.flv
```

import vibe.core.core : runApplication;
import rtmp.server : listenRTMP, RtmpServerConfig;

int main()
{
    auto listener = listenRTMP(RtmpServerConfig(host: "0.0.0.0", port: 1935));
    scope(exit) listener.stopListening();
    return runApplication();
}

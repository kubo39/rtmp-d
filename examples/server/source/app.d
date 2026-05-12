import vibe.core.core : runApplication;
import rtmp.server : RtmpServer, RtmpServerConfig;

int main()
{
    auto config = RtmpServerConfig(host: "0.0.0.0", port: 1935);
    auto server = new RtmpServer(config);
    server.listen();
    return runApplication();
}

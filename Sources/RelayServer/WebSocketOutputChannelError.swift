/// Reports output attempted after the NIO handler context was released.
enum WebSocketOutputChannelError: Error {
    case closed
}

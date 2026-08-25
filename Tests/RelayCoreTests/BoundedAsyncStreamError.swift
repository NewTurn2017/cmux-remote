import Foundation

enum BoundedAsyncStreamError: Error {
    case ended
    case timeout
}

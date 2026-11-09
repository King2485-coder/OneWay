import Combine
import Foundation
import Network

enum OneWayNetworkPathState: String {
    case online
    case offline
    case constrained
    case expensive
    case unknown
}

enum OneWayNetworkError: LocalizedError, Equatable {
    case offline
    case timeout
    case unauthorized
    case forbidden
    case notFound
    case serverUnavailable
    case invalidResponse
    case decoding
    case cancelled
    case unknown

    var errorDescription: String? {
        switch self {
        case .offline:
            return "You’re offline."
        case .timeout:
            return "The backend request timed out."
        case .unauthorized:
            return "Your session is unavailable. Please sign in again."
        case .forbidden:
            return "This account does not have access."
        case .notFound:
            return "The requested resource was not found."
        case .serverUnavailable:
            return "The OneWay backend is temporarily unavailable."
        case .invalidResponse, .decoding:
            return "The backend returned an unreadable response."
        case .cancelled:
            return "The request was cancelled."
        case .unknown:
            return "The request could not be completed."
        }
    }

    static func classify(_ error: Error) -> OneWayNetworkError {
        if let classified = error as? OneWayNetworkError {
            return classified
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
                return .offline
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            default:
                return .unknown
            }
        }
        if let apiError = error as? APIClientError {
            switch apiError {
            case .server(let statusCode, _):
                switch statusCode {
                case 401: return .unauthorized
                case 403: return .forbidden
                case 404: return .notFound
                case 500...599: return .serverUnavailable
                default: return .unknown
                }
            case .invalidBaseURL, .invalidResponse, .emptyResponse:
                return .invalidResponse
            }
        }
        if error is DecodingError {
            return .decoding
        }
        return .unknown
    }
}

final class OneWayConnectivity: ObservableObject {
    static let shared = OneWayConnectivity()
    static let didBecomeOnline = Notification.Name("OneWay.Connectivity.didBecomeOnline")

    @Published private(set) var state: OneWayNetworkPathState = .unknown

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.oneway.connectivity")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let nextState: OneWayNetworkPathState
            if path.status != .satisfied {
                nextState = .offline
            } else if path.isConstrained {
                nextState = .constrained
            } else if path.isExpensive {
                nextState = .expensive
            } else {
                nextState = .online
            }

            DispatchQueue.main.async {
                guard let self else { return }
                let wasOffline = self.state == .offline || self.state == .unknown
                self.state = nextState
#if DEBUG
                let interfaces = path.availableInterfaces.map(\.type.debugName).joined(separator: ",")
                print("[Network] path=\(nextState.rawValue) interfaces=\(interfaces)")
#endif
                if wasOffline, nextState != .offline {
                    NotificationCenter.default.post(name: Self.didBecomeOnline, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }
}

private extension NWInterface.InterfaceType {
    var debugName: String {
        switch self {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "ethernet"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}

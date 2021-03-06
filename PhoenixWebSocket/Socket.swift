//
//  Socket.swift
//  PhoenixWebSocket
//
//  Created by Almas Sapargali on 2/4/16.
//  Copyright © 2016 Almas Sapargali. All rights reserved.
//

import Foundation
import Starscream

// http://stackoverflow.com/a/24888789/1935440
// String's stringByAddingPercentEncodingWithAllowedCharacters doesn't encode + sign,
// which is ofter used in Phoenix tokens.
private let URLEncodingAllowedChars = NSCharacterSet(charactersInString: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/?")

private func encodePair(pair: (String, String)) -> String? {
    if let key = pair.0.stringByAddingPercentEncodingWithAllowedCharacters(URLEncodingAllowedChars),
        value = pair.1.stringByAddingPercentEncodingWithAllowedCharacters(URLEncodingAllowedChars)
    { return "\(key)=\(value)" } else { return nil }
}


private func resolveUrl(url: NSURL, params: [String: String]?) -> NSURL {
    guard let components = NSURLComponents(URL: url, resolvingAgainstBaseURL: false),
        params = params else { return url }
    
    let queryString = params.flatMap(encodePair).joinWithSeparator("&")
    components.percentEncodedQuery = queryString
    return components.URL ?? url
}

public enum SendError: ErrorType {
    case NotConnected
    
    case PayloadSerializationFailed(String)
    
    case ResponseDeserializationFailed(ResponseError)
    
    case ChannelNotJoined
}

extension SendError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .NotConnected: return "Socket is not connected to the server."
        case .PayloadSerializationFailed(let reason):
            return "Payload serialization failed: \(reason)"
        case .ResponseDeserializationFailed(let error):
            return "Response deserialization failed: \(error)"
        case .ChannelNotJoined: return "Channel not joined."
        }
    }
}

public enum MessageResponse {
    case Success(Response)
    
    /// Note that errors received from server will be in Success case.
    /// This case for client side errors.
    case Error(SendError)
}

public final class Socket {
    public typealias MessageCallback = MessageResponse -> ()
    
    private static let HearbeatRefPrefix = "heartbeat-"
    
    private let socket: WebSocket
    
    private var reconnectTimer: NSTimer?
    private var heartbeatTimer: NSTimer?
    
    public var enableLogging: Bool = true
    
    public var onConnect: (() -> ())?
    public var onDisconnect: (NSError? -> ())?
    
    // ref as key, for triggering callback when phx_reply event comes in
    private var sentMessages = [String: MessageCallback]()
    
    private var channels = Set<Channel>()
    
    // data may become stale on this
    private var connectedChannels = Set<Channel>()
    
    /// **Warning:** Please don't forget to disconnect when you're done to prevent memory leak
    public init(url: NSURL, params: [String: String]? = nil, selfSignedSSL: Bool = false) {
        socket = WebSocket(url: resolveUrl(url, params: params))
        socket.selfSignedSSL = selfSignedSSL
        socket.delegate = self
    }
    
    /// Connects socket to server, if socket is already connected to server, makes sure 
    /// all timers are in place. This may be usefull to ensure connection when app comes 
    /// from background, since all timers invalidated when app goes background.
    public func connect(reconnectOnError: Bool = true, reconnectInterval: NSTimeInterval = 5) {
        // if everything is on place
        if let heartbeatTimer = heartbeatTimer
            where socket.isConnected && heartbeatTimer.valid { return }
        
        if reconnectOnError {
            // let's invalidate old timer if any
            reconnectTimer?.invalidate()
            reconnectTimer = NSTimer.scheduledTimerWithTimeInterval(reconnectInterval,
                target: self, selector: #selector(Socket.retry), userInfo: nil, repeats: true)
        }
        
        if socket.isConnected { // just restart heartbeat timer
            // send one now attempting to not to timeout on server
            sendHeartbeat()
            // setup new timer
            heartbeatTimer?.invalidate()
            heartbeatTimer = NSTimer.scheduledTimerWithTimeInterval(30,
                target: self, selector: #selector(Socket.sendHeartbeat), userInfo: nil, repeats: true)
        } else {
            log("Connecting to", socket.currentURL)
            channels.forEach { $0.status = .Joining }
            socket.connect()
        }
    }
    
    @objc func retry() {
        guard !socket.isConnected else { return }
        log("Retrying connect to", socket.currentURL)
        channels.forEach { $0.status = .Joining }
        socket.connect()
    }
    
    /// See Starscream.WebSocket.disconnect() for forceTimeout argument's doc
    public func disconnect(forceTimeout: NSTimeInterval? = nil) {
        heartbeatTimer?.invalidate()
        reconnectTimer?.invalidate()
        if socket.isConnected {
            log("Disconnecting from", socket.currentURL)
            socket.disconnect(forceTimeout: forceTimeout)
        }
    }
    
    public func send(channel: Channel, event: String, payload: Message.JSON = [:], callback: MessageCallback? = nil) {
        guard socket.isConnected else {
            callback?(.Error(.NotConnected))
            log("Attempt to send message while not connected:", event, payload)
            return
        }
        guard channels.contains(channel) && channel.status.isJoined() else {
            callback?(.Error(.ChannelNotJoined))
            log("Attempt to send message to not joined channel:", channel.topic, event, payload)
            return
        }
        sendMessage(Message(event, topic: channel.topic, payload: payload), callback: callback)
    }
    
    public func join(channel: Channel) {
        channels.insert(channel)
        if socket.isConnected { // check for setting status here.
            channel.status = .Joining
            sendJoinEvent(channel)
        }
    }
    
    private func sendJoinEvent(channel: Channel) {
        // if socket isn't connected, we join this channel right after connection
        guard socket.isConnected else { return }
        
        log("Joining channel:", channel.topic)
        let payload = channel.joinPayload ?? [:]
        // Use send message to skip channel joined check
        sendMessage(Message(Event.Join, topic: channel.topic, payload: payload)) { [weak self] result in
            switch result {
            case .Success(let joinResponse):
                switch joinResponse {
                case .Ok(let response):
                    self?.log("Joined channel, payload:", response)
                    self?.connectedChannels.insert(channel)
                    channel.status = .Joined(response)
                case let .Error(reason, response):
                    self?.log("Rejected from channel, payload:", response)
                    channel.status = .Rejected(reason, response)
                }
            case .Error(let error):
                self?.log("Failed to join channel:", error)
                channel.status = .JoinFailed(error)
            }
        }
    }
    
    public func leave(channel: Channel) {
        // before guard so it won't be rejoined on next connection
        channels.remove(channel)
        
        // we simply won't rejoin after connection
        guard socket.isConnected else { return }
        
        log("Leaving channel:", channel.topic)
        sendMessage(Message(Event.Leave, topic: channel.topic, payload: [:])) { [weak self] result in
            switch result {
            case .Success(let response):
                self?.log("Left channel, payload:", response)
                self?.connectedChannels.remove(channel)
                channel.status = .Disconnected(nil)
            case .Error(let error): // how is this possible?
                self?.log("Failed to leave channel:", error)
            }
        }
    }
    
    func sendMessage(message: Message, callback: MessageCallback? = nil) {
        do {
            let data = try message.toJson()
            log("Sending", message)
            // force unwrap because:
            // 0. if ref is missing, then something is going wrong
            // 1. this func isn't public
            sentMessages[message.ref!] = callback
            socket.writeData(data)
        } catch let error as NSError {
            log("Failed to send message:", error)
            callback?(.Error(.PayloadSerializationFailed(error.localizedDescription)))
        }
    }
    
    @objc func sendHeartbeat() {
        guard socket.isConnected else { return }
        // so we can skip logging them, less noisy
        let ref = Socket.HearbeatRefPrefix + NSUUID().UUIDString
        sendMessage(Message(Event.Heartbeat, topic: "phoenix", payload: [:], ref: ref))
    }
    
    // Phoenix related events
    struct Event {
        static let Heartbeat = "heartbeat"
        static let Join = "phx_join"
        static let Leave = "phx_leave"
        static let Reply = "phx_reply"
        static let Error = "phx_error"
        static let Close = "phx_close"
    }
}

extension Socket: WebSocketDelegate {
    public func websocketDidConnect(socket: Starscream.WebSocket) {
        log("Connected to:", socket.currentURL)
        onConnect?()
        heartbeatTimer?.invalidate()
        heartbeatTimer = NSTimer.scheduledTimerWithTimeInterval(30,
            target: self, selector: #selector(Socket.sendHeartbeat), userInfo: nil, repeats: true)
        // statuses set when we were connecting socket
        channels.forEach(sendJoinEvent)
    }
    
    public func websocketDidDisconnect(socket: Starscream.WebSocket, error: NSError?) {
        log("Disconnected from:", socket.currentURL, error)
        // we don't worry about reconnecting, since we've started reconnectTime when connecting
        onDisconnect?(error)
        heartbeatTimer?.invalidate()
        channels.forEach { channel in
            switch channel.status {
            case .Joined(_), .Joining: channel.status = .Disconnected(error)
            default: break
            }
        }
        connectedChannels.removeAll()
        
        // I don't think we'll recive their responses
        sentMessages.removeAll()
    }
    
    public func websocketDidReceiveMessage(socket: Starscream.WebSocket, text: String) {
        guard let data = text.dataUsingEncoding(NSUTF8StringEncoding), message = Message(data: data)
            else { log("Couldn't parse message from text:", text); return }
        
        // don't log if hearbeat reply
        if let ref = message.ref where ref.hasPrefix(Socket.HearbeatRefPrefix) { }
        else { log("Received:", message) }
        
        // Replied message
        if let ref = message.ref, callback = sentMessages.removeValueForKey(ref) {
            do {
                callback(.Success(try Response.fromPayload(message.payload)))
            } catch let error as ResponseError {
                callback(.Error(.ResponseDeserializationFailed(error)))
            } catch {
                fatalError("Response.fromPayload throw unknown error")
            }
        }
        channels.filter { $0.topic == message.topic }
            .forEach { $0.recieved(message) }
    }
    
    public func websocketDidReceiveData(socket: Starscream.WebSocket, data: NSData) {
        log("Received data:", data)
    }
}

extension Socket {
    private func log(items: Any...) {
        if enableLogging { print(items) }
    }
}

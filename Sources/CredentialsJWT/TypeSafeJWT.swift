//
//  File.swift
//  
//
//  Created by Cameron McWilliam on 06/08/2019.
//

import Kitura
import KituraNet
import LoggerAPI
import Credentials
import Foundation
import SwiftJWT

/// The cache element for keeping google profile information.
private class JWTCacheElement<C: Claims> {
    /// The user profile information stored as `TypeSafeGoogleToken`.
    var userProfile: JWT<C>

    /// The time the UserProfile was originally created
    var createdAt: Date

    /// Initialize a `GoogleCacheElement`.
    ///
    /// - Parameter profile: the `TypeSafeGoogleToken` to store.
    init (profile: JWT<C>) {
        userProfile = profile
        createdAt = Date()
    }
}

// As it is not yet possible to have a stored static property on an generic type,
// this dictionary provides the storage for each specialization of JWTCacheElement<C>.
// The computed property TypeSafeJWTCache<C>.cacheForType uses an AnyHashableMetatype
// to
fileprivate var _cachesForType = [AnyHashableMetatype: Any]()

private struct TypeSafeJWTCache<C: Claims> {
    internal static var cacheForType: [String: NSCache<NSString, JWTCacheElement<C>>] {
        get {
            guard let cache = _cachesForType[AnyHashableMetatype(C.self), default: []] as? [String: NSCache<NSString, JWTCacheElement<C>>] else {
                // This should never happen
                fatalError("The cache for type \(C.self) could not be cast to the expected type")
            }
            return cache
        }
        set {
            _cachesForType[AnyHashableMetatype(C.self)] = newValue
        }
    }
}

extension JWT: TypeSafeCredentials {
    public var id: String {
        return "id"
    }
    
    
    public var provider: String {
        return "JWT"
    }
    
    
    public static var cacheSize: Int {
        return 0
    }
    
    public static var tokenTimeToLive: TimeInterval? {
        return nil
    }
    
    private static var usersCache: NSCache<NSString, JWTCacheElement<T>> {
        let key = String(reflecting: Self.self)
        if let usersCache = TypeSafeJWTCache<T>.cacheForType[key] {
            return usersCache
        } else {
            let usersCache = NSCache<NSString, JWTCacheElement<T>>()
            Log.debug("Token cache size for \(key): \(cacheSize == 0 ? "unlimited" : String(describing: cacheSize))")
            usersCache.countLimit = cacheSize
            TypeSafeJWTCache.cacheForType[key] = usersCache
            return usersCache
        }
    }
    
    public static func authenticate(request: RouterRequest, response: RouterResponse,
                                    onSuccess: @escaping (JWT<T>) -> Void,
                                    onFailure: @escaping (HTTPStatusCode?, [String : String]?) -> Void,
                                    onSkip: @escaping (HTTPStatusCode?, [String : String]?) -> Void) {
        // Check whether this request declares that a Google token is being supplied
        guard let type = request.headers["X-token-type"], type == "JWT" else {
            return onSkip(nil, nil)
        }
        // Check whether a token has been supplied
        guard let token = request.headers["Authorization"] else {
            return onFailure(nil, nil)
        }
         //Return a cached profile from the cache associated with our type, if one is found
         //(ie. if we have successfully authenticated this token before)
        if let cacheProfile = getFromCache(token: token) {
            return onSuccess(cacheProfile)
        }
        let auth = request.headers["Authorization"]
            guard let authParts = auth?.split(separator: " ", maxSplits: 2),
                authParts.count == 2,
                authParts[0] == "Bearer",
                let key = "<PrivateKey>".data(using: .utf8),
                let jwt = try? JWT<T>(jwtString: String(authParts[1]), verifier: .hs256(key: key))
                else {
                    return onFailure(nil, nil)
            }
            onSuccess(jwt)
        }
    
    static func getFromCache(token: String) -> Self? {
        #if os(Linux)
        let key = NSString(string: token)
        #else
        let key = token as NSString
        #endif
        guard let cacheElement = Self.usersCache.object(forKey: key) else {
            Log.debug("Cached token not found: \(token)")
            return nil
        }
        Log.debug("Cached token found: \(token)")
        if let ttl = Self.tokenTimeToLive,
            cacheElement.createdAt.addingTimeInterval(ttl) < Date()
        {
            Log.debug("Cached token has expired: \(token)")
            return nil
        }
        Log.debug("Cached token is valid: \(token)")
        return cacheElement.userProfile
    }

    static func saveInCache(profile: Self, token: String) {
        #if os(Linux)
        let key = NSString(string: token)
        #else
        let key = token as NSString
        #endif
        Self.usersCache.setObject(JWTCacheElement(profile: profile), forKey: key)
        Log.debug("Token added to cache: \(token)")
    }
}
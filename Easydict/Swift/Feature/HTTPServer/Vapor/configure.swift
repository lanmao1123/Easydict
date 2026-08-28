//
//  vapor.swift
//  Easydict
//
//  Created by tisfeng on 2024/7/15.
//  Copyright © 2024 izual. All rights reserved.
//

import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    // Loopback only, made explicit: the routes expose translation and the
    // user's selected text with no auth, so the server must never bind a
    // public interface. The port stays user-configurable (set by VaporServer).
    app.http.server.configuration.hostname = "127.0.0.1"
    // register routes
    try routes(app)
}

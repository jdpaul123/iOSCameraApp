//
//  TestSessionConfiguration.swift
//  iOSCameraAppTests
//
//  Created by Jonathan Paul on 11/15/23.
//

import XCTest
@testable import iOSCameraApp

final class SessionConfigurationTests: XCTestCase {

    func testSessionExists() {
        let vc = ViewController(nibName: nil, bundle: nil)
        XCTAssertNotNil(vc.session)
    }
}

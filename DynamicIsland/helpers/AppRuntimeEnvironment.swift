/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// Runtime context flags used to keep the app's launch deterministic on CI.
enum AppRuntimeEnvironment {
    /// `true` for both unit-test host processes and XCUITest launches.
    /// Feature services that own global resources or persistent data should
    /// use this broader flag rather than only checking launch arguments.
    static let isTesting: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return isUITesting
            || environment["ATOLL_UNIT_TESTING"] == "1"
            || (CommandLine.arguments.contains("-NSTreatUnknownArgumentsAsOpen")
                && CommandLine.arguments.contains("-ApplePersistenceIgnoreState"))
            || NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCInjectBundleInto"] != nil
            || environment.keys.contains { $0.hasPrefix("XCTest") }
    }()

    /// `true` only for the XCTest host process. The shared scheme sets the
    /// explicit environment flag so hosted unit tests remain deterministic on
    /// headless GitHub runners where XCTest injection variables arrive late.
    static let isUnitTesting: Bool = {
        !isUITesting && isTesting
    }()

    /// `true` only in DEBUG builds launched by XCUITest (`--uitesting`); always false in Release.
    static let isUITesting: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--uitesting")
        #else
        return false
        #endif
    }()
}

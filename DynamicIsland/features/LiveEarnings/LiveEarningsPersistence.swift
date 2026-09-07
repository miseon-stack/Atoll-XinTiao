/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Defaults

extension LiveEarningsSalaryMode: Defaults.Serializable {}
extension LiveEarningsWeekday: Defaults.Serializable {}
extension LiveEarningsLocalTime: Defaults.Serializable {}
extension LiveEarningsConfig: Defaults.Serializable {}

extension Defaults.Keys {
    static let liveEarningsConfig = Key<LiveEarningsConfig>(
        "liveEarningsConfig.v1",
        default: LiveEarningsConfig()
    )
}

//
//  ClockActivityManager.swift
//  boringNotch
//
//  Created by OpenAI on 2025-02-17.
//

import Combine
import Foundation

struct ClockActivity: Equatable {
    enum Kind: String {
        case timer
        case stopwatch
    }

    let kind: Kind
    let title: String
    let time: TimeInterval
    let isRunning: Bool
}

@MainActor
final class ClockActivityManager: ObservableObject {
    static let shared = ClockActivityManager()

    @Published private(set) var activity: ClockActivity?

    private var refreshTimer: Timer?
    private let updateInterval: TimeInterval = 1

    private init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func refresh() {
        let nextActivity = resolveActivity()
        if nextActivity != activity {
            activity = nextActivity
        }
    }

    private func resolveActivity() -> ClockActivity? {
        let domains = ["com.apple.clock", "com.apple.mobiletimer"]
        let domainData = domains.map { loadDomain(named: $0) }

        if let timerActivity = domainData.compactMap({ parseTimerActivity(from: $0) }).first {
            return timerActivity
        }

        if let stopwatchActivity = domainData.compactMap({ parseStopwatchActivity(from: $0) }).first {
            return stopwatchActivity
        }

        return nil
    }

    private func loadDomain(named name: String) -> [String: Any] {
        if let defaults = UserDefaults(suiteName: name) {
            let representation = defaults.dictionaryRepresentation()
            if !representation.isEmpty {
                return representation
            }
        }

        return UserDefaults.standard.persistentDomain(forName: name) ?? [:]
    }

    private func parseTimerActivity(from domain: [String: Any]) -> ClockActivity? {
        let timerSources: [Any?] = [
            domain["Timer"],
            domain["Timers"],
            domain["timer"],
            domain["timers"],
            domain["MTTimer"],
            domain["MTTimers"],
            domain["RunningTimers"],
        ]

        for source in timerSources {
            if let activity = parseTimerSource(source) {
                return activity
            }
        }

        return nil
    }

    private func parseStopwatchActivity(from domain: [String: Any]) -> ClockActivity? {
        let stopwatchSources: [Any?] = [
            domain["Stopwatch"],
            domain["stopwatch"],
            domain["MTStopwatch"],
            domain["Stopwatches"],
            domain["stopwatches"],
            domain["RunningStopwatches"],
        ]

        for source in stopwatchSources {
            if let activity = parseStopwatchSource(source) {
                return activity
            }
        }

        return nil
    }

    private func parseTimerSource(_ source: Any?) -> ClockActivity? {
        if let timerDict = source as? [String: Any] {
            return parseTimerDictionary(timerDict)
        }

        if let timerArray = source as? [[String: Any]] {
            for entry in timerArray {
                if let activity = parseTimerDictionary(entry) {
                    return activity
                }
            }
        }

        if let timerArray = source as? [Any] {
            for entry in timerArray {
                if let dict = entry as? [String: Any], let activity = parseTimerDictionary(dict) {
                    return activity
                }
            }
        }

        return nil
    }

    private func parseStopwatchSource(_ source: Any?) -> ClockActivity? {
        if let stopwatchDict = source as? [String: Any] {
            return parseStopwatchDictionary(stopwatchDict)
        }

        if let stopwatchArray = source as? [[String: Any]] {
            for entry in stopwatchArray {
                if let activity = parseStopwatchDictionary(entry) {
                    return activity
                }
            }
        }

        if let stopwatchArray = source as? [Any] {
            for entry in stopwatchArray {
                if let dict = entry as? [String: Any], let activity = parseStopwatchDictionary(dict) {
                    return activity
                }
            }
        }

        return nil
    }

    private func parseTimerDictionary(_ dict: [String: Any]) -> ClockActivity? {
        guard isRunning(in: dict) else {
            return nil
        }

        let remaining = remainingTime(from: dict)
        guard let remainingTime = remaining, remainingTime > 0 else {
            return nil
        }

        let title = stringValue(in: dict, keys: ["label", "title", "name", "TimerLabel"]) ?? "Timer"

        return ClockActivity(kind: .timer, title: title, time: remainingTime, isRunning: true)
    }

    private func parseStopwatchDictionary(_ dict: [String: Any]) -> ClockActivity? {
        guard isRunning(in: dict) else {
            return nil
        }

        guard let elapsed = elapsedTime(from: dict), elapsed >= 0 else {
            return nil
        }

        let title = stringValue(in: dict, keys: ["label", "title", "name", "StopwatchLabel"]) ?? "Stopwatch"

        return ClockActivity(kind: .stopwatch, title: title, time: elapsed, isRunning: true)
    }

    private func isRunning(in dict: [String: Any]) -> Bool {
        if let running = boolValue(in: dict, keys: ["running", "isRunning", "Running", "active", "isActive", "enabled"]) {
            return running
        }

        if let paused = boolValue(in: dict, keys: ["paused", "isPaused", "Paused"]) {
            return !paused
        }

        if let state = stringValue(in: dict, keys: ["state", "State", "status", "Status"])?.lowercased() {
            return state == "running" || state == "active"
        }

        return false
    }

    private func remainingTime(from dict: [String: Any]) -> TimeInterval? {
        if let remaining = timeIntervalValue(in: dict, keys: [
            "remaining",
            "remainingTime",
            "timeRemaining",
            "remainingDuration",
            "remainingSeconds",
            "remainingTimeInterval",
        ]) {
            return remaining
        }

        if let targetDate = dateValue(in: dict, keys: [
            "fireDate",
            "targetDate",
            "endDate",
            "expectedFireDate",
            "TimerFireDate",
            "TimerTargetDate",
        ]) {
            return max(0, targetDate.timeIntervalSinceNow)
        }

        if let startDate = dateValue(in: dict, keys: ["startDate", "StartDate"]),
           let duration = timeIntervalValue(in: dict, keys: ["duration", "Duration", "timerDuration"]) {
            return max(0, startDate.addingTimeInterval(duration).timeIntervalSinceNow)
        }

        return nil
    }

    private func elapsedTime(from dict: [String: Any]) -> TimeInterval? {
        if let elapsed = timeIntervalValue(in: dict, keys: [
            "elapsed",
            "elapsedTime",
            "timeElapsed",
            "elapsedSeconds",
            "elapsedTimeInterval",
        ]) {
            return elapsed
        }

        if let startDate = dateValue(in: dict, keys: ["startDate", "StartDate"]) {
            return max(0, Date().timeIntervalSince(startDate))
        }

        return nil
    }

    private func boolValue(in dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool {
                return value
            }
            if let number = dict[key] as? NSNumber {
                return number.boolValue
            }
            if let string = dict[key] as? String {
                let normalized = string.lowercased()
                if ["true", "yes", "1"].contains(normalized) {
                    return true
                }
                if ["false", "no", "0"].contains(normalized) {
                    return false
                }
            }
        }

        return nil
    }

    private func stringValue(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func dateValue(in dict: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = dict[key] as? Date {
                return value
            }
            if let timeInterval = dict[key] as? TimeInterval {
                return dateFromInterval(timeInterval)
            }
            if let number = dict[key] as? NSNumber {
                return dateFromInterval(number.doubleValue)
            }
            if let string = dict[key] as? String, let interval = TimeInterval(string) {
                return dateFromInterval(interval)
            }
        }

        return nil
    }

    private func timeIntervalValue(in dict: [String: Any], keys: [String]) -> TimeInterval? {
        for key in keys {
            if let value = dict[key] as? TimeInterval {
                return value
            }
            if let number = dict[key] as? NSNumber {
                return number.doubleValue
            }
            if let string = dict[key] as? String, let interval = TimeInterval(string) {
                return interval
            }
        }

        return nil
    }

    private func dateFromInterval(_ interval: TimeInterval) -> Date {
        if interval > 10_000_000_000 {
            return Date(timeIntervalSince1970: interval / 1000)
        }
        if interval > 1_000_000_000 {
            return Date(timeIntervalSince1970: interval)
        }
        return Date(timeIntervalSinceReferenceDate: interval)
    }
}

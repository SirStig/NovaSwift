import Foundation
import NovaSwiftKit

// MARK: - crön events, news and salaries (the daily tick's story half)

extension StoryEngine {

    /// The original's iterative-hook bail-out (0x2711 passes).
    static let cronLoopCap = 0x2711

    /// One day of `crön` processing (0x00439500, MS-14). An idle event rolls
    /// `rand(0…100) ≤ Random` first, then must be inside its date window and
    /// pass Require and EnableOn. It then waits PreHoldoff days, runs OnStart,
    /// lasts Duration days and runs OnEnd. Quirks kept: month/day bounds apply
    /// in every year; a Duration 0 event runs OnStart and OnEnd the same day
    /// and OnEnd again the next; the post-end wait is read from PreHoldoff, so
    /// with PreHoldoff 0 a PostHoldoff event never deactivates and reruns
    /// OnEnd daily; a negative Duration marks an absent slot.
    public func evaluateCrons() {
        for c in game.crons() where c.duration >= 0 {
            var rt = cronRuntime(c)
            if !(rt.active ?? false) {
                let roll = random(101)
                if roll > c.random || !dateInWindow(c) || !requireMet(c.require)
                    || !evaluate(test: c.enableOn) {
                    player.cronRuntime[c.id] = rt
                    continue
                }
                rt.active = true
                rt.duration = c.duration
                if c.preHoldoff < 1 {
                    rt.holdoff = 0
                    startCron(c)
                    if c.duration == 0 {
                        endCron(c)
                        rt.duration = -1
                        if c.postHoldoff > 0 { rt.holdoff = c.postHoldoff }
                    }
                } else {
                    rt.holdoff = c.preHoldoff
                }
            } else if (rt.holdoff ?? 0) < 1 {
                rt.duration = (rt.duration ?? 0) - 1
                if (rt.duration ?? 0) < 1 {
                    endCron(c)
                    if c.postHoldoff < 1 { rt.active = false } else { rt.holdoff = c.preHoldoff }
                }
            } else {
                rt.holdoff = (rt.holdoff ?? 0) - 1
                if (rt.holdoff ?? 0) < 1 {
                    if (rt.duration ?? 0) < 0 {
                        rt.active = false
                    } else {
                        startCron(c)
                        if rt.duration == 0 { endCron(c) }
                    }
                }
            }
            player.cronRuntime[c.id] = rt
        }
    }

    /// The event's counters, converting a runtime saved before they existed
    /// (dates) on first use.
    private func cronRuntime(_ c: CronRes) -> CronRuntime {
        var rt = player.cronRuntime[c.id] ?? CronRuntime(cronID: c.id)
        guard rt.active == nil else { return rt }
        let today = player.date
        if rt.startedDate != nil {
            rt.active = true
            rt.holdoff = 0
            rt.duration = max(0, today.days(until: rt.endDate ?? today))
        } else if let pending = rt.pendingStart {
            rt.active = true
            rt.holdoff = max(1, today.days(until: pending))
            rt.duration = c.duration
        } else if let earliest = rt.earliestStart, earliest > today {
            rt.active = true
            rt.holdoff = today.days(until: earliest)
            rt.duration = -1
        } else {
            rt.active = false
        }
        rt.startedDate = nil
        rt.endDate = nil
        rt.pendingStart = nil
        rt.earliestStart = nil
        return rt
    }

    private func requireMet(_ require: UInt64) -> Bool {
        require == 0 || (activeContributeBits() & require) == require
    }

    private func startCron(_ c: CronRes) {
        runCronHook(c.onStart, iterative: c.loopStartUntilFalse, cron: c, field: "OnStart")
        Log.mission.debug("cron \(c.id) started on \(String(describing: self.player.date), privacy: .public)")
        services?.notify(.cronStarted(cronID: c.id))
    }

    private func endCron(_ c: CronRes) {
        runCronHook(c.onEnd, iterative: c.loopEndUntilFalse, cron: c, field: "OnEnd")
        Log.mission.debug("cron \(c.id) ended on \(String(describing: self.player.date), privacy: .public)")
        services?.notify(.cronEnded(cronID: c.id))
    }

    /// Run OnStart/OnEnd (0x00439750 / 0x004398b0). An iterative event (Flags
    /// 0x0001 start / 0x0002 end) re-runs its string while Require and
    /// EnableOn still hold — tested *before* each run, so it may run no times
    /// at all — up to 0x2711 passes.
    private func runCronHook(_ expr: String, iterative: Bool, cron c: CronRes, field: String) {
        let source = ncbSource("crön", c.id, c.name, field)
        guard iterative else {
            apply(set: expr, source: source)
            return
        }
        var passes = 0
        while passes < Self.cronLoopCap, requireMet(c.require), evaluate(test: c.enableOn) {
            // Past the first few passes the bit-level log is suppressed so a
            // long-running loop doesn't bury a bug report.
            apply(set: expr, source: source, logBits: passes < 3)
            passes += 1
        }
        if passes >= Self.cronLoopCap {
            Log.mission.error("cron \(c.id) iterative hook hit cap \(Self.cronLoopCap); aborting loop (possible infinite EnableOn)")
        }
    }

    /// The crön date window (0x0046c800): the year bounds and the month/day
    /// bounds are separate tests, so month/day apply in every year. A month
    /// of 0 bounds on the day alone; a day of 0 on the month alone; both set
    /// compare `month × 32 + day`; a negative field is ignored.
    func dateInWindow(_ c: CronRes) -> Bool {
        let d = player.date
        let dayKey = d.month * 32 + d.day
        if c.firstYear > 0, d.year < c.firstYear { return false }
        if c.firstMonth == 0 {
            if c.firstDay > 0, d.day < c.firstDay { return false }
        } else if c.firstMonth < 1 || c.firstDay != 0 {
            if c.firstMonth > 0, c.firstDay > 0, dayKey < c.firstMonth * 32 + c.firstDay { return false }
        } else if d.month < c.firstMonth {
            return false
        }
        if c.lastYear > 0, d.year > c.lastYear { return false }
        if c.lastMonth == 0 {
            if c.lastDay > 0, d.day > c.lastDay { return false }
        } else if c.lastMonth < 1 || c.lastDay != 0 {
            if c.lastMonth > 0, c.lastDay > 0, c.lastMonth * 32 + c.lastDay < dayKey { return false }
        } else if d.month > c.lastMonth {
            return false
        }
        return true
    }

    // MARK: News (MS-20)

    /// The crön news a station of `govt` shows (0x0047d600): one string. Of
    /// the events now running (holdoffs over), each contributes its *last*
    /// NewsGovt slot allied with the station as local news; an event with no
    /// allied slot contributes its IndNewsStr. Local news beats independent;
    /// one STR# is picked at random and one entry from it. Empty when no
    /// event has news here — the Holovid then shows generic news.
    public func stationNews(forGovt govt: Int?) -> [String] {
        let stationGovt = govt ?? -1
        var local: [Int] = []
        var independent: [Int] = []
        for c in game.crons() {
            guard let rt = player.cronRuntime[c.id], rt.isActive, (rt.holdoff ?? 0) < 1 else { continue }
            var slotStr: Int? = nil
            for (k, g) in c.newsGovts.enumerated() where g != -1 && k < c.govtNewsStrs.count {
                if geography.allied(g, stationGovt) { slotStr = c.govtNewsStrs[k] }
            }
            if let s = slotStr {
                if s > 0 { local.append(s) }
            } else if c.independentNewsStrID > 0 {
                independent.append(c.independentNewsStrID)
            }
        }
        let pool = local.isEmpty ? independent : local
        guard !pool.isEmpty, let body = randomStringListEntry(pool[random(pool.count)]) else { return [] }
        return [body]
    }

    /// The generic news body (STR# 8101), shown when no crön news applies.
    public func genericNews() -> String? { randomStringListEntry(8101) }

    /// The news window's headline (0x0047d600): a random STR# 8100 entry, else
    /// STR# 2002 #190.
    public func newsHeadline() -> String {
        randomStringListEntry(8100) ?? game.stringList(2002)?.string(at: 190) ?? ""
    }

    /// A random entry of a `STR#` list.
    func randomStringListEntry(_ strListID: Int) -> String? {
        guard let strings = game.stringList(strListID)?.strings, !strings.isEmpty else { return nil }
        return strings[random(strings.count)]
    }

    // MARK: Salaries

    /// Rank salaries (0x00466cb0): each active rank pays unless the player is
    /// at or above its SalaryCap (a cap below 1 is no cap), and credits are
    /// clamped at 0 after each payment.
    func payDailySalaries() {
        for rankID in player.activeRanks.sorted() {
            guard let r = game.rank(rankID), r.salary != 0 else { continue }
            if r.salaryCap < 1 || player.credits < r.salaryCap { player.credits += r.salary }
            if player.credits < 0 { player.credits = 0 }
        }
    }
}

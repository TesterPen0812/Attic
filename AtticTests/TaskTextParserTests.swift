import XCTest
@testable import Attic

/// The add bar's shorthand, parsed with an injected calendar, region and
/// "now". Thursday 24 September 2026, 10:00 in Rome, unless a test says
/// otherwise.
final class TaskTextParserTests: XCTestCase {
    private static let rome: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        rome.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func parser(
        now: Date = TaskTextParserTests.date(2026, 9, 24),
        locale: String = "en_US",
        calendar: Calendar = TaskTextParserTests.rome
    ) -> TaskTextParser {
        TaskTextParser(calendar: calendar, locale: Locale(identifier: locale), now: { now })
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> DueDay {
        DueDay(year: year, month: month, day: day)!
    }

    private func due(_ text: String, _ parser: TaskTextParser? = nil) -> DueDay? {
        (parser ?? self.parser()).parse(text).dueDay
    }

    // MARK: - Plain text

    func testPlainTextIsTheTitleWithNoTokens() {
        let parsed = parser().parse("  Call   the bank  ")
        XCTAssertEqual(parsed.title, "Call the bank")
        XCTAssertTrue(parsed.tokens.isEmpty)
        XCTAssertEqual(parser().parse("").title, "")
    }

    // MARK: - Tags

    func testTagsAreRecognisedNormalisedAndRemovedFromTheTitle() {
        let parsed = parser().parse("Buy milk #Home #errands-2 #home")
        XCTAssertEqual(parsed.title, "Buy milk")
        XCTAssertEqual(parsed.tags, ["home", "errands-2", "home"])
        XCTAssertEqual(parser().parse("#work Write report").title, "Write report")
        XCTAssertEqual(parser().parse("Ship it #q3_launch.").tags, ["q3-launch"])
    }

    func testThingsThatLookLikeTagsButAreNotStayText() {
        for text in ["Fix issue #42", "Learn C#", "Use a#b notation", "Price ## tag", "Just #", "Say #!"] {
            XCTAssertTrue(parser().parse(text).tags.isEmpty, text)
        }
        XCTAssertEqual(parser().parse("Fix issue #42").title, "Fix issue #42")
    }

    // MARK: - Priority

    func testStandaloneExclamationMarksSetPriority() {
        XCTAssertEqual(parser().parse("Pay rent !").priority, .medium)
        XCTAssertEqual(parser().parse("!! Pay rent").priority, .high)
        XCTAssertEqual(parser().parse("Pay rent !!").title, "Pay rent")
        XCTAssertEqual(parser().parse("! first !! second").priority, .medium, "only the first counts")
    }

    func testExclamationMarksInsideWordsStayText() {
        for text in ["Call mom!", "Wow!! nice", "Yahoo! mail", "Hey!there", "!!! urgent"] {
            XCTAssertNil(parser().parse(text).priority, text)
        }
        XCTAssertEqual(parser().parse("Call mom!").title, "Call mom!")
    }

    // MARK: - Relative days

    func testTodayTomorrowAndRelativeDays() {
        XCTAssertEqual(due("Pay today"), day(2026, 9, 24))
        XCTAssertEqual(due("Pay tomorrow"), day(2026, 9, 25))
        XCTAssertEqual(due("Pay TOMORROW."), day(2026, 9, 25))
        XCTAssertEqual(due("Renew in 3 days"), day(2026, 9, 27))
        XCTAssertEqual(due("Renew in 1 day"), day(2026, 9, 25))
        XCTAssertEqual(due("Renew in 2 weeks"), day(2026, 10, 8))
        XCTAssertEqual(due("Renew in a week"), day(2026, 10, 1))
        XCTAssertEqual(due("Renew in 1 month"), day(2026, 10, 24))
        XCTAssertNil(due("Put in some days"))
        XCTAssertNil(due("Stay in"))
    }

    func testTomorrowAcrossMonthYearAndDaylightSavingBoundaries() {
        XCTAssertEqual(due("x tomorrow", parser(now: Self.date(2026, 12, 31, hour: 23))), day(2027, 1, 1))
        // Rome leaves summer time on 25 October 2026.
        XCTAssertEqual(due("x tomorrow", parser(now: Self.date(2026, 10, 24, hour: 23))), day(2026, 10, 25))
        XCTAssertEqual(due("x tomorrow", parser(now: Self.date(2026, 10, 25, hour: 1))), day(2026, 10, 26))
    }

    func testWeekdayNamesMeanTheNextOneNeverToday() {
        // 24 September 2026 is a Thursday.
        XCTAssertEqual(due("Gym fri"), day(2026, 9, 25))
        XCTAssertEqual(due("Gym friday"), day(2026, 9, 25))
        XCTAssertEqual(due("Gym saturday"), day(2026, 9, 26))
        XCTAssertEqual(due("Gym sunday"), day(2026, 9, 27))
        XCTAssertEqual(due("Gym monday"), day(2026, 9, 28))
        XCTAssertEqual(due("Gym tue"), day(2026, 9, 29))
        XCTAssertEqual(due("Gym wednesday"), day(2026, 9, 30))
        XCTAssertEqual(due("Gym thursday"), day(2026, 10, 1), "the next Thursday, not today")
        XCTAssertEqual(due("Gym thurs"), day(2026, 10, 1))
        XCTAssertEqual(due("Gym next friday"), day(2026, 9, 25))
        XCTAssertEqual(due("Gym next sat"), day(2026, 9, 26))
        XCTAssertEqual(parser().parse("Gym next friday").title, "Gym")
    }

    func testShortWeekdaysThatAreEverydayWordsStayText() {
        for text in ["Buy sun cream", "Sat exam results", "Get wed"] {
            XCTAssertNil(due(text), text)
        }
    }

    func testNextWeekIsTheNextMonday() {
        XCTAssertEqual(due("Plan next week"), day(2026, 9, 28))
        XCTAssertEqual(due("Plan next week", parser(now: Self.date(2026, 9, 28))), day(2026, 10, 5), "from a Monday")
        XCTAssertEqual(due("Plan next week", parser(now: Self.date(2026, 9, 27))), day(2026, 9, 28), "from a Sunday")
        XCTAssertEqual(parser().parse("Plan next week").title, "Plan")
    }

    // MARK: - Calendar dates

    func testMonthNamesCountOnlyWithADayNumber() {
        XCTAssertEqual(due("Taxes sep 30"), day(2026, 9, 30))
        XCTAssertEqual(due("Taxes September 30th"), day(2026, 9, 30))
        XCTAssertEqual(due("Taxes 30 sep"), day(2026, 9, 30))
        XCTAssertEqual(due("Taxes 1st oct"), day(2026, 10, 1))
        XCTAssertEqual(due("Taxes sept 30 2027"), day(2027, 9, 30))
        XCTAssertEqual(due("Taxes 30 September 2027"), day(2027, 9, 30))
        XCTAssertEqual(parser().parse("Taxes sep 30 2027").title, "Taxes")
        for text in ["Ship the may release", "March forward", "Dec the halls", "may 32 things", "jun 0"] {
            XCTAssertNil(due(text), text)
        }
        XCTAssertEqual(parser().parse("Ship the may release").title, "Ship the may release")
    }

    func testADatePassedThisYearMeansNextYear() {
        XCTAssertEqual(due("Renew jan 5"), day(2027, 1, 5))
        XCTAssertEqual(due("Renew sep 24"), day(2026, 9, 24), "today is not in the past")
        XCTAssertEqual(due("Renew sep 23"), day(2027, 9, 23))
        XCTAssertNil(due("Renew feb 30"))
        XCTAssertEqual(due("Leap feb 29"), day(2028, 2, 29), "the next year that has one")
    }

    func testNumericDatesFollowTheRegionWhenAmbiguous() {
        let us = parser(locale: "en_US")
        let uk = parser(locale: "en_GB")
        XCTAssertTrue(TaskTextParser.prefersDayFirst(locale: Locale(identifier: "en_GB")))
        XCTAssertFalse(TaskTextParser.prefersDayFirst(locale: Locale(identifier: "en_US")))
        XCTAssertEqual(due("Pay 10/11", us), day(2026, 10, 11))
        XCTAssertEqual(due("Pay 10/11", uk), day(2026, 11, 10))
        // Only one reading is valid: both regions understand it.
        XCTAssertEqual(due("Pay 30/9", us), day(2026, 9, 30))
        XCTAssertEqual(due("Pay 9/30", uk), day(2026, 9, 30))
        XCTAssertEqual(due("Pay 30/9/2027", us), day(2027, 9, 30))
        XCTAssertEqual(due("Pay 9/30/27", us), day(2027, 9, 30))
        XCTAssertEqual(due("Pay 2026-12-01"), day(2026, 12, 1))
        for text in ["Pay 13/13", "Pay 1/2/3/4", "Pay 123/4", "Pay 9/", "Pay 2026-13-01", "Pay 32/1/2026"] {
            XCTAssertNil(due(text, us), text)
        }
    }

    func testOnlyTheFirstDateIsRecognised() {
        let parsed = parser().parse("Move meeting from fri to mon")
        XCTAssertEqual(parsed.dueDay, day(2026, 9, 25))
        XCTAssertEqual(parsed.title, "Move meeting from to mon")
    }

    func testTheDayDependsOnTheInjectedTimeZone() {
        // 23:30 UTC on 24 September is already 25 September in Rome.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let instant = utc.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 23, minute: 30))!
        XCTAssertEqual(due("x today", parser(now: instant, calendar: utc)), day(2026, 9, 24))
        XCTAssertEqual(due("x today", parser(now: instant, calendar: Self.rome)), day(2026, 9, 25))
    }

    // MARK: - Ranges and titles

    func testTokensCarryTheirRangesForChips() {
        let text = "Call Ana tomorrow #family !!"
        let parsed = parser().parse(text)
        XCTAssertEqual(parsed.tokens.map { String(text[$0.range]) }, ["tomorrow", "#family", "!!"])
        XCTAssertEqual(parsed.tokens.map(\.value), [.dueDay(day(2026, 9, 25)), .tag("family"), .priority(.high)])
        XCTAssertEqual(parsed.tokens[0].utf16Range(in: text), NSRange(location: 9, length: 8))
        XCTAssertEqual(parsed.title, "Call Ana")

        let emoji = "🎉 Party sep 30"
        let emojiToken = try? XCTUnwrap(parser().parse(emoji).tokens.first)
        XCTAssertEqual(emojiToken.map { String(emoji[$0.range]) }, "sep 30")
        XCTAssertEqual(emojiToken?.utf16Range(in: emoji), NSRange(location: 9, length: 6))
    }

    func testPunctuationLeftByARemovedTokenIsTidied() {
        XCTAssertEqual(parser().parse("Call mom, tomorrow").title, "Call mom")
        XCTAssertEqual(parser().parse("Call mom tomorrow, then dad").title, "Call mom, then dad")
        XCTAssertEqual(parser().parse("tomorrow: dentist").title, "dentist")
    }

    // MARK: - Standalone due dates (agents)

    func testParseDueDayAcceptsOneWholeDatePhrase() {
        let parser = parser()
        XCTAssertEqual(parser.parseDueDay("2026-10-02"), day(2026, 10, 2))
        XCTAssertEqual(parser.parseDueDay(" tomorrow "), day(2026, 9, 25))
        XCTAssertEqual(parser.parseDueDay("next week"), day(2026, 9, 28))
        XCTAssertEqual(parser.parseDueDay("sep 30"), day(2026, 9, 30))
        XCTAssertEqual(parser.parseDueDay("in 3 days"), day(2026, 9, 27))
        for phrase in ["", "soon", "tomorrow morning", "call mom tomorrow", "2026-02-30", "may"] {
            XCTAssertNil(parser.parseDueDay(phrase), phrase)
        }
    }

    func testDueDayStorageIsFloatingAndValidated() {
        XCTAssertEqual(DueDay(rawValue: "2026-09-30")?.rawValue, "2026-09-30")
        XCTAssertNil(DueDay(rawValue: "2026-9-30"))
        XCTAssertNil(DueDay(rawValue: "2026-02-29"))
        XCTAssertNotNil(DueDay(rawValue: "2028-02-29"))
        XCTAssertTrue(day(2026, 9, 30) < day(2026, 10, 1))
        let task = TaskItem(title: "Due")
        task.dueDay = day(2026, 9, 30)
        XCTAssertEqual(task.dueDayRaw, "2026-09-30")
    }
}

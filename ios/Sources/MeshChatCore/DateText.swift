import Foundation

extension Date {
    /// When something happened or will end, short: the time on the same day as `now` ("0:32"), the day and
    /// time on any other ("11 Nov, 0:32"), so a time from an earlier day can't pass for today's.
    public func timeOrDay(now: Date = .now, calendar: Calendar = .current) -> String {
        calendar.isDate(self, inSameDayAs: now)
            ? formatted(date: .omitted, time: .shortened)
            : formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

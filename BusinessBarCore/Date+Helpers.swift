import Foundation

public extension Date {
    func relativeString() -> String {
        let now = Date()
        let interval = self.timeIntervalSince(now)
        
        if interval < 0 {
            return "passed"
        }
        
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        let days = hours / 24
        
        if days > 0 {
            return "in \(days)d"
        } else if hours > 0 {
            return "in \(hours)h"
        } else if minutes > 0 {
            return "in \(minutes)m"
        } else {
            return "now"
        }
    }
    
    // public — inherits from `public extension Date` block above
    func timeRemaining(until endDate: Date) -> String {
        let interval = endDate.timeIntervalSince(self)
        
        if interval < 0 {
            return "ended"
        }
        
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        } else {
            return "\(minutes)m"
        }
    }
}

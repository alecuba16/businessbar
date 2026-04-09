import Foundation

public extension String {
    func truncated(to maxLength: Int, trailing: String = "...") -> String {
        guard self.count > maxLength else {
            return self
        }
        
        return self.prefix(maxLength - trailing.count) + trailing
    }
    
    func stripHTML() -> String {
        guard let data = self.data(using: .utf8) else {
            return self
        }
        
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        
        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return self
        }
        
        return attributedString.string
    }
}

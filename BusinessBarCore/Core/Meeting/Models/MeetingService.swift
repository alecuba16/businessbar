import Foundation

enum MeetingService: String, CaseIterable {
    case zoom = "Zoom"
    case googleMeet = "Google Meet"
    case microsoftTeams = "Microsoft Teams"
    case webex = "Webex"
    case jitsi = "Jitsi"
    case slack = "Slack"
    case discord = "Discord"
    case skype = "Skype"
    case bluejeans = "BlueJeans"
    case gotomeeting = "GoToMeeting"
    case hangouts = "Hangouts"
    case whereby = "Whereby"
    case around = "Around"
    case meet = "Meet"
    case chime = "Amazon Chime"
    case ringcentral = "RingCentral"
    case eight_by_eight = "8x8"
    case facetime = "FaceTime"
    case phone = "Phone"
    case generic = "Meeting"
    
    var pattern: String {
        switch self {
        case .zoom:
            return "https?://[\\w.-]*zoom\\.us/[\\w/?=&-]+"
        case .googleMeet:
            return "https?://meet\\.google\\.com/[\\w-]+"
        case .microsoftTeams:
            return "https?://teams\\.microsoft\\.com/[\\w/?=&-]+"
        case .webex:
            return "https?://[\\w.-]*webex\\.com/[\\w/?=&-]+"
        case .jitsi:
            return "https?://meet\\.jit\\.si/[\\w-]+"
        case .slack:
            return "https?://[\\w.-]*slack\\.com/[\\w/?=&-]+"
        case .discord:
            return "https?://discord\\.gg/[\\w-]+"
        case .skype:
            return "https?://join\\.skype\\.com/[\\w-]+"
        case .bluejeans:
            return "https?://[\\w.-]*bluejeans\\.com/[\\w/?=&-]+"
        case .gotomeeting:
            return "https?://[\\w.-]*gotomeeting\\.com/[\\w/?=&-]+"
        case .hangouts:
            return "https?://hangouts\\.google\\.com/[\\w/?=&-]+"
        case .whereby:
            return "https?://whereby\\.com/[\\w-]+"
        case .around:
            return "https?://meet\\.around\\.co/[\\w-]+"
        case .meet:
            return "https?://meet\\.[\\w.-]+/[\\w/?=&-]+"
        case .chime:
            return "https?://chime\\.aws/[\\w-]+"
        case .ringcentral:
            return "https?://meetings\\.ringcentral\\.com/[\\w/?=&-]+"
        case .eight_by_eight:
            return "https?://8x8\\.vc/[\\w-]+"
        case .facetime:
            return "facetime://[\\w/?=&-]+"
        case .phone:
            return "tel:[\\d-+]+"
        case .generic:
            return "https?://[\\w.-]+/[\\w/?=&-]+"
        }
    }
}

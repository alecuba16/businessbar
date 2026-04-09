import SwiftUI

struct WelcomeStep: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)
            
            Text("Welcome to BusinessBar")
                .font(.largeTitle)
                .bold()
            
            Text("Your meetings, notifications, and\nfocus mode — all in one place.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button(action: onNext) {
                Text("Get Started")
                    .font(.headline)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Spacer()
        }
        .padding(40)
    }
}

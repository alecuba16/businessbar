import BusinessBarCore
import SwiftUI

struct AppPickerView: View {
    @State private var installedApps: [MonitoredApp] = []
    @State private var searchText = ""
    @State private var isLoading = true
    let onSelect: (MonitoredApp) -> Void
    
    var filteredApps: [MonitoredApp] {
        if searchText.isEmpty {
            return installedApps
        } else {
            return installedApps.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Add App to Monitor")
                .font(.headline)
            
            TextField("Search apps...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            
            if isLoading {
                ProgressView("Loading apps...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                Text("No apps found")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 80, maximum: 100))
                    ], spacing: 16) {
                        ForEach(filteredApps) { app in
                            AppIconButton(app: app) {
                                onSelect(app)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 600, height: 500)
        .task {
            await loadApps()
        }
    }
    
    private func loadApps() async {
        installedApps = await AppDiscovery.findInstalledApps()
        isLoading = false
    }
}

struct AppIconButton: View {
    let app: MonitoredApp
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: "app")
                        .resizable()
                        .frame(width: 48, height: 48)
                        .foregroundColor(.secondary)
                }
                
                Text(app.displayName)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 32)
            }
            .frame(width: 80)
        }
        .buttonStyle(.plain)
    }
}

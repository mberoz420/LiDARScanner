import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ScannerView()
                .tabItem {
                    Label("Scan", systemImage: "viewfinder")
                }
                .tag(0)

            ResultsView()
                .tabItem {
                    Label("Results", systemImage: "list.bullet")
                }
                .tag(1)

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "folder")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
    }
}

struct ResultsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                if appState.identificationResults.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("Scan an object to see identification results")
                    )
                } else {
                    ForEach(appState.identificationResults) { result in
                        IdentificationResultRow(result: result)
                    }
                }
            }
            .navigationTitle("Identification Results")
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                if appState.downloadedCADFiles.isEmpty {
                    ContentUnavailableView(
                        "No CAD Files",
                        systemImage: "cube",
                        description: Text("Downloaded CAD files will appear here")
                    )
                } else {
                    ForEach(appState.downloadedCADFiles) { file in
                        CADFileRow(file: file)
                    }
                }
            }
            .navigationTitle("CAD Library")
        }
    }
}

struct SettingsView: View {
    @AppStorage("measurementUnit") private var measurementUnit = "mm"
    @AppStorage("autoIdentify") private var autoIdentify = true
    @AppStorage("cacheCADFiles") private var cacheCADFiles = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Measurements") {
                    Picker("Unit", selection: $measurementUnit) {
                        Text("Millimeters").tag("mm")
                        Text("Inches").tag("in")
                        Text("Centimeters").tag("cm")
                    }
                }

                Section("Scanning") {
                    Toggle("Auto-identify after scan", isOn: $autoIdentify)
                }

                Section("Storage") {
                    Toggle("Cache CAD files", isOn: $cacheCADFiles)
                    Button("Clear Cache") {
                        // TODO: Implement cache clearing
                    }
                    .foregroundColor(.red)
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    Link("Privacy Policy", destination: URL(string: "https://example.com/privacy")!)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct IdentificationResultRow: View {
    let result: IdentificationResult

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(result.name)
                    .font(.headline)
                Text(result.source.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(Int(result.confidence * 100))%")
                .font(.subheadline)
                .foregroundColor(result.confidence > 0.7 ? .green : .orange)
        }
    }
}

struct CADFileRow: View {
    let file: CADFile

    var body: some View {
        NavigationLink(destination: ModelViewer(file: file)) {
            HStack {
                Image(systemName: "cube.fill")
                    .foregroundColor(.blue)
                VStack(alignment: .leading) {
                    Text(file.name)
                        .font(.headline)
                    Text(file.format.rawValue.uppercased())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}

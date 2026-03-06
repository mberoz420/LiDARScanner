import SwiftUI

/// Sheet shown after a scan finishes — lets the user pick a server project folder
/// before uploading. The selected project persists as the default for subsequent scans.
struct ProjectPickerView: View {
    let onSelect: (String) -> Void
    let onSkip: () -> Void

    @ObservedObject private var server = ScanServerManager.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var projects: [String] = []
    @State private var isLoading = true
    @State private var newProjectName = ""
    @State private var showNewProject = false
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Currently selected project badge
                if !settings.selectedProject.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.blue)
                        Text("Current: **\(settings.selectedProject)**")
                            .font(.subheadline)
                        Spacer()
                        Button("Upload Here") {
                            onSelect(settings.selectedProject)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.08))
                }

                if isLoading {
                    Spacer()
                    ProgressView("Loading projects...")
                    Spacer()
                } else {
                    List {
                        // Root (no project)
                        Button {
                            settings.selectedProject = ""
                            onSelect("")
                        } label: {
                            HStack {
                                Image(systemName: "tray")
                                    .foregroundColor(.secondary)
                                    .frame(width: 28)
                                Text("Root (no project)")
                                    .foregroundColor(.primary)
                                Spacer()
                                if settings.selectedProject.isEmpty {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }

                        // Project folders
                        ForEach(projects, id: \.self) { project in
                            Button {
                                settings.selectedProject = project
                                onSelect(project)
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(.blue)
                                        .frame(width: 28)
                                    Text(project)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if settings.selectedProject == project {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }

                        // New project button
                        Button {
                            showNewProject = true
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.plus")
                                    .foregroundColor(.green)
                                    .frame(width: 28)
                                Text("New Project...")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Save to Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { onSkip() }
                }
            }
            .alert("New Project", isPresented: $showNewProject) {
                TextField("Project name", text: $newProjectName)
                Button("Create") {
                    guard !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let name = newProjectName.trimmingCharacters(in: .whitespaces)
                    isCreating = true
                    Task {
                        let ok = await server.createProject(name: name)
                        if ok {
                            projects = await server.fetchProjects()
                            settings.selectedProject = name
                        }
                        newProjectName = ""
                        isCreating = false
                    }
                }
                Button("Cancel", role: .cancel) { newProjectName = "" }
            } message: {
                Text("Enter a name for the new project folder")
            }
            .task {
                projects = await server.fetchProjects()
                isLoading = false
            }
        }
        .presentationDetents([.medium, .large])
    }
}

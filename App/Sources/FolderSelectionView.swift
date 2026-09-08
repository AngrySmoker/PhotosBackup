import Photos
import SwiftUI
import UIKit

struct FolderSelectionView: View {
    @EnvironmentObject private var albums: PhotoAlbumStore
    @EnvironmentObject private var preferences: BackupPreferences
    @Environment(\.openURL) private var openURL
    @State private var searchText = ""

    private var filteredAlbums: [PhotoAlbum] {
        guard !searchText.isEmpty else { return albums.albums }
        return albums.albums.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if albums.authorization == .notDetermined {
                    permissionState
                } else if !albums.canRead {
                    deniedState
                } else if albums.isLoading {
                    ProgressView("Loading albums…")
                } else if albums.albums.isEmpty {
                    EmptyState(symbol: "rectangle.stack", title: "No albums found", message: "Albums from your Photos library will appear here.")
                } else {
                    albumList
                }
            }
            .background(BackupTheme.background)
            .navigationTitle("Folders")
            .searchable(text: $searchText, prompt: "Search albums")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("\(preferences.selectedAlbumIDs.count) selected")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .onAppear { albums.refresh() }
        }
    }

    private var albumList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: preferences.automaticBackup ? "arrow.triangle.2.circlepath.circle.fill" : "pause.circle.fill")
                        .foregroundStyle(preferences.automaticBackup ? .green : .orange)
                    Text(preferences.automaticBackup ? "Selected albums back up automatically" : "Automatic backup is paused")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .padding(14)
                .background((preferences.automaticBackup ? Color.green : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .padding(.bottom, 4)

                ForEach(filteredAlbums) { album in
                    AlbumSelectionRow(album: album, isSelected: preferences.selectedAlbumIDs.contains(album.id)) {
                        preferences.toggle(albumID: album.id)
                    }
                }
            }
            .padding(16)
        }
    }

    private var permissionState: some View {
        VStack(spacing: 18) {
            Spacer()
            EmptyState(symbol: "photo.on.rectangle.angled", title: "See your albums", message: "Allow photo access to choose which albums Photos Backup should protect.")
            Button("Allow Photo Access") { Task { await albums.requestAccess() } }
                .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24)
            Spacer()
        }
    }

    private var deniedState: some View {
        VStack(spacing: 18) {
            Spacer()
            EmptyState(symbol: "photo.badge.exclamationmark", title: "Photo access is off", message: "Allow access in Settings to choose albums and back up photos.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24)
            Spacer()
        }
    }
}

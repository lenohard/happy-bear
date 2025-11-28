import SwiftUI

struct AboutView: View {
    private var changelog: [AppInfo.ChangelogEntry] {
        AppInfo.changelog
    }

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("about_app_section_title", comment: "About app section title"))) {
                HStack {
                    Label(NSLocalizedString("about_version_row_label", comment: "Version label"), systemImage: "number")
                    Spacer()
                    Text(AppInfo.currentVersionDisplay)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let buildTime = AppInfo.buildTimestampDisplay {
                    HStack {
                        Label(NSLocalizedString("about_build_time_label", comment: "Build time label"), systemImage: "clock")
                        Spacer()
                        Text(buildTime)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }

                Link(destination: AppInfo.githubURL) {
                    Label(NSLocalizedString("about_github_row_label", comment: "GitHub row label"), systemImage: "link")
                }
            }

            Section(header: Text(NSLocalizedString("about_changelog_section_title", comment: "Changelog section title"))) {
                if changelog.isEmpty {
                    Text(NSLocalizedString("about_changelog_empty", comment: "Changelog empty placeholder"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(changelog) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.date)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(entry.description)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("about_navigation_title", comment: "About navigation title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}

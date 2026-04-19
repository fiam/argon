import Foundation
import Testing

@testable import Argon

@Suite("SandboxfileSettingsSnapshot")
struct SandboxfileSettingsSnapshotTests {
  @Test("focused root files are labeled as focused root")
  func focusedRootFilesUseFocusedRootSubtitle() {
    let source = SandboxfileSettingsSnapshotLoader.makeSource(
      order: 1,
      path: "/tmp/repo/Sandboxfile",
      rootPath: "/tmp/repo",
      contents: "USE os\n",
      homePath: "/Users/test"
    )

    #expect(source.title == "Sandboxfile")
    #expect(source.subtitle == "focused root")
    #expect(source.highlightPath == "sandbox.sh")
  }

  @Test("home files are abbreviated to tilde")
  func homeFilesUseTildeSubtitle() {
    let source = SandboxfileSettingsSnapshotLoader.makeSource(
      order: 2,
      path: "/Users/test/.Sandboxfile",
      rootPath: "/tmp/repo",
      contents: "USE shell\n",
      homePath: "/Users/test"
    )

    #expect(source.title == ".Sandboxfile")
    #expect(source.subtitle == "~")
    #expect(source.menuTitle == "2. .Sandboxfile - ~")
  }

  @Test("home level files are classified as user settings")
  func homeFilesAreUserSettings() {
    #expect(
      SandboxfileSettingsSnapshotLoader.isUserSource(
        path: "/Users/test/.Sandboxfile",
        homePath: "/Users/test"
      ))
    #expect(
      !SandboxfileSettingsSnapshotLoader.isUserSource(
        path: "/Users/test/projects/argon/Sandboxfile",
        homePath: "/Users/test"
      ))
  }

  @Test("nested repo files show relative parent paths")
  func nestedRepoFilesUseRelativeParentPath() {
    let subtitle = SandboxfileSettingsSnapshotLoader.subtitle(
      forParentPath: "/tmp/repo/config/sandbox",
      rootPath: "/tmp/repo",
      homePath: "/Users/test"
    )

    #expect(subtitle == "config/sandbox")
  }

  @Test("project editing uses the first project source and tracks inherited files")
  func projectLayerUsesFirstSourceForEditing() {
    let snapshot = SandboxfileSettingsSnapshot(
      rootPath: "/tmp/repo",
      initPath: "/tmp/repo/Sandboxfile",
      projectSources: [
        SandboxfileSettingsSource(
          order: 1,
          path: "/tmp/repo/Sandboxfile",
          title: "Sandboxfile",
          subtitle: "focused root",
          contents: "USE os\n"
        ),
        SandboxfileSettingsSource(
          order: 2,
          path: "/tmp/.Sandboxfile",
          title: ".Sandboxfile",
          subtitle: "..",
          contents: "USE shell\n"
        ),
      ],
      userSources: []
    )

    #expect(snapshot.editableSource(for: .project)?.path == "/tmp/repo/Sandboxfile")
    #expect(snapshot.inheritedSourceCount(for: .project) == 1)
  }

  @Test("personal editing uses the home sandboxfile when present")
  func personalLayerUsesUserSourceForEditing() {
    let snapshot = SandboxfileSettingsSnapshot(
      rootPath: "/tmp/repo",
      initPath: "/tmp/repo/Sandboxfile",
      projectSources: [],
      userSources: [
        SandboxfileSettingsSource(
          order: 1,
          path: "/Users/test/.Sandboxfile",
          title: ".Sandboxfile",
          subtitle: "~",
          contents: "USE agent\n"
        )
      ]
    )

    #expect(snapshot.editableSource(for: .personal)?.path == "/Users/test/.Sandboxfile")
    #expect(snapshot.inheritedSourceCount(for: .personal) == 0)
  }
}

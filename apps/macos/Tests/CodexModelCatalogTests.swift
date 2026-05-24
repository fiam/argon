import Testing

@testable import Argon

@Suite("CodexModelCatalog")
struct CodexModelCatalogTests {

  @Test("parses visible model slugs from the Codex catalog")
  func parsesVisibleModelSlugs() {
    let json = """
      {
        "models": [
          {
            "slug": "gpt-5.5",
            "display_name": "GPT-5.5",
            "visibility": "list"
          },
          {
            "slug": "internal-model",
            "display_name": "Internal",
            "visibility": "hidden"
          },
          {
            "slug": "gpt-5.4-mini",
            "display_name": "GPT-5.4 Mini"
          }
        ]
      }
      """

    let choices = CodexModelCatalog.parseChoices(from: json)

    #expect(choices.map(\.value) == ["gpt-5.5", "gpt-5.4-mini"])
    #expect(choices.map(\.label) == ["GPT-5.5", "GPT-5.4 Mini"])
  }

  @Test("returns no choices for invalid catalog JSON")
  func rejectsInvalidCatalogJSON() {
    #expect(CodexModelCatalog.parseChoices(from: "not json").isEmpty)
  }
}

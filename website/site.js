const repoOwner = "fiam";
const repoName = "argon";
const releasesURL = `https://github.com/${repoOwner}/${repoName}/releases/latest`;
const latestReleaseURL = `https://api.github.com/repos/${repoOwner}/${repoName}/releases/latest`;

const downloadButton = document.getElementById("download-button");
const downloadCardLink = document.getElementById("download-card-link");

function preferredAsset(assets, suffix) {
  return assets.find((asset) => asset.name.endsWith(suffix));
}

function useReleaseFallback(message) {
  downloadButton.href = releasesURL;
  downloadButton.textContent = "Download";
  downloadCardLink.href = releasesURL;
  downloadCardLink.textContent = message || "Download Argon";
}

async function loadLatestRelease() {
  try {
    const response = await fetch(latestReleaseURL, {
      headers: {
        Accept: "application/vnd.github+json"
      }
    });

    if (!response.ok) {
      throw new Error(`GitHub API returned ${response.status}`);
    }

    const release = await response.json();
    const assets = release.assets ?? [];
    const dmg = preferredAsset(assets, ".dmg");
    const zip = preferredAsset(assets, ".zip");

    if (!dmg && !zip) {
      useReleaseFallback("");
      return;
    }

    const primaryAsset = dmg ?? zip;
    const downloadText = `Download ${release.tag_name}`;
    downloadButton.href = primaryAsset.browser_download_url;
    downloadButton.textContent = downloadText;
    downloadCardLink.href = primaryAsset.browser_download_url;
    downloadCardLink.textContent = downloadText;
  } catch (error) {
    useReleaseFallback("");
  }
}

loadLatestRelease();

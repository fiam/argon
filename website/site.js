const repoOwner = "fiam";
const repoName = "argon";
const releasesURL = `https://github.com/${repoOwner}/${repoName}/releases/latest`;
const latestReleaseURL = `https://api.github.com/repos/${repoOwner}/${repoName}/releases/latest`;

const downloadButton = document.getElementById("download-button");
const downloadCardLink = document.getElementById("download-card-link");
const releaseStatus = document.getElementById("release-status");

function preferredAsset(assets, suffix) {
  return assets.find((asset) => asset.name.endsWith(suffix));
}

function useReleaseFallback(message) {
  downloadButton.href = releasesURL;
  downloadButton.textContent = "Download";
  downloadCardLink.href = releasesURL;

  if (releaseStatus) {
    releaseStatus.textContent = message;
  }
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
    downloadButton.href = primaryAsset.browser_download_url;
    downloadButton.textContent = `Download ${release.tag_name}`;
    downloadCardLink.href = primaryAsset.browser_download_url;

    const formats = [];
    if (dmg) {
      formats.push("DMG");
    }
    if (zip) {
      formats.push("ZIP");
    }

    if (releaseStatus) {
      releaseStatus.textContent = `${release.tag_name} - ${formats.join(" + ")}`;
    }
  } catch (error) {
    useReleaseFallback("");
  }
}

loadLatestRelease();

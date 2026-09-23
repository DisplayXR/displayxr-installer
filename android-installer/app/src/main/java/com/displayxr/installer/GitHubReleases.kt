package com.displayxr.installer

import org.json.JSONException
import org.json.JSONObject

data class Asset(val name: String, val url: String, val size: Long)

object GitHubReleases {

    /**
     * Resolve a pin (`v2.16.36`) to the one release asset this component installs.
     *
     * The asset name cannot be constructed from the tag — it embeds the bare
     * version, sometimes a variant token, and the extension differs per
     * component — so the release has to be read. This is the same reason
     * `install-android-bundle.sh --links` calls `gh release view` instead of
     * printing a templated URL.
     *
     * No fallback to an older release. The shell script has one, added when the
     * browser's Android asset went missing from consecutive pins; it is wrong
     * here, because quietly installing a browser other than the pinned one is
     * the exact configuration this installer refuses to produce.
     */
    fun resolve(component: Component, tag: String): Asset {
        val url = "https://api.github.com/repos/${component.repo}/releases/tags/$tag"
        val body = try {
            Net.getText(url, accept = "application/vnd.github+json")
        } catch (e: InstallerFailure.Http) {
            if (e.code == 404) throw InstallerFailure.NoSuchRelease(tag, component.repo) else throw e
        }

        val assets = try {
            JSONObject(body).getJSONArray("assets")
        } catch (e: JSONException) {
            throw InstallerFailure.Malformed("the release JSON for $tag", e.message ?: "unparseable")
        }

        for (i in 0 until assets.length()) {
            val a = assets.getJSONObject(i)
            val name = a.optString("name")
            if (name.isNotEmpty() && component.assetMatch(name)) {
                return Asset(
                    name = name,
                    url = a.optString("browser_download_url"),
                    size = a.optLong("size", -1L),
                )
            }
        }
        throw InstallerFailure.NoAndroidAsset(tag, component.repo)
    }

    /** Read versions.json — the same mirrored pin matrix every other install path uses. */
    fun readPins(): Map<String, String> {
        val body = Net.getText(Catalog.PINS_URL)
        val json = try {
            JSONObject(body)
        } catch (e: JSONException) {
            throw InstallerFailure.Malformed("versions.json", e.message ?: "unparseable")
        }
        val out = LinkedHashMap<String, String>()
        for (key in json.keys()) {
            val v = json.opt(key)
            if (v is String && !key.startsWith("$")) out[key] = v
        }
        if (out["runtime"].isNullOrBlank()) {
            throw InstallerFailure.Malformed("versions.json", "no \"runtime\" pin in it")
        }
        return out
    }
}

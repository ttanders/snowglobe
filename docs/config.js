// Snowglobe web viewer settings.
//
// googleMapsApiKey: a Google Maps Platform key with the Map Tiles API enabled, restricted to
// HTTP referrers (websites) so it only works on this site:
//   https://ttanders.github.io/snowglobe/*
// A browser key is always visible to visitors; the website restriction is what keeps it safe.
// Use a separate key from the iOS app's (which is restricted to the app's bundle ID).
//
// Leave the placeholder below in the repo. The real key is the GOOGLE_MAPS_WEB_KEY repository
// secret; .github/workflows/pages.yml swaps it in when the site is published to GitHub Pages.
window.SNOWGLOBE_CONFIG = {
    googleMapsApiKey: "PASTE_YOUR_WEB_KEY_HERE",
};

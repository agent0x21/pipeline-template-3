// Hosting supplies runtime-config.json separately from the immutable application ZIP.
// The Vite development server retains the local API default.
export async function getApiUrl(): Promise<string> {
  if (import.meta.env.DEV) return "http://localhost:5130/weatherforecast";
  const response = await fetch(`${import.meta.env.BASE_URL}runtime-config.json`, {
    cache: "no-store",
  });
  if (response.status === 404) return "/weatherforecast";
  if (!response.ok) throw new Error("Runtime configuration unavailable");
  const config: unknown = await response.json();
  if (
    typeof config !== "object" || config === null ||
    !("apiUrl" in config) || typeof config.apiUrl !== "string" ||
    !config.apiUrl.trim()
  ) throw new Error("Runtime configuration requires apiUrl");
  const url = new URL(config.apiUrl, window.location.origin);
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new Error("Invalid runtime API URL");
  }
  return url.href;
}

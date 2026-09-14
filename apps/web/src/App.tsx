import { useCallback, useEffect, useState } from "react";
import "./App.css";
import { APP_NAME } from "@repo/shared";

type Forecast = { date: string; temperatureC: number; summary: string };

const apiUrl = "http://localhost:5130/weatherforecast";

function App() {
  const [forecast, setForecast] = useState<Forecast[]>([]);
  const [status, setStatus] = useState("Connecting to the API…");
  const [loading, setLoading] = useState(true);

  const loadForecast = useCallback(async () => {
    try {
      const response = await fetch(apiUrl);
      if (!response.ok) throw new Error(`API returned ${response.status}`);
      setForecast(await response.json());
      setStatus("Connected to the API");
    } catch {
      setStatus("API unavailable — start the API with pnpm start-api");
      setForecast([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void loadForecast();
    }, 0);

    return () => window.clearTimeout(timer);
  }, [loadForecast]);

  return (
    <main className="dashboard">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark">P</span>
          <span>Pipeline</span>
        </div>
        <span className="profile">JD&nbsp; Jon C.</span>
      </header>
      <section className="content">
        <p className="eyebrow">WORKSPACE OVERVIEW</p>
        <h1>Good morning, Jon</h1>
        <p className="intro">
          Here&apos;s what&apos;s happening across your workspace today.
        </p>
        <section className="hero-card">
          <div>
            <h2>Your workspace is ready</h2>
            <p>Connect your first pipeline and keep every handoff moving.</p>
          </div>
          <span className="sparkle">✦</span>
        </section>
        <div className="section-heading">
          <h2>API connection</h2>
          <button
            onClick={() => {
              setLoading(true);
              setStatus("Connecting to the API…");
              void loadForecast();
            }}
            disabled={loading}
          >
            {loading ? "Refreshing…" : "Refresh"}
          </button>
        </div>
        <section className="api-card">
          <div
            className={
              status.startsWith("Connected") ? "status connected" : "status"
            }
          >
            {status}
          </div>
          {forecast.length > 0 ? (
            <div className="forecast-grid">
              {forecast.map((item) => (
                <article className="forecast" key={item.date}>
                  <span>{new Date(item.date).toLocaleDateString()}</span>
                  <strong>{item.temperatureC}°C</strong>
                  <small>{item.summary}</small>
                </article>
              ))}
            </div>
          ) : (
            <p className="empty">
              The dashboard is available when you are offline.
            </p>
          )}
        </section>
      </section>
      <section className="app-info-card" aria-label="Application information">
        <h3>From shared dependency: {APP_NAME}</h3>
        <p>Version: {import.meta.env.VITE_APP_VERSION ?? "development"}</p>
      </section>
    </main>
  );
}

export default App;

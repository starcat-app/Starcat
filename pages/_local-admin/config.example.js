/*
 * Starcat local admin panel config template.
 *
 * Copy this file to `config.js` in the same directory and fill in your local
 * or private Fly.io endpoints. The real `config.js` is ignored by git and
 * excluded from `pages/deploy.sh` so API keys do not ship with the public site.
 */
window.STARCAT_ADMIN_CONFIG = {
  fly: {
    // Browser requests go through the local-only proxy in server.mjs to avoid
    // Fly Machines API CORS failures.
    proxyBaseURL: "/fly-api",
    apiBaseURL: "https://api.machines.dev/v1",
    apiToken: "FlyV1 your-personal-access-token",
    apps: [
      "starcat-sharing-api",
      "starcat-trending-api",
      "starcat-weekly-api",
      "starcat-wiki-api",
      "starcat-recommend-api",
      "starcat-discovery-api"
    ]
  },
  services: {
    sharing: {
      label: "Sharing",
      baseURL: "http://127.0.0.1:5001",
      apiKey: "sk-starcat-local-api-key"
    },
    trending: {
      label: "Trending",
      baseURL: "http://127.0.0.1:5002",
      apiKey: "sk-starcat-local-api-key"
    },
    weekly: {
      label: "Weekly",
      baseURL: "http://127.0.0.1:5003",
      apiKey: "sk-starcat-local-api-key",
      adminKey: "sk-starcat-local-admin-key"
    },
    wiki: {
      label: "Wiki",
      baseURL: "http://127.0.0.1:5004",
      apiKey: "sk-starcat-local-api-key",
      adminKey: "sk-starcat-local-api-key"
    },
    recommend: {
      label: "Recommend",
      baseURL: "http://127.0.0.1:5005",
      apiKey: "sk-starcat-local-api-key"
    },
    discovery: {
      label: "Discovery",
      baseURL: "http://127.0.0.1:5006",
      apiKey: "sk-starcat-local-api-key",
      adminKey: "sk-starcat-local-admin-key"
    }
  }
};

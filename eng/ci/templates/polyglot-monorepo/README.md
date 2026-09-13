# Polyglot monorepo template

This template demonstrates independent tags for four components:

- `contracts/v<SemVer>` for shared contracts.
- `web/v<SemVer>` for the Node web client.
- `api/v<SemVer>` for the modern .NET API.
- `desktop/v<SemVer>` for a legacy .NET Framework desktop application.

Changes to `shared-contracts` also release `web` and `api` because they list it in `dependencies`. A desktop release remains independent in this example.

The legacy component omits `build.command` so the release module discovers `MSBuild.exe` through PATH or `vswhere.exe`. Replace `build.solution` and `package.path` with the real solution and output directory. If the project needs a custom restore/build sequence, use a PowerShell `build.command` instead.

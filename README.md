# Main-based monorepo release pipeline

This pnpm workspace contains a React/Vite web app, an ASP.NET Core API and a WPF desktop app. CI and release orchestration use PowerShell 7 on Windows.

**Branches are for development, tags identify artifacts, and GitHub Environments control approvals.** The only permanent branch is `main`. Work in temporary `feature/*`, `bugfix/*` or `hotfix/*` branches and merge reviewed PRs into main. Create `release/*` only for an actual stabilization line.

## Everyday workflow

1. Open a PR into main. CI validates the release engine, lints/builds web, and builds API and desktop.
2. Merge the PR. Main CI runs again. No deployable artifact is automatically published.
3. When needed, run **DEV Artifacts** from main. Select main or a full SHA reachable from main; optionally select components. Download the run artifacts for manual installation. These are not release candidates.
4. Run **Build Release Candidate** from main, selecting main or a full SHA. The source is resolved once. Default bumps are minor; per-component/exact overrides and full releases are available.
5. Copy the resulting `release/<run-id>` identifier into **Prepare QA**. Download and manually install the artifacts described in the handoff. After testing every included component, approve the waiting **QA** job.
6. Run **Promote PROD** with that release identifier and the successful Prepare QA run ID. A separate **PROD** reviewer approves publication of stable component releases. Install those artifacts manually.

QA can remain on its selected release while main advances. No workflow merges into or moves main, and no environment branches are required. QA/PROD workflows do not build or repackage applications.

## Versions and artifacts

Components retain independent versions: `api/v2.15.0-rc.1`, `web/v1.4.0-rc.1`, and so on. Stable promotion produces `api/v2.15.0` from the same commit and bytes. The original RC build version may remain embedded in the application.

A `release/<run-id>` GitHub Release groups the selected components and stores the v2 manifest, ZIPs, recoverable build bundle, and later approval records. API images live in GHCR and are identified by digest. Actions artifact expiry does not remove the durable release assets.

A release set contains the affected components, not a claim about everything currently installed in an environment. Unchanged components retain their existing installations. Shared TypeScript changes affect web; common build configuration affects all components. Use `release_all` when a complete artifact set is required.

## Production hotfix

Create a temporary branch from the production component tag or release-set SHA:

```powershell
git switch -c hotfix/2.14.4 api/v2.14.3
```

Apply the fix and push the branch. Run Build Release Candidate **from main**, setting `source_ref=hotfix/2.14.4` and `baseline_release=api/v2.14.3`. Auto bump defaults to patch for hotfixes. Follow the same separate QA and PROD approval process. Apply the fix back to main through a reviewed PR, then delete the temporary branch. No automatic cherry-picks or branch synchronization occur.

## Configuration and local validation

Use pnpm **12.3.4**, .NET 10, PowerShell 7, Git, GitHub CLI and a Windows runner. Container publication also needs Docker with a Linux-container-capable engine. CI uses Pester 5.7.1 and powershell-yaml 0.4.12. A runner label of `[self-hosted, Windows]` is required by these workflows.

```powershell
pnpm install --frozen-lockfile
pnpm test-ci
pnpm --filter ./apps/web lint
pnpm build-web
pnpm build-api
dotnet build apps/desktop -c Release
pnpm release-plan
```

Application test commands are executed when configured per component. No .NET application test projects currently exist; the Pester suite covers the pipeline.

For a built frontend, serve `runtime-config.json` beside the app with, for example:

```json
{ "apiUrl": "https://api.example.com/weatherforecast" }
```

Supply that file separately at installation; never modify the application ZIP. A missing file defaults to same-origin `/weatherforecast`; Vite development uses localhost:5130. Configure API CORS for your frontend origin when using different hosts. .NET settings remain runtime environment variables/configuration.

## Operations

- [Functional requirements document: release and versioning pipeline](eng/documentation/FUNCTIONAL-REQUIREMENTS.md) — scope, numbered requirements, lifecycle and acceptance criteria.
- [Discovery engine functional requirements](eng/documentation/DISCOVERY-REQUIREMENTS.md) — planned repository analysis and reviewed generation of `.releasepipeline.yml`; not yet implemented.
- [Release contract and workflow inputs](eng/documentation/RELEASE-STANDARD.md)
- [Cutover and GitHub settings](eng/documentation/MIGRATION.md)
- [Retry and recovery](eng/documentation/RECOVERY.md)
- [Implementation progress and resume notes](eng/documentation/ROADMAP.md)
- [PowerShell tooling and provider portability](eng/documentation/README.md)

Actual installation is manual. Environment jobs use `deployment: false`, so an approval or artifact handoff is not reported as a successful application deployment.

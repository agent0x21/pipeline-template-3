# Repository Guidelines

## Project Structure & Module Organization

This repository is a pnpm workspace. The browser client is in `apps/web` (React, TypeScript, and Vite); its source, styles, and images live under `apps/web/src`, while static files are in `apps/web/public`. The HTTP API is in `apps/api` as an ASP.NET Core project, and the Windows desktop client is in `apps/desktop` as a WPF project. Reusable TypeScript code belongs in `packages/shared/src`. Keep generated output such as `apps/web/dist` out of source changes.

## Project Tracking

Read [`eng/ci/ROADMAP.md`](eng/ci/ROADMAP.md) before making CI/CD changes. Keep its checkboxes and “Current focus” section aligned with the implementation, and treat `prompt/main-prompt.md` as the complete product requirements source.

Use `main` as the only permanent branch. DEV and RC artifacts are manually requested; QA and PROD promote a persisted release identity without rebuilding or moving branches. Installation remains manual. Keep roadmap validation/resume notes current, and do not apply live governance settings or delete historical branches/releases as an incidental code change.

## Build, Test, and Development Commands

Use pnpm 12.3.4, as declared in the root `package.json`.

- `pnpm dev-web` — start the Vite development server.
- `pnpm build-web` — type-check and create the production web bundle.
- `pnpm serve-web` — serve the built web bundle locally.
- `pnpm start-api` — run the API with its HTTP launch profile.
- `pnpm build-api` — compile the API project.
- `pnpm build` — build both the web client and API.
- `pnpm --filter ./apps/web lint` — run ESLint for the web app.

Run `pnpm install` after changing workspace dependencies. Build the web app and API before opening a pull request.

## Coding Style & Naming Conventions

Use two-space indentation in JSON, YAML, and frontend code, semicolons in TypeScript, and the existing ESLint/TypeScript configuration as the source of truth. Use `PascalCase` for React components and C# types, `camelCase` for variables and functions, and descriptive kebab-free filenames consistent with nearby files. Put shared contracts and helpers in `packages/shared` instead of duplicating them across apps.

## Testing Guidelines

The release engine uses Pester 5.7.1 (`pnpm test-ci`). Application test projects are not currently configured. For new behavior, add focused tests in the relevant app/package and document their command. Verify affected applications with builds, lint and manual smoke checks.

## Commit & Pull Request Guidelines

Recent commits use short, imperative summaries (for example, `Add initial CI/CD pipeline architecture and configuration files`). Follow that style, keep commits focused, and explain any deployment or configuration impact. Pull requests should include a concise summary, validation commands and results, linked issue or task when applicable, and screenshots or a short recording for visible web or desktop changes. Call out required environment variables or migration steps explicitly.

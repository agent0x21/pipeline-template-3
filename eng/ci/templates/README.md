# Adoption templates

Copy the appropriate .releasepipeline.yml to your repository root and adjust paths and commands. Keep main as the sole permanent branch and use explicit RC creation instead of branch channels.

- single-application: one independently versioned component.
- polyglot-monorepo: shared contracts, web, API and a legacy Windows application.

Adopt the workflows and PowerShell tooling together. Configure Windows runners, DEV/QA/PROD and separate QA/PROD reviewers following [migration](../MIGRATION.md). The examples contain build/test commands for illustrative projects; replace them with commands that exist in your repository. No package manager other than pnpm is needed for JavaScript.

GitHub provider storage and approvals are described in [the release standard](../RELEASE-STANDARD.md).

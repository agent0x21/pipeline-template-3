# Polyglot monorepo

Copy .releasepipeline.yml to the repository root and replace example paths. Components version independently. Shared-contract changes propagate to web and API; legacy desktop uses Windows/MSBuild.

Use main for integration and temporary branches for work. Select an RC source explicitly, preserve the manifest and promote its bytes after QA/PROD approval. No environment branches or source synchronization are required. Follow [adoption instructions](../README.md).

# Single application

Copy .releasepipeline.yml to the repository root. Adjust apps/app and build/test/package paths. RC tags are app/v<version>-rc.N; stable promotion reuses the exact ZIP as app/v<version>.

Use main for integration, manual DEV/RC artifact creation, QA sign-off and separate PROD approval. Installation remains manual. Follow [adoption instructions](../README.md).

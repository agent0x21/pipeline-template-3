# API container

Build and smoke-test the API container locally:

```powershell
pnpm test-container-api
```

The command builds `apps/api/Dockerfile`, starts it on `http://127.0.0.1:8088`, verifies `/weatherforecast`, and removes the test container. Use `-HostPort` when port 8088 is already in use:

```powershell
pwsh ./eng/ci/Test-ApiContainer.ps1 -HostPort 18088
```

Release builds save the same versioned image as an immutable `*.container.tar` artifact and publish it to `ghcr.io/agent0x21/pipeline-template-3-api` after the registry approval. Pull a published image with:

```powershell
docker pull ghcr.io/agent0x21/pipeline-template-3-api:<version>
docker run --rm -p 8088:8080 -e ASPNETCORE_URLS=http://+:8080 ghcr.io/agent0x21/pipeline-template-3-api:<version>
```

# Single-application template

This template makes the repository behave as one independently versioned component. A release on `dev` produces `app/v<version>-beta.<n>`, promotion produces an RC tag, and promotion from RC produces a stable `app/v<version>` tag.

Change `app` and `tagPrefix` only before the first release. Changing a tag prefix after tags exist creates a separate version history.

For a modern .NET application, replace the build and package sections with:

```yaml
type: modern-dotnet
build:
  command: dotnet publish ./apps/app/App.csproj -c Release -o .release-output/app
package:
  path: .release-output/app
```

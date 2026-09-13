FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY . .
ARG DOTNET_Version
ARG DOTNET_VersionPrefix
ARG DOTNET_VersionSuffix
ARG DOTNET_AssemblyVersion
ARG DOTNET_FileVersion
ARG DOTNET_InformationalVersion
RUN dotnet publish apps/api/DotNetWebAPI.Api.csproj -c Release -o /publish \
    -p:Version="$DOTNET_Version" -p:VersionPrefix="$DOTNET_VersionPrefix" \
    -p:VersionSuffix="$DOTNET_VersionSuffix" -p:AssemblyVersion="$DOTNET_AssemblyVersion" \
    -p:FileVersion="$DOTNET_FileVersion" -p:InformationalVersion="$DOTNET_InformationalVersion" \
    -p:IncludeSourceRevisionInInformationalVersion=false
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /publish .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "DotNetWebAPI.Api.dll"]

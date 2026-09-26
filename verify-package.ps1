#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Consumes a packed .nupkg from a folder feed once per lib/<tfm> asset it ships.

.DESCRIPTION
    Generates a throwaway consumer project outside the repository, because the packaging
    project sits at the repository root and globs **/*.cs, so an in-tree test source file
    would be swept into it.

    Fails when a lib asset is missing, when the consumer resolves a different file than the
    one in the package, or when the assembly does not load and work at runtime.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $PackagePath,

    # The lib/<tfm> folders the package must ship. Without this the script would test
    # whatever it happens to find and pass a package that quietly lost an asset.
    [Parameter(Mandatory)]
    [string[]] $ExpectedTargetFrameworks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
Write-Host "package: $PackagePath"

function Get-StreamSha256 {
    param([IO.Stream] $Stream)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha.ComputeHash($Stream)).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

# Read the package: id, version, and the sha256 of every lib/<tfm>/*.dll it carries.
$zip = [IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
    $nuspecEntries = @($zip.Entries | Where-Object { $_.FullName -like '*.nuspec' -and $_.FullName -notlike '*/*' })
    if ($nuspecEntries.Count -ne 1) {
        throw "Expected exactly 1 root .nuspec, found $($nuspecEntries.Count)."
    }

    $stream = $nuspecEntries[0].Open()
    try {
        $reader = New-Object IO.StreamReader($stream)
        try { $nuspec = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }

    $packageId = $nuspec.package.metadata.id
    $packageVersion = $nuspec.package.metadata.version

    $libAssets = @{}
    foreach ($entry in @($zip.Entries | Where-Object { $_.FullName -like 'lib/*/*.dll' })) {
        $tfm = $entry.FullName.Split('/')[1]
        $stream = $entry.Open()
        try { $hash = Get-StreamSha256 -Stream $stream } finally { $stream.Dispose() }

        if (-not $libAssets.ContainsKey($tfm)) { $libAssets[$tfm] = @{} }
        $libAssets[$tfm][[IO.Path]::GetFileName($entry.FullName)] = $hash
    }
}
finally { $zip.Dispose() }

$tfms = @($libAssets.Keys | Sort-Object)
$expected = @($ExpectedTargetFrameworks | Sort-Object)
$differences = @(Compare-Object -ReferenceObject $expected -DifferenceObject $tfms)
if ($differences.Count -ne 0) {
    throw "Package $packageId $packageVersion ships lib folders [$($tfms -join ', ')], expected [$($expected -join ', ')]."
}

Write-Host "id: $packageId  version: $packageVersion"
Write-Host "lib assets:"
foreach ($tfm in $tfms) {
    foreach ($file in @($libAssets[$tfm].Keys | Sort-Object)) {
        Write-Host ("  lib/{0}/{1}  {2}" -f $tfm, $file, $libAssets[$tfm][$file])
    }
}

# Generate the consumer outside the repository.
$workDir = Join-Path ([IO.Path]::GetTempPath()) ("pkgverify-" + [Guid]::NewGuid().ToString('n'))
$feedDir = Join-Path $workDir 'feed'
New-Item -ItemType Directory -Path $feedDir -Force | Out-Null
Copy-Item -LiteralPath $PackagePath -Destination $feedDir
Write-Host "consumer: $workDir"

$nugetConfig = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="package-under-test" value="feed" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
'@

$consumerProject = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFrameworks>$($tfms -join ';')</TargetFrameworks>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="$packageId" Version="[$packageVersion]" />
  </ItemGroup>
</Project>
"@

$consumerProgram = @'
using System.Collections.Immutable;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Dynamics.Nav.CodeAnalysis.Packaging;

var failures = new List<string>();

Console.WriteLine($"runtime         : {RuntimeInformation.FrameworkDescription}");

var asm = typeof(NavAppPackageReader).Assembly;
Console.WriteLine($"assembly        : {asm.GetName().Name} {asm.GetName().Version}");
Console.WriteLine($"location        : {asm.Location}");
Console.WriteLine($"sha256          : {Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(asm.Location))).ToLowerInvariant()}");
Console.WriteLine($"writer type     : {typeof(NavAppPackageWriter).FullName}");

// System.Collections.Immutable has to resolve: from the declared package on net8.0, from the
// shared framework on net10.0 where SDK pruning drops the dependency.
var immutable = typeof(ImmutableArray<int>).Assembly.GetName();
Console.WriteLine($"immutable       : {immutable.Name} {immutable.Version}");

var immutableProps = typeof(NavAppManifest)
    .GetProperties(BindingFlags.Public | BindingFlags.Instance)
    .Count(p => p.PropertyType.FullName!.Contains("Immutable", StringComparison.Ordinal));
Console.WriteLine($"manifest props  : {immutableProps} immutable-typed");
if (immutableProps == 0)
{
    failures.Add("NavAppManifest exposes no immutable-typed property, so nothing forced System.Collections.Immutable to load.");
}

// System.IO.Packaging has to resolve: junk bytes must reach the OPC layer and be rejected
// there, rather than failing earlier because an assembly was missing.
try
{
    using var junk = new MemoryStream(new byte[] { 0, 1, 2, 3 });
    using var reader = NavAppPackageReader.Create(junk);
    failures.Add("NavAppPackageReader.Create accepted 4 junk bytes, expected it to throw.");
}
catch (Exception ex) when (ex is FileNotFoundException or FileLoadException or TypeLoadException or BadImageFormatException)
{
    failures.Add($"NavAppPackageReader.Create failed to resolve a dependency: {ex.GetType().Name}: {ex.Message}");
}
catch (Exception ex)
{
    Console.WriteLine($"reader rejected : {ex.GetType().Name}");
}

foreach (var failure in failures)
{
    Console.Error.WriteLine($"FAIL: {failure}");
}

if (failures.Count > 0)
{
    return 1;
}

Console.WriteLine("PASS");
return 0;
'@

[IO.File]::WriteAllText((Join-Path $workDir 'nuget.config'), $nugetConfig)
[IO.File]::WriteAllText((Join-Path $workDir 'Consumer.csproj'), $consumerProject)
[IO.File]::WriteAllText((Join-Path $workDir 'Program.cs'), $consumerProgram)

# A private packages folder, or the global cache would serve an earlier extraction of the
# same id and version instead of the file under test.
$previousNuGetPackages = $env:NUGET_PACKAGES
$env:NUGET_PACKAGES = Join-Path $workDir 'packages'

Push-Location $workDir
try {
    dotnet restore
    if ($LASTEXITCODE -ne 0) { throw "Consumer restore failed with exit code $LASTEXITCODE." }

    foreach ($tfm in $tfms) {
        Write-Host "======== $tfm ========"

        $output = @(dotnet run --framework $tfm)
        $runExitCode = $LASTEXITCODE
        $output | ForEach-Object { Write-Host $_ }
        if ($runExitCode -ne 0) { throw "Consumer run on $tfm failed with exit code $runExitCode." }

        # The consumer must have resolved this TFM's own asset, not another TFM's.
        $resolvedLine = @($output | Where-Object { $_ -match '^sha256\s+:\s+(?<hash>[0-9a-f]{64})$' })
        if ($resolvedLine.Count -ne 1) {
            throw "Expected exactly 1 sha256 line from the $tfm run, found $($resolvedLine.Count)."
        }
        $resolvedHash = [regex]::Match($resolvedLine[0], '^sha256\s+:\s+(?<hash>[0-9a-f]{64})$').Groups['hash'].Value

        $expectedHashes = @($libAssets[$tfm].Values)
        if ($expectedHashes -notcontains $resolvedHash) {
            throw "On $tfm the consumer resolved $resolvedHash, which is not any lib/$tfm asset ($($expectedHashes -join ', '))."
        }
        Write-Host "matches lib/$tfm asset: $resolvedHash"
    }
}
finally {
    Pop-Location
    $env:NUGET_PACKAGES = $previousNuGetPackages
}

Write-Host ""
Write-Host "$packageId $packageVersion verified on $($tfms.Count) framework(s): $($tfms -join ', ')"

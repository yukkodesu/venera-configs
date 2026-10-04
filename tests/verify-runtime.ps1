param(
    [string]$VeneraRoot = (Join-Path $PSScriptRoot '../../venera'),
    [string]$QjsDll
)
$ErrorActionPreference = 'Stop'
$VeneraRoot = (Resolve-Path -LiteralPath $VeneraRoot).Path
$runtimeDirectory = Join-Path $PSScriptRoot '.runtime'
New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
$packageConfigPath = Join-Path $VeneraRoot '.dart_tool/package_config.json'
if (!(Test-Path -LiteralPath $packageConfigPath)) {
    throw 'Run flutter pub get in the Venera checkout first.'
}

# Use the app's HTML bridge and DocumentWrapper verbatim, rather than a DOM substitute.
$engineSource = Get-Content -LiteralPath (Join-Path $VeneraRoot 'lib/foundation/js_engine.dart') -Raw
$bridgeStart = $engineSource.IndexOf('  final _documents =')
$bridgeEnd = $engineSource.IndexOf('  dynamic handleCookieCallback')
$wrapperStart = $engineSource.IndexOf('class DocumentWrapper')
$wrapperEnd = $engineSource.IndexOf('class JSAutoFreeFunction')
if ($bridgeStart -lt 0 -or $bridgeEnd -le $bridgeStart -or $wrapperStart -lt 0 -or $wrapperEnd -le $wrapperStart) {
    throw 'The Venera HTML bridge layout changed; update the test extraction boundaries.'
}
$generatedBridge = "import 'package:html/parser.dart' as html;`nimport 'package:html/dom.dart' as dom;`nclass Log { static void warning(String title, String message) {} }`nclass HtmlBridge {`n" +
    $engineSource.Substring($bridgeStart, $bridgeEnd - $bridgeStart) +
    "int get activeDocuments => _documents.length;`n}`n" +
    $engineSource.Substring($wrapperStart, $wrapperEnd - $wrapperStart)
[IO.File]::WriteAllText((Join-Path $runtimeDirectory 'html_bridge.dart'), $generatedBridge)

if (!$QjsDll) {
    # Compile the exact flutter_qjs dependency resolved by Venera.
    $packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
    $qjsPackage = $packageConfig.packages | Where-Object { $_.name -eq 'flutter_qjs' }
    $qjsRoot = ([Uri]::new([Uri]::new($packageConfigPath), $qjsPackage.rootUri)).LocalPath
    $cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmakeCommand) {
        $cmakePath = $cmakeCommand.Source
    } else {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        $vsRoot = & $vswhere -latest -property installationPath
        $cmakePath = Join-Path $vsRoot 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    }
    $nativeDirectory = Join-Path $runtimeDirectory 'native'
    & $cmakePath -S (Join-Path $qjsRoot 'test') -B $nativeDirectory -A x64
    if ($LASTEXITCODE -ne 0) { throw 'QuickJS configuration failed.' }
    & $cmakePath --build $nativeDirectory --config Release
    if ($LASTEXITCODE -ne 0) { throw 'QuickJS build failed.' }
    $QjsDll = Join-Path $nativeDirectory 'Release/ffiquickjs.dll'
}
Copy-Item -LiteralPath $QjsDll -Destination (Join-Path $runtimeDirectory 'flutter_qjs_plugin.dll') -Force
$previousPath = $env:PATH
try {
    $env:PATH = "$runtimeDirectory;$previousPath"
    & dart "--packages=$packageConfigPath" (Join-Path $PSScriptRoot 'wnacg.runtime.dart') $VeneraRoot @args
    if ($LASTEXITCODE -ne 0) { throw 'Venera runtime regression tests failed.' }
} finally {
    $env:PATH = $previousPath
}

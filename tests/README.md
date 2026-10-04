# Wnacg regression checks

The manga source runs in Venera's QuickJS host. Node is only used for the fast
fixture tests; those use linkedom and are not a host compatibility check.

## Native host verification (Windows)

Prepare the Venera checkout with `flutter pub get`. Run from venera-configs:

```powershell
./tests/verify-runtime.ps1 -VeneraRoot D:/Code/venera
./tests/verify-runtime.ps1 -VeneraRoot D:/Code/venera --live
```

This builds the flutter_qjs version resolved by Venera (requires Visual Studio
C++ tools and CMake), loads the real `assets/init.js`, and uses the app's
`handleHtmlCallback` and `DocumentWrapper` code verbatim with Dart `package:html`.
Only settings and HTTP responses are supplied by the harness. It checks chapter
Map conversion across QuickJS/Dart, directory pagination/order, image requests,
ordinary albums, thumbnails, and document disposal after errors.

`--live` additionally verifies the two reported albums and the two child albums
against wnacg.com. These optional checks depend on the website remaining available
and retaining the reported chapter/image counts. It does not exercise the app UI.

Generated bridge code and native build outputs stay in ignored `tests/.runtime/`.
Use `-QjsDll path/to/ffiquickjs.dll` to reuse a library built from the same dependency.

## Fast fixture tests

```powershell
npm --prefix tests ci
npm --prefix tests test
```

The real `ComicDetails` constructor is loaded from the sibling Venera checkout.
Set `VENERA_ROOT` when that checkout lives elsewhere.

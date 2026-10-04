import 'dart:convert';
import 'dart:io';
import 'package:flutter_qjs/flutter_qjs.dart';
import '.runtime/html_bridge.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String info(bool series, String directory) => '''
<div class="userwrap"><h2>Fixture comic</h2><div class="asTB">
<div class="asTBcell uwthumb"><img src="////covers.example/cover.jpg"></div>
<div class="asTBcell uwconn"><label>分類：同人誌／漢化</label>
<label>${series ? '章節：2 話' : '頁數：187P'}</label>
<a class="tagshow">Fixture tag</a><p>Fixture description</p></div>
<div class="asTBcell uwuinfo"><a><p>Fixture uploader</p></a></div>
</div></div>${series ? '<div id="sr_pub"></div>' : ''}$directory''';
String chapter(String id, String title) =>
    '<a class="tagshow" data-chid="$id" href="/photos-slide-aid-$id-sid-390990.html">$title</a>';
String indexUrl(String id, [int page = 1]) =>
    'https://www.wnacg.com/photos-index-page-$page-aid-$id.html?order=asc&mode=list';
String galleryUrl(String id) => 'https://www.wnacg.com/photos-gallery-aid-$id.html';

Future<void> main(List<String> args) async {
  final veneraRoot = args.first;
  final configsRoot = File.fromUri(Platform.script).parent.parent.path;
  final bridge = HtmlBridge();
  final requests = <String>[];
  final paginator = '<div class="f_left paginator"><span class="thispage">1</span></div>';
  final responses = <String, Map<String, dynamic>>{};
  void respond(String url, String body, [int status = 200]) {
    responses[url] = {'status': status, 'body': body, 'headers': <String, String>{}};
  }
  respond(indexUrl('390990'), info(true,
      chapter('379953', '第1話') + '<div class="f_left paginator"><a href="/photos-index-page-2-aid-390990.html">2</a></div>'));
  respond(indexUrl('390990', 2), chapter('279843', '第2話') + paginator);
  respond(indexUrl('390889'), info(false, paginator));
  respond('https://www.wnacg.com/photos-index-page-1-aid-390990.html', info(true, ''));
  for (final id in ['279843', '379953', '390889']) {
    respond(galleryUrl(id), r'document.writeln("var imglist = [{url: \"//images.example/' + id + r'/1.jpg\"}];");');
  }
  final qjs = FlutterQjs();
  qjs.dispatch();
  try {
    Object? receive(dynamic raw) {
      final message = Map<String, dynamic>.from(raw as Map);
      switch (message['method']) {
        case 'html':
          return bridge.handleHtmlCallback(message);
        case 'load_setting':
          return message['setting_key'] == 'domain0' ? 'www.wnacg.com' : '0';
        case 'http':
          final url = message['url'] as String;
          requests.add(url);
          check(responses.containsKey(url), 'Unexpected request: $url');
          return Future.value(responses[url]);
        default:
          throw StateError('Unexpected host API: ${message['method']}');
      }
    }
    final setGlobal = qjs.evaluate('(key, value) => { this[key] = value; }') as JSInvokable;
    setGlobal(['sendMessage', receive]);
    setGlobal(['appVersion', '1.6.3']);
    setGlobal.free();
    qjs.evaluate(File('$veneraRoot/assets/init.js').readAsStringSync(), name: '<venera-init>');
    qjs.evaluate('${File('$configsRoot/wnacg.js').readAsStringSync()}\nvar source = new Wnacg();');

    final series = await qjs.evaluate("source.comic.loadInfo('390990')") as Map;
    final chapters = series['chapters'] as Map;
    check(chapters.keys.join(',') == '379953,279843', 'Chapter IDs/order lost in QuickJS -> Dart conversion');
    check(chapters.values.join(',') == '第1話,第2話', 'Chapter titles lost');
    check((series['tags']['標籤'] as List).join(',') == 'Fixture tag', 'Chapter links leaked into tags');
    check(!series.containsKey('pages'), 'ComicDetails must use the real constructor');
    check(bridge.activeDocuments == 0, 'HTML documents leaked');
    print('PASS: Dart HTML parsing, paginated chapters, Map conversion, tags, disposal');

    for (final id in chapters.keys) {
      final result = await qjs.evaluate("source.comic.loadEp('390990', '$id')") as Map;
      check((result['images'] as List).single == 'https://images.example/$id/1.jpg', 'Wrong chapter image');
      check(requests.last == galleryUrl(id), 'Wrong chapter request');
    }
    final old = await qjs.evaluate("source.comic.loadInfo('390889')") as Map;
    check(old['chapters'] == null, 'Ordinary album gained chapters');
    check((old['tags']['頁數'] as List).single == '187P', 'Ordinary page count changed');
    await qjs.evaluate("source.comic.loadEp('390889', null)");
    check(requests.last == galleryUrl('390889'), 'Ordinary album request changed');
    final thumbs = await qjs.evaluate("source.comic.loadThumbnails('390990', null)") as Map;
    check((thumbs['thumbnails'] as List).isEmpty && thumbs['next'] == null, 'Collection thumbnails did not stop');
    check(bridge.activeDocuments == 0, 'HTML documents leaked');
    print('PASS: chapter images, ordinary albums and collection thumbnails in native QuickJS');

    respond(indexUrl('390990', 2), '', 503);
    var failed = false;
    try { await qjs.evaluate("source.comic.loadInfo('390990')"); } catch (_) { failed = true; }
    check(failed && bridge.activeDocuments == 0, 'Failed pagination returned partial data or leaked DOM');
    print('PASS: failed chapter pagination propagates error and releases DOM');

    if (args.contains('--live')) {
      final client = HttpClient();
      try {
        for (final id in ['390889', '390990']) {
          final url = indexUrl(id);
          final response = await (await client.getUrl(Uri.parse(url))).close();
          respond(url, await utf8.decodeStream(response), response.statusCode);
        }
        final live = await qjs.evaluate("source.comic.loadInfo('390990')") as Map;
        final liveChapters = live['chapters'] as Map;
        check(liveChapters.keys.join(',') == '279843,379953', 'Live directory differs from reported chapters');
        for (final entry in {'390889': 187, '279843': 263, '379953': 82}.entries) {
          final url = galleryUrl(entry.key);
          final response = await (await client.getUrl(Uri.parse(url))).close();
          respond(url, await utf8.decodeStream(response), response.statusCode);
          final ep = entry.key == '390889' ? 'null' : "'${entry.key}'";
          final comic = entry.key == '390889' ? '390889' : '390990';
          final result = await qjs.evaluate("source.comic.loadEp('$comic', $ep)") as Map;
          check((result['images'] as List).length == entry.value, 'Unexpected live image count for ${entry.key}');
          print('PASS: live ${entry.key} has ${entry.value} images');
        }
        await qjs.evaluate("source.comic.loadInfo('390889')");
        check(bridge.activeDocuments == 0, 'Live parsing leaked DOM');
      } finally { client.close(force: true); }
    }
  } finally { qjs.port.close(); qjs.close(); }
}

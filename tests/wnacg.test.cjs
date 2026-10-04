const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');
const {parseHTML} = require('linkedom');

// Minimal HTML fixtures preserving the structure of the two reported pages.
function info(series, directory = '') {
    return `<div class="userwrap"><h2>Fixture comic</h2><div class="asTB">
      <div class="asTBcell uwthumb"><img src="////covers.example/cover.jpg"></div>
      <div class="asTBcell uwconn"><label>分類：同人誌／漢化${series ? '／合集' : ''}</label>
      <label>${series ? '章節：2 話' : '頁數：187P'}</label>
      <a class="tagshow">Fixture tag</a><p>Fixture description</p></div>
      <div class="asTBcell uwuinfo"><a><p>Fixture uploader</p></a></div>
      </div></div>${series ? '<div id="sr_pub" data-order="asc" data-mode="list"></div>' : ''}${directory}`;
}
const chapter = (id, title) => `<a class="tagshow" data-chid="${id}"
    href="/photos-slide-aid-${id}-sid-390990.html">${title}</a>`;
const paginator = '<div class="f_left paginator"><span class="thispage">1</span></div>';
const series = info(true, chapter('279843', '第1話') + chapter('379953', '第2話') + paginator);
const single = info(false, '<div class="pic_box tb"><a><img src="//covers.example/page1.jpg"></a></div>' + paginator);
const indexUrl = (id, page = 1) => `https://www.wnacg.com/photos-index-page-${page}-aid-${id}.html?order=asc&mode=list`;
const galleryUrl = id => `https://www.wnacg.com/photos-gallery-aid-${id}.html`;
const gallery = id => `document.writeln("var imglist = [{url: \\\"//images.example/${id}/1.jpg\\\"}];");`;

function harness(responses) {
    let activeDocuments = 0;
    const requests = [];
    class HtmlElement {
        constructor(node) { this.node = node; }
        get text() { return this.node.textContent; }
        get attributes() { return Object.fromEntries(Array.from(this.node.attributes, a => [a.name, a.value])); }
        get children() { return Array.from(this.node.children, n => new HtmlElement(n)); }
        get classNames() { return Array.from(this.node.classList); }
        querySelector(selector) {
            const node = this.node.querySelector(selector);
            return node ? new HtmlElement(node) : null;
        }
        querySelectorAll(selector) { return Array.from(this.node.querySelectorAll(selector), n => new HtmlElement(n)); }
    }
    class HtmlDocument extends HtmlElement {
        constructor(html) { super(parseHTML(html).document); activeDocuments++; }
        dispose() { assert.equal(this.disposed, undefined); this.disposed = true; activeDocuments--; }
    }
    const context = vm.createContext({
        ComicSource: class { loadSetting(key) { return key === 'domain0' ? 'www.wnacg.com' : '0'; } },
        HtmlDocument,
        Network: {get: async url => {
            requests.push(url);
            assert.ok(Object.hasOwn(responses, url), `Unexpected request: ${url}`);
            const response = responses[url];
            return typeof response === 'string' ? {status: 200, body: response} : response;
        }},
    });
    const veneraRoot = process.env.VENERA_ROOT || path.resolve(__dirname, '../../venera');
    const runtime = fs.readFileSync(path.join(veneraRoot, 'assets/init.js'), 'utf8');
    const detailsStart = runtime.indexOf('function ComicDetails(');
    const detailsEnd = runtime.indexOf('\n}', detailsStart) + 2;
    vm.runInContext(runtime.slice(detailsStart, detailsEnd), context);
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../wnacg.js'), 'utf8') + '\nthis.source = new Wnacg();', context);
    return {comic: context.source.comic, requests, activeDocuments: () => activeDocuments};
}

test('collection exposes selectable chapters and keeps chapter links out of tags', async () => {
    const h = harness({[indexUrl('390990')]: series});
    const result = await h.comic.loadInfo('390990');
    assert.deepEqual(Array.from(result.chapters, entry => Array.from(entry)), [['279843', '第1話'], ['379953', '第2話']]);
    assert.equal(result.pages, undefined);
    assert.deepEqual(Array.from(result.tags.get('章節')), ['2 話']);
    assert.deepEqual(Array.from(result.tags.get('標籤')), ['Fixture tag']);
    assert.equal(result.tags.has('頁數'), false);
    assert.equal(h.activeDocuments(), 0);
});

test('chapter directory includes later pages, preserving website order and deduplicating IDs', async () => {
    const first = info(true, chapter('379953', '第1話') + '<div class="f_left paginator"><a href="/photos-index-page-2-aid-390990.html">2</a></div>');
    const second = chapter('379953', '第1話') + chapter('279843', '第2話') + paginator;
    const h = harness({[indexUrl('390990')]: first, [indexUrl('390990', 2)]: second});
    const result = await h.comic.loadInfo('390990');
    assert.deepEqual(Array.from(result.chapters.keys()), ['379953', '279843']);
    assert.equal(h.requests.length, 2);
    assert.equal(h.activeDocuments(), 0);
});

test('chapter image requests use the selected chapter ID', async () => {
    const h = harness({[galleryUrl('279843')]: gallery('279843'), [galleryUrl('379953')]: gallery('379953')});
    for (const id of ['279843', '379953']) {
        const result = await h.comic.loadEp('390990', id);
        assert.deepEqual(Array.from(result.images), [`https://images.example/${id}/1.jpg`]);
    }
});

test('ordinary albums retain their metadata and image requests', async () => {
    const h = harness({[indexUrl('390889')]: single, [galleryUrl('390889')]: gallery('390889')});
    const result = await h.comic.loadInfo('390889');
    assert.equal(result.chapters, undefined);
    assert.equal(result.pages, undefined); // The real ComicDetails constructor has no pages field.
    assert.deepEqual(Array.from(result.tags.get('頁數')), ['187P']);
    const images = await h.comic.loadEp('390889', null);
    assert.equal(images.images[0], 'https://images.example/390889/1.jpg');
    assert.equal(h.activeDocuments(), 0);
});

test('collection thumbnails stop cleanly; ordinary thumbnails still load', async () => {
    const h = harness({
        'https://www.wnacg.com/photos-index-page-1-aid-390990.html': series,
        'https://www.wnacg.com/photos-index-page-1-aid-390889.html': single,
    });
    const collection = await h.comic.loadThumbnails('390990', null);
    assert.equal(collection.thumbnails.length, 0);
    assert.equal(collection.next, null);
    const album = await h.comic.loadThumbnails('390889', null);
    assert.equal(album.thumbnails[0], 'https://covers.example/page1.jpg');
    assert.equal(album.next, null);
    assert.equal(h.activeDocuments(), 0);
});

test('failed later directory pages report failure instead of returning incomplete chapters', async () => {
    const first = info(true, chapter('279843', '第1話') + '<div class="f_left paginator"><a href="/photos-index-page-2-aid-390990.html">2</a></div>');
    const h = harness({[indexUrl('390990')]: first, [indexUrl('390990', 2)]: {status: 503}});
    await assert.rejects(h.comic.loadInfo('390990'), error => error === 'Invalid Status Code 503');
    assert.equal(h.activeDocuments(), 0);
});

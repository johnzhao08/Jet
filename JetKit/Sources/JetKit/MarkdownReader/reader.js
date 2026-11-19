/* Only locally bundled scripts execute. Markdown's raw HTML stays disabled. */
const md = markdownit({ linkify: true, html: false }).use(markdownitFootnote).use(markdownitMark);
const escape = md.utils.escapeHtml;
const bridge = (action, value) => window.webkit.messageHandlers.note.postMessage({action, value});
const scripts = new Map();
function loadScript(file) {
  if (!scripts.has(file)) scripts.set(file, new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = file; script.onload = resolve; script.onerror = reject;
    document.head.append(script);
  }));
  return scripts.get(file);
}
md.renderer.rules.fence = (tokens, i) => {
  const token = tokens[i], lang = token.info.trim().split(/\s/)[0].toLowerCase();
  if (lang === 'mermaid' || lang === 'math') return '<div data-render="' + lang + '">' + escape(token.content) + '</div>';
  const html = lang && hljs.getLanguage(lang) ? hljs.highlight(token.content, {language: lang}).value : escape(token.content);
  return '<pre><code>' + html + '</code></pre>';
};
md.renderer.rules.text = (tokens, i) => {
  const text = tokens[i].content;
  const pattern = /(!?)\[\[([^\]\n]+)\]\]|(\$)(?!\s)([^$\n]+?)\$|(^|\s)#([\p{L}\p{N}_/-]+)/gu;
  let html = '', from = 0;
  for (const m of text.matchAll(pattern)) {
    html += escape(text.slice(from, m.index));
    if (m[2]) {
      const [target, alias] = m[2].split('|', 2);
      html += m[1] ? '<span data-embed="' + escape(target) + '"></span>'
        : '<a href="#" data-wiki="' + escape(target) + '">' + escape(alias || target) + '</a>';
    } else if (m[3]) html += '<span data-render="math">' + escape(m[4]) + '</span>';
    else html += escape(m[5]) + '<a href="#" data-tag="' + escape(m[6]) + '">#' + escape(m[6]) + '</a>';
    from = m.index + m[0].length;
  }
  return html + escape(text.slice(from));
};
md.renderer.rules.image = (tokens, i) => {
  const src = tokens[i].attrGet('src') || '', alt = tokens[i].content;
  return /^https?:\/\//i.test(src) ? '<img src="' + escape(src) + '" alt="' + escape(alt) + '">'
    : '<span data-embed="' + escape(src) + '" data-alt="' + escape(alt) + '"></span>';
};

function prepare(source) {
  // Keep source line numbers intact for task toggles and leave code literals alone.
  return source.replace(/^(\s*`{3,}|\s*~{3,})[^\n]*\n[\s\S]*?^\1[ \t]*$|`[^`\n]*`|%%[\s\S]*?%%|^\$\$[ \t]*\n([\s\S]*?)^\$\$[ \t]*$/gm, (match, fence, math) =>
    math !== undefined ? '```math\n' + math + '```' : match.startsWith('%%') ? match.replace(/[^\n]/g, '') : match);
}
let sequence = 0, diagramID = 0;
async function fill(container, note, ancestors) {
  container.dataset.path = note.path;
  const tokens = md.parse(prepare(note.body), {});
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].type !== 'list_item_open') continue;
    const inline = tokens[i+2];
    if (inline?.type === 'inline' && /^\[[ xX]\]\s/.test(inline.content)) {
      tokens[i].attrSet('data-task', String(note.offset + inline.map[0]));
      tokens[i].attrSet('class', 'task');
    }
  }
  container.innerHTML = md.renderer.render(tokens, md.options, {});
  if (note.properties?.length) {
    const dl = document.createElement('dl'); dl.className = 'properties';
    for (const p of note.properties) {
      const dt = document.createElement('dt'), dd = document.createElement('dd');
      dt.textContent = p.key;
      if (/^tags?$/i.test(p.key)) {
        for (const value of p.values) {
          const a = document.createElement('a'); a.href = '#'; a.dataset.tag = value.replace(/^#/, '');
          a.textContent = '#' + a.dataset.tag; dd.append(a, ' ');
        }
      } else dd.textContent = p.values.join(', ') || '—';
      dl.append(dt, dd);
    }
    container.prepend(dl);
  }
  for (const li of container.querySelectorAll('[data-task]')) {
    const root = li.firstElementChild?.tagName === 'P' ? li.firstElementChild : li;
    const text = root.firstChild;
    if (!text || text.nodeType !== Node.TEXT_NODE) continue;
    const box = document.createElement('input'); box.type = 'checkbox';
    box.checked = /^\[x\]/i.test(text.textContent);
    box.setAttribute('aria-label', text.textContent.slice(4));
    text.textContent = text.textContent.slice(4); root.prepend(box);
    box.disabled = ancestors.length > 1;
    box.onchange = () => bridge('toggle', Number(li.dataset.task));
  }
  for (const quote of container.querySelectorAll('blockquote > p:first-child')) {
    const first = quote.firstChild;
    if (first?.nodeType !== Node.TEXT_NODE) continue;
    const m = first.textContent.match(/^\[!(\w+)\][+-]?([^\n]*)(?:\n|$)/);
    if (!m) continue;
    quote.parentNode.classList.add('callout');
    const title = document.createElement('strong'); title.textContent = m[2].trim() || m[1];
    first.textContent = first.textContent.slice(m[0].length); quote.prepend(title, document.createElement('br'));
  }
  for (const item of container.querySelectorAll('[data-render]')) {
    try {
      if (item.dataset.render === 'math') {
        await loadScript('math.js');
        katex.render(item.textContent, item, {output: 'mathml', throwOnError: false, trust: false, displayMode: item.tagName === 'DIV'});
      } else {
        await loadScript('diagram.js');
        mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true, flowchart: {htmlLabels: false} });
        const {svg} = await mermaid.render('jetDiagram' + (++diagramID), item.textContent);
        item.innerHTML = svg;
      }
    } catch { item.setAttribute('aria-label', 'Unable to render ' + item.dataset.render); }
  }
  for (const item of container.querySelectorAll('[data-embed]')) {
    const target = item.dataset.embed;
    try {
      const result = await bridge('embed', {path: note.path, target});
      if (result.image) {
        const img = document.createElement('img'); img.src = result.image; img.alt = item.dataset.alt || target; item.append(img);
      } else if (result.body !== undefined && !ancestors.includes(result.path) && ancestors.length < 8) {
        const section = document.createElement('section'); section.className = 'embed'; item.replaceWith(section);
        await fill(section, result, [...ancestors, result.path]);
      } else {
        const link = document.createElement('a'); link.href = '#'; link.dataset.wiki = target; link.textContent = target; item.append(link);
      }
    } catch { item.textContent = 'Missing: ' + target; }
  }
}
async function renderNote(note, size) {
  const current = ++sequence, main = document.createElement('main');
  document.documentElement.style.fontSize = size + 'px';
  await fill(main, note, [note.path]);
  if (current === sequence) document.querySelector('main').replaceWith(main);
}
function jumpToHeading(title) {
  const heading = [...document.querySelectorAll('main h1,main h2,main h3,main h4,main h5,main h6')].find(h => h.textContent.trim().toLowerCase() === title.trim().toLowerCase());
  heading?.scrollIntoView();
}
document.addEventListener('click', e => {
  const a = e.target.closest('a'); if (!a) return;
  e.preventDefault();
  const href = a.getAttribute('href') || '';
  if (a.dataset.tag) bridge('tag', a.dataset.tag);
  else if (a.dataset.wiki) bridge('open', {path: a.closest('[data-path]').dataset.path, target: a.dataset.wiki});
  else if (href.startsWith('#') && document.getElementById(href.slice(1))) document.getElementById(href.slice(1)).scrollIntoView();
  else bridge('open', {path: a.closest('[data-path]').dataset.path, target: href});
});

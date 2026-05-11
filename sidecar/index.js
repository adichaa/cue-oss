const readline = require('readline');

const proxies = (process.env.SIDECAR_PROXIES || '')
  .split(',')
  .map(p => p.trim())
  .filter(Boolean);
let proxyIndex = 0;

let browser = null;
let page = null;

async function getPage() {
  if (!browser) {
    const { chromium } = require('playwright-extra');
    const stealth = require('puppeteer-extra-plugin-stealth');
    chromium.use(stealth());
    const proxy = proxies.length ? proxies[proxyIndex % proxies.length] : null;
    if (proxies.length) proxyIndex++;
    const launchOpts = { headless: true };
    if (proxy) launchOpts.proxy = { server: proxy };
    browser = await chromium.launch(launchOpts);
    const ctx = await browser.newContext();
    page = await ctx.newPage();
    try {
      await page.goto('https://api.ipify.org?format=json', { waitUntil: 'domcontentloaded', timeout: 10000 });
      const ip = await page.evaluate(() => document.body.innerText);
      process.stderr.write(`[sidecar] proxy=${proxy ?? 'none'} ip=${ip}\n`);
    } catch (e) {
      process.stderr.write(`[sidecar] proxy=${proxy ?? 'none'} ip=unknown (${e.message})\n`);
    }
  }
  return page;
}

function write(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });

rl.on('line', async (line) => {
  let cmd;
  try { cmd = JSON.parse(line); }
  catch { write({ error: 'invalid JSON' }); return; }

  try {
    switch (cmd.action) {
      case 'navigate': {
        const pg = await getPage();
        await pg.goto(cmd.url, { waitUntil: 'domcontentloaded', timeout: 15000 });
        write({ ok: true, url: pg.url(), title: await pg.title() });
        break;
      }
      case 'click': {
        const pg = await getPage();
        await pg.click(cmd.selector, { timeout: 10000 });
        write({ ok: true });
        break;
      }
      case 'type': {
        const pg = await getPage();
        await pg.fill(cmd.selector, cmd.text);
        write({ ok: true });
        break;
      }
      case 'content': {
        const pg = await getPage();
        const content = await Promise.race([
          (async () => {
            try { await pg.waitForLoadState('domcontentloaded', { timeout: 5000 }); } catch {}
            return pg.evaluate(() => document.body?.innerText?.substring(0, 5000) ?? '');
          })(),
          new Promise((_, reject) => setTimeout(() => reject(new Error('content timeout')), 8000))
        ]);
        write({ ok: true, url: pg.url(), title: await pg.title(), content });
        break;
      }
      case 'screenshot': {
        const pg = await getPage();
        const buf = await pg.screenshot({ type: 'jpeg', quality: 60 });
        write({ ok: true, data: buf.toString('base64') });
        break;
      }
      case 'close': {
        if (browser) { await browser.close(); browser = null; page = null; }
        write({ ok: true });
        break;
      }
      default:
        write({ error: `unknown action: ${cmd.action}` });
    }
  } catch (err) {
    write({ error: err.message });
  }
});

async function closeBrowser() {
  if (browser) {
    try { await browser.close(); } catch {}
    browser = null;
    page = null;
  }
}

rl.on('close', async () => {
  await closeBrowser();
  process.exit(0);
});

process.on('SIGTERM', async () => {
  await closeBrowser();
  process.exit(0);
});

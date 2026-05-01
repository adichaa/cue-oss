const readline = require('readline');

let browser = null;
let page = null;

async function getPage() {
  if (!browser) {
    const { chromium } = require('playwright');
    browser = await chromium.launch({ headless: true });
    const ctx = await browser.newContext();
    page = await ctx.newPage();
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
        await pg.goto(cmd.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
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
        const content = await pg.evaluate(() =>
          document.body?.innerText?.substring(0, 5000) ?? ''
        );
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

process.on('SIGTERM', async () => {
  if (browser) try { await browser.close(); } catch {}
  process.exit(0);
});

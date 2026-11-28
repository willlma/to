const {test, expect} = require('@playwright/test');

const rpc = (request, token, method, params = {}, options = {}) => request.post('/mcp', {
  headers: {
    Accept: 'application/json, text/event-stream',
    Authorization: `Bearer ${token}`,
    'MCP-Protocol-Version': '2025-11-25',
    ...options.headers
  },
  data: {jsonrpc:'2.0', id:1, method, params}
});

const callTool = async (request, token, name, args) => {
  const response = await rpc(request, token, 'tools/call', {name, arguments:args});
  expect(response.status()).toBe(200);
  return (await response.json()).result;
};

const signIn = async (page, person) => {
  await page.goto('/auth/google');
  await page.getByRole('link', {name:`Continue as ${person}`}).click();
  await expect(page.locator('.phx-connected')).toBeVisible();
};

const tokenFor = async page => {
  await page.goto('/settings');
  await page.getByRole('button', {name:'Generate Pebble token', exact:true}).click();
  return page.getByLabel('Pebble authorization').inputValue();
};

// End-to-end failure cases: browser cookies must not authorize MCP; revoked or
// another person's replaced token must not work; invalid arguments must not
// create tasks; confirmation must follow a committed save even if push fails.
// Protocol errors must stay JSON-RPC errors rather than crashing the endpoint.
test('Pebble credentials, MCP discovery, and additions reach both household browsers', async ({page, browser, request}) => {
  const context = await browser.newContext({viewport:{width:390,height:844}});
  const nicole = await context.newPage();
  let willToken, nicoleToken, listId, listUrl;

  try {
    await test.step('Generate private credentials in Settings on desktop and mobile', async () => {
      await signIn(page, 'Will');
      await page.getByRole('button', {name:'New list', exact:true}).click();
      await page.locator('#list-name').fill('Pebble groceries');
      await page.locator('#list-form button').click();
      await expect(page.getByRole('link', {name:'Pebble groceries', exact:true})).toHaveAttribute('aria-current','page');
      listUrl = new URL(page.url()).pathname;
      listId = Number(listUrl.split('/').pop());
      willToken = (await tokenFor(page)).replace('Bearer ', '');
      await expect(page.getByLabel('Pebble MCP URL')).toHaveValue('http://127.0.0.1:4002/mcp');
      await page.screenshot({path:'artifacts/e2e/pebble-settings-desktop.png',fullPage:true});
      await page.reload();
      await expect(page.getByLabel('Pebble authorization')).toHaveCount(0);
      await expect(page.getByRole('button', {name:'Replace Pebble token',exact:true})).toBeVisible();

      await signIn(nicole, 'Nicole');
      nicoleToken = (await tokenFor(nicole)).replace('Bearer ', '');
      await nicole.screenshot({path:'artifacts/e2e/pebble-settings-mobile.png',fullPage:true});
      expect(nicoleToken).not.toBe(willToken);
      expect(await nicole.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    });

    await test.step('Authenticate, negotiate MCP, and discover every list and tool', async () => {
      expect((await page.request.post('/mcp', {data:{jsonrpc:'2.0',id:1,method:'tools/list'}})).status()).toBe(401);
      expect((await rpc(request, 'invalid', 'tools/list')).status()).toBe(401);
      const initialized = await rpc(request, willToken, 'initialize', {
        protocolVersion:'2025-11-25', capabilities:{}, clientInfo:{name:'Pebble E2E',version:'1'}
      });
      expect((await initialized.json()).result).toMatchObject({
        protocolVersion:'2025-11-25', capabilities:{tools:{}}, serverInfo:{name:'Town'}
      });
      const notification = await request.post('/mcp', {
        headers:{Authorization:`Bearer ${willToken}`,Accept:'application/json, text/event-stream'},
        data:{jsonrpc:'2.0',method:'notifications/initialized'}
      });
      expect(notification.status()).toBe(202);
      expect(await notification.text()).toBe('');
      const tools = (await (await rpc(request, willToken, 'tools/list')).json()).result.tools;
      expect(tools.map(tool => tool.name)).toEqual(['list_lists','add_task']);
      const lists = await callTool(request, willToken, 'list_lists', {});
      expect(JSON.parse(lists.content[0].text).lists).toContainEqual({id:listId,name:'Pebble groceries'});
      expect((await request.get('/mcp', {headers:{Authorization:`Bearer ${willToken}`,Accept:'text/event-stream'}})).status()).toBe(405);
    });

    await test.step('Create a dated, assigned task and observe live updates and existing sync', async () => {
      await page.goto(listUrl);
      await nicole.goto(listUrl);
      await expect(page.locator('.phx-connected')).toBeVisible();
      await expect(nicole.locator('.phx-connected')).toBeVisible();
      const result = await callTool(request, nicoleToken, 'add_task', {
        list_id:listId, title:'Milk from Pebble', description:'Two cartons',
        due_on:'2030-06-10', assignee:'Will', group:'Dairy'
      });
      expect(result.isError).not.toBe(true);
      const saved = JSON.parse(result.content[0].text);
      expect(saved.task).toMatchObject({title:'Milk from Pebble',list_id:listId});
      for (const tab of [page,nicole]) {
        const row = tab.locator(`[data-task-id="${saved.task.id}"]`);
        await expect(row.locator('[name="task[title]"]')).toHaveValue('Milk from Pebble');
        await expect(row.getByRole('combobox', {name:'Assignee'}).locator('option:checked')).toHaveText('Will');
        await expect(row.getByLabel('Due date', {exact:true})).toHaveValue('2030-06-10');
      }
      const row = page.locator(`[data-task-id="${saved.task.id}"]`);
      await row.getByRole('button', {name:/^Edit /}).click();
      await expect(page.getByRole('dialog')).toContainText('Nicole');
      await expect(page.locator('#task-description')).toHaveValue('Two cartons');
      await expect(page.locator('#task-group')).toHaveValue('Dairy');
      await page.keyboard.press('Escape');
      await expect.poll(async () => {
        const state = await (await request.get('http://127.0.0.1:4010/__state')).json();
        return Object.values(state.tasks.will || {}).some(task => task.title === 'Milk from Pebble');
      }).toBe(true);
      await page.screenshot({path:'artifacts/e2e/pebble-created-task.png',fullPage:true});
    });

    await test.step('Reject invalid tool calls and report notification failure without undoing a save', async () => {
      for (const args of [
        {list_id:listId,title:''}, {list_id:listId,title:'Invalid assignee',assignee:'Someone else'},
        {list_id:listId,title:'Invalid date',due_on:'tomorrow'}, {list_id:999999,title:'Deleted list'},
        {list_id:'oops',title:'Wrong type'}, {list_id:listId,title:{text:'Wrong type'}},
        {list_id:listId,title:'Invalid description',description:{}},
        {list_id:listId,title:'Invalid group',group:[]},
        {list_id:1e30,title:'Out of range list'},
        {list_id:listId,title:'Forged creator',created_by:'Nicole'}, {list_id:listId}
      ]) {
        const response = await rpc(request, willToken, 'tools/call', {name:'add_task',arguments:args});
        expect(response.status()).toBe(200);
        const body = await response.json();
        expect(body.error || body.result?.isError).toBeTruthy();
      }
      await request.post('http://127.0.0.1:4010/__push-response', {data:{status:503}});
      const warning = await callTool(request, willToken, 'add_task', {
        list_id:listId,title:'Saved even without push',assignee:'Nicole'
      });
      await request.post('http://127.0.0.1:4010/__push-response', {data:{status:201}});
      expect(warning.isError).not.toBe(true);
      const saved = JSON.parse(warning.content[0].text);
      expect(saved.warning).toContain('saved');
      await expect(page.locator(`[data-task-id="${saved.task.id}"]`)).toBeVisible();
      expect((await rpc(request, willToken, 'tools/list', {}, {headers:{Origin:'https://unrelated.example'}})).status()).toBe(403);
      expect((await rpc(request, willToken, 'tools/list', {}, {headers:{'MCP-Protocol-Version':'invalid'}})).status()).toBe(400);
      const unknown = await rpc(request, willToken, 'unknown');
      expect((await unknown.json()).error.code).toBe(-32601);
      const malformed = await request.post('/mcp', {
        headers:{Authorization:`Bearer ${willToken}`,Accept:'application/json, text/event-stream'},
        data:[{jsonrpc:'2.0',id:1,method:'tools/list'}]
      });
      expect((await malformed.json()).error.code).toBe(-32600);
      const invalidParams = await rpc(request, willToken, 'tools/call', []);
      expect((await invalidParams.json()).error.code).toBe(-32602);
    });

    await test.step('Replacement and revocation take effect without affecting the other person', async () => {
      await page.goto('/settings');
      await page.getByRole('button', {name:'Replace Pebble token',exact:true}).click();
      const replacement = (await page.getByLabel('Pebble authorization').inputValue()).replace('Bearer ', '');
      expect((await rpc(request, willToken, 'tools/list')).status()).toBe(401);
      expect((await rpc(request, replacement, 'tools/list')).status()).toBe(200);
      expect((await rpc(request, nicoleToken, 'tools/list')).status()).toBe(200);
      await page.getByRole('button', {name:'Revoke Pebble token',exact:true}).click();
      await expect(page.getByLabel('Pebble authorization')).toHaveCount(0);
      await expect(page.getByRole('button', {name:'Generate Pebble token',exact:true})).toBeVisible();
      expect((await rpc(request, replacement, 'tools/list')).status()).toBe(401);
      expect((await rpc(request, nicoleToken, 'tools/list')).status()).toBe(200);
    });
  } finally {
    await context.close();
  }
});

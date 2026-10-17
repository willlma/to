const {test, expect} = require('@playwright/test');

async function signIn(page, person = 'Will') {
  await page.goto('/auth/google');
  await page.getByRole('link', {name: `Continue as ${person}`}).click();
  await expect(page).toHaveURL(/\/lists(?:\/\d+)?$/);
  await expect(page.locator('.phx-connected')).toBeVisible();
}

function taskRow(page, title) {
  return page.locator('[data-task-id]').filter({has: page.locator('input[name="task[title]"][value=' + JSON.stringify(title) + ']')});
}

async function createTask(page, title, options = {}) {
  await page.locator('#quick-title').fill(title);
  if (Object.keys(options).length) {
    await page.locator('#task-title').press('Shift+Enter');
    await expect(page.locator('#task-description')).toBeVisible();
    if (options.description) await page.locator('#task-description').fill(options.description);
    if (options.due) await page.locator('#task-due').fill(options.due);
    if (options.assignee) await page.locator('#task-assignee').selectOption({label: options.assignee});
    if (options.group) await page.locator('#task-group').fill(options.group);
  }
  await page.locator('#task-title').press('Enter');
  const row = taskRow(page, title);
  await expect(row).toHaveCount(1);
  await expect(page.locator('#task-title')).toHaveValue('');
  const id = await row.getAttribute('data-task-id');
  return page.locator('[data-task-id="' + id + '"]');
}

async function editTask(page, row, changes) {
  if ('assignee' in changes) {
    const picker = row.getByRole('combobox', {name:'Assignee'});
    await picker.selectOption(changes.assignee === 'Unassigned' ? '' : {label: changes.assignee});
  }
  if ('due' in changes) {
    await row.getByLabel('Due date', {exact:true}).fill(changes.due);
  }
}

async function googleState(request) { return (await request.get('http://127.0.0.1:4010/__state')).json(); }
async function googleTasks(request, person) { return Object.values((await googleState(request)).tasks[person] || {}); }

// Scheduling failure cases are documented before exercising the system: wrong
// previous calendar day, wrong timezone/DST conversion, obsolete jobs after an
// edit, or a reminder still queued after completion. The browser writes through
// LiveView; reading the persisted job verifies the server side of that flow.
function reminderJobs(title) {
  const {execFileSync} = require('node:child_process');
  const script = `import sqlite3,json,sys
c=sqlite3.connect('tmp/e2e.db'); c.row_factory=sqlite3.Row
rows=c.execute("SELECT j.state,j.scheduled_at,j.args,t.due_on,u.reminder_time FROM oban_jobs j JOIN tasks t ON t.id=json_extract(j.args,'$.task_id') JOIN users u ON u.id=t.assignee_id WHERE j.worker='To.ReminderWorker' AND t.title=? ORDER BY j.id",(sys.argv[1],)).fetchall()
print(json.dumps([dict(r) for r in rows]))`;
  return JSON.parse(execFileSync('python3', ['-c', script, title], {encoding:'utf8'}));
}

test('household journey: lists, tasks, Google export, reminders, and recovery', async ({page, browser, request}) => {
  // Stub the browser's push-provider boundary; registration, subscription saving,
  // server delivery, and encryption still use the application's real flow.
  const {createECDH, randomBytes} = require('node:crypto');
  const deviceKey = createECDH('prime256v1');
  deviceKey.generateKeys();
  const deviceSubscription = {
    endpoint:'https://fcm.googleapis.com/e2e',
    keys:{p256dh:deviceKey.getPublicKey().toString('base64url'),auth:randomBytes(16).toString('base64url')}
  };
  await page.context().addInitScript(subscription => {
    Object.defineProperty(Notification, 'permission', {
      get:() => localStorage.getItem('e2e-notification-permission') || 'default'
    });
    Notification.requestPermission = async () => {
      localStorage.setItem('e2e-notification-permission','granted');
      return 'granted';
    };
    const current = () => localStorage.getItem('e2e-push-enabled') ? {
      endpoint:subscription.endpoint, toJSON:() => subscription
    } : null;
    PushManager.prototype.getSubscription = async () => current();
    PushManager.prototype.subscribe = async () => {
      localStorage.setItem('e2e-push-enabled','true');
      return current();
    };
  }, deviceSubscription);
  await test.step('Reject unauthorized sign-in', async () => {
    await page.goto('/auth/google');
    await page.getByRole('link', {name:'Continue as Stranger'}).click();
    await expect(page).toHaveURL('http://127.0.0.1:4002/');
    await expect(page.getByText(/Only Nicole and Will/)).toBeVisible();
    await page.goto('/auth/google');
    await page.goto('/auth/google/callback?code=will&state=forged');
    await expect(page).toHaveURL('http://127.0.0.1:4002/');
    await page.goto('/lists');
    await expect(page).toHaveURL('http://127.0.0.1:4002/');
  });
  await signIn(page);
  await page.locator('#quick-title').blur();
  await page.keyboard.type('Body typing');
  await expect(page.locator('#task-title')).toHaveValue('Body typing');
  await page.locator('#task-title').press('Enter');
  await expect(taskRow(page, 'Body typing')).toHaveCount(1);
  await expect(page.locator('#task-title')).toHaveValue('');
  await expect(page.locator('#old-completed')).not.toHaveAttribute('open', '');
  await page.locator('#old-completed > summary').click();
  await expect(taskRow(page, 'Archived fixture')).toBeVisible();
  await page.locator('#old-completed > summary').click();

  const nicoleContext = await browser.newContext({viewport:{width:390,height:844}, isMobile:true, hasTouch:true});
  const nicole = await nicoleContext.newPage();
  await signIn(nicole, 'Nicole');
  await expect(page.locator('#list-name')).toBeHidden();
  await page.getByRole('button', {name:'New list', exact:true}).click();
  await page.locator('#list-name').fill('Groceries');
  await page.locator('#list-form').getByRole('button').click();
  await expect(page.getByRole('link', {name:'Groceries', exact:true})).toBeVisible();
  await expect(page.locator('#list-name')).toBeHidden();
  await expect(nicole.getByRole('link', {name:'Groceries', exact:true})).toBeVisible();
  await nicole.getByRole('link', {name:'Groceries', exact:true}).click();

  await test.step('Validate a new task', async () => {
    const title = page.locator('#task-title');
    await expect(page.locator('#task-form [role="alert"]')).toHaveCount(0);
    await page.locator('#quick-title').fill('Validation draft');
    await title.press('Tab');
    await expect(page.locator('#task-form [role="alert"]')).toHaveCount(0);
    await title.fill('   ');
    await title.press('Enter');
    await expect(page.locator('#task-title-errors')).toHaveText("Todo can't be blank");
    await expect(title).toHaveAttribute('aria-describedby', 'task-title-errors');
    await expect(page.locator('#task-form [role="alert"]')).toHaveCount(1);
    await title.fill('Validation saved');
    await title.press('Enter');
    await expect(taskRow(page, 'Validation saved')).toBeVisible();
    await expect(title).toHaveValue('');
    await expect(page.locator('#task-form [role="alert"]')).toHaveCount(0);
  });

  const friday = await createTask(page, 'Friday groceries', {description:'Whole milk', due:'2030-05-03', assignee:'Nicole', group:'Dairy'});
  await createTask(page, 'Thursday produce', {due:'2030-05-02', group:'Produce'});
  const plain = await createTask(page, 'No due date');
  await expect(taskRow(nicole, 'Friday groceries')).toBeVisible();
  await expect.poll(async () => (await googleTasks(request, 'nicole')).find(t => t.title === 'Friday groceries')?.due).toBe('2030-05-03T00:00:00Z');
  // Date order applies within a group, so compare two ungrouped rows.
  await createTask(page, 'Earlier ungrouped', {due:'2030-05-01'});
  await createTask(page, 'Later ungrouped', {due:'2030-05-04'});
  const titles = await page.locator('[data-task-id] input[name="task[title]"]').evaluateAll(inputs => inputs.map(input => input.value));
  expect(titles.findIndex(t => t.includes('Earlier ungrouped'))).toBeLessThan(titles.findIndex(t => t.includes('Later ungrouped')));
  expect(titles.findIndex(t => t.includes('Later ungrouped'))).toBeLessThan(titles.findIndex(t => t.includes('No due date')));
  expect(titles.findIndex(t => t.includes('No due date'))).toBeLessThan(titles.findIndex(t => t.includes('Friday groceries')));
  expect(titles.findIndex(t => t.includes('No due date'))).toBeLessThan(titles.findIndex(t => t.includes('Thursday produce')));

  // Moving groups must persist across browsers, preserve completion and keep due-date sorting.
  const inGroup = (tab, group) => tab.locator('section').filter({has:tab.locator('input[data-group=' + JSON.stringify(group) + ']')});
  await plain.getByRole('checkbox').dragTo(page.locator('input[data-group="Dairy"]'));
  await expect(inGroup(nicole, 'Dairy').locator('[data-task-id]').filter({has:nicole.locator('input[value="No due date"]')})).toBeVisible();
  await expect(plain.getByRole('checkbox')).not.toBeChecked();
  await friday.getByRole('checkbox').dragTo(page.locator('input[data-group="Produce"]'));
  await expect(inGroup(nicole, 'Produce').locator('[data-task-id]').filter({has:nicole.locator('input[value="Friday groceries"]')})).toBeVisible();
  await friday.getByRole('checkbox').dragTo(page.locator('input[data-group="Dairy"]'));
  await expect(inGroup(page, 'Dairy').locator('input[value="Friday groceries"]')).toBeVisible();
  await plain.getByRole('checkbox').dragTo(page.getByRole('link', {name:'Groceries', exact:true}));
  await expect(plain).toHaveAttribute('data-group', '');
  // The same move is available to keyboard users without another menu.
  await plain.getByRole('checkbox').press('Alt+ArrowDown');
  await expect(plain).not.toHaveAttribute('data-group', '');
  await plain.getByRole('checkbox').press('Alt+ArrowUp');
  await expect(plain).toHaveAttribute('data-group', '');

  await test.step('Move the same task by touch', async () => {
    const page = nicole;
    const context = nicoleContext;
    const row = taskRow(page, 'No due date');
    const id = await row.getAttribute('data-task-id');
    const session = await context.newCDPSession(page);
    async function drag(target) {
      const source = await row.getByRole('checkbox').boundingBox();
      const start = {x:source.x+source.width/2,y:source.y+source.height/2};
      const point = (x,y) => [{x,y,id:0,radiusX:1,radiusY:1,force:1}];
      await session.send('Input.dispatchTouchEvent', {type:'touchStart',touchPoints:point(start.x,start.y)});
      for (let step=1; step<=8; step++) await session.send('Input.dispatchTouchEvent', {type:'touchMove',touchPoints:point(start.x+(target.x-start.x)*step/8,start.y+(target.y-start.y)*step/8)});
      await session.send('Input.dispatchTouchEvent', {type:'touchEnd',touchPoints:[]});
    }
    const group = await page.locator('input[data-group="Dairy"]').boundingBox();
    await drag({x:group.x+group.width/2,y:group.y+group.height/2});
    await expect(row).toHaveAttribute('data-group','Dairy');
    await expect(row.getByRole('checkbox')).not.toBeChecked();
    await drag({x:380,y:10});
    await expect(row).toHaveAttribute('data-group','Dairy');
    await expect(row.getByRole('checkbox')).not.toBeChecked();
    await page.reload();
    await expect(page.locator('[data-task-id="'+id+'"]').getByRole('textbox', {name:'Title',exact:true})).toHaveValue('No due date');
    await expect(page.locator('[data-task-id="'+id+'"]')).toHaveAttribute('data-group','Dairy');
    await page.screenshot({path:'artifacts/e2e/touch-grouping.png',fullPage:true});

  });

  const dairyInput = page.locator('input[data-group="Dairy"]');
  await dairyInput.fill('Cold food');
  await dairyInput.blur();
  await expect(page.locator('input[data-group="Cold food"]')).toHaveValue('Cold food');
  await expect(nicole.locator('input[data-group="Cold food"]')).toHaveValue('Cold food');
  await page.locator('input[data-group="Cold food"]').fill('Produce');
  await page.locator('input[data-group="Cold food"]').blur();
  await expect(page.locator('#merge-dialog')).toBeVisible();
  await page.getByRole('button', {name:'Choose another name', exact:true}).click();
  await expect(page.locator('#merge-dialog')).toHaveCount(0);
  await expect(page.locator('input[data-group="Cold food"]')).toBeVisible();
  await page.locator('input[data-group="Cold food"]').fill('Produce');
  await page.locator('input[data-group="Cold food"]').blur();
  await page.getByRole('button', {name:'Merge groups', exact:true}).click();
  await expect(page.locator('input[data-group="Produce"]')).toHaveCount(1);
  await expect(page.locator('input[data-group="Cold food"]')).toHaveCount(0);

  await expect(page.locator('header strong')).toHaveCount(0);
  await expect(page.getByRole('button', {name:/^Edit /})).toHaveCount(0);
  const listUrl = page.url();
  await expect(page.locator('#reminder-form')).toBeHidden();
  await page.getByRole('link', {name:'Settings for Will'}).click();
  await expect(page).toHaveURL(/\/settings$/);
  await expect(page.getByRole('heading', {name:'Settings', exact:true})).toBeVisible();
  await expect(page.locator('#task-form')).toHaveCount(0);
  await expect(page.locator('#reminder-form')).toBeVisible();
  await expect(page.locator('#enable-notifications')).toHaveCSS('margin-top', '16px');
  await test.step('Enable notifications and send a test to this device', async () => {
    await page.getByRole('button', {name:'Enable notifications',exact:true}).click();
    await expect(page.getByRole('button', {name:'Test notification',exact:true})).toBeEnabled();
    await expect(page.locator('#notification-status')).toBeEmpty();
    expect(await page.evaluate(() => Notification.permission)).toBe('granted');
    await page.getByRole('button', {name:'Test notification',exact:true}).click();
    await expect(page.getByRole('status').filter({hasText:'Test notification sent.'})).toBeVisible();
    await expect.poll(async () => (await googleState(request)).pushes.filter(p => p.payload.title === 'Hello from town').length).toBe(1);
    const delivery = (await googleState(request)).pushes.find(p => p.payload.title === 'Hello from town');
    expect(delivery.endpoint).toBe(deviceSubscription.endpoint);
    expect((await googleState(request)).encrypted_pushes.at(-1)).toMatchObject({vapid:true,valid_encrypted_body:true});
    await page.reload();
    await expect(page.getByRole('button', {name:'Test notification',exact:true})).toBeEnabled();
    await page.screenshot({path:'artifacts/e2e/test-notification.png',fullPage:true});
  });
  await test.step('Import existing Google tasks without duplicates or reverse sync', async () => {
    const source = 'http://127.0.0.1:4010/tasks/v1/lists/@default/tasks';
    const willAuth = {Authorization:'Bearer access-will'};
    const originals = [];
    for (const data of [
      {title:'Existing Google task', notes:'Keep these notes', due:'2030-11-01T00:00:00Z', status:'needsAction'},
      {title:'Existing Google task', status:'needsAction'},
      {title:'Google task already completed', status:'completed', completed:'2020-01-01T12:00:00Z'},
      {title:'Shared Chat task for Will', status:'needsAction', assignmentInfo:{surfaceType:'SPACE',spaceInfo:{space:'spaces/family'}}}
    ]) {
      const response = await request.post(source, {headers:willAuth, data});
      expect(response.ok()).toBe(true);
      originals.push(await response.json());
    }
    for (const data of [
      {title:'Second subtask', position:'0002', notes:'Subtask notes', status:'needsAction'},
      {title:'First subtask', position:'0001', status:'needsAction'},
      {title:'Completed subtask', position:'0003', status:'completed'}
    ]) {
      const response = await request.post(source, {headers:willAuth,data:{...data,parent:originals[0].id}});
      expect(response.ok()).toBe(true);
    }
    const nicoleSource = await request.post(source, {
      headers:{Authorization:'Bearer access-nicole'},
      data:{title:'Nicole-only Google task', due:'2030-11-02T00:00:00Z', status:'needsAction', assignmentInfo:{surfaceType:'SPACE',spaceInfo:{space:'spaces/family'}}}
    });
    expect(nicoleSource.ok()).toBe(true);
    await request.post('http://127.0.0.1:4010/__google-connection', {data:{person:'Will',connected:false}});
    await page.reload();
    await expect(page.getByRole('button', {name:'Import Google Tasks',exact:true})).toHaveCount(0);
    await page.getByRole('button', {name:'Connect to Google',exact:true}).click();
    await expect(page).toHaveURL(/127\.0\.0\.1:4010\/authorize\?/);
    await request.post('http://127.0.0.1:4010/__google-connection', {data:{person:'Will',connected:true}});
    await page.goto('/settings');
    await expect(page.getByRole('combobox', {name:'Import into list'})).toHaveCount(0);
    await expect(page.getByText('Google Tasks connected.', {exact:true})).toHaveCount(0);
    await expect(page.getByRole('link', {name:/Connect Google Tasks|Reconnect Google Tasks/})).toHaveCount(0);
    await expect(page.locator('#google-import-form p')).toHaveCount(0);
    await nicole.getByRole('link', {name:'To do',exact:true}).click();
    await request.post('http://127.0.0.1:4010/__fail-next', {data:{count:1}});
    await page.getByRole('button', {name:'Import Google Tasks',exact:true}).click();
    await expect(page.getByText(/Import failed.*Nothing was imported/)).toBeVisible();
    await expect(page.getByRole('button', {name:'Import Google Tasks',exact:true})).toBeEnabled();
    await expect(taskRow(nicole, 'Existing Google task')).toHaveCount(0);

    // A temporary token-service outage must allow retry without reconnecting.
    await request.post('http://127.0.0.1:4010/__token-error', {data:{error:'unavailable'}});
    await page.getByRole('button', {name:'Import Google Tasks',exact:true}).click();
    await expect.poll(async () => (await googleState(request)).token_error).toBe(null);
    await expect(page.getByText(/Import failed.*Nothing was imported/)).toBeVisible();
    await expect(page.getByRole('button', {name:'Import Google Tasks',exact:true})).toBeEnabled();

    await request.post('http://127.0.0.1:4010/__token-error', {data:{error:'revoked'}});
    await page.getByRole('button', {name:'Import Google Tasks',exact:true}).click();
    await expect(page.getByText(/Google access has expired or was revoked/)).toBeVisible();
    await page.getByRole('button', {name:'Reconnect to Google',exact:true}).click();
    await expect(page).toHaveURL(/127\.0\.0\.1:4010\/authorize\?/);
    // Keep the existing sign-in; the provider rejected only the previous attempt.
    await page.goto('/settings');

    const beforeImport = (await googleState(request)).calls.length;
    await page.getByRole('button', {name:'Import Google Tasks',exact:true}).click();
    await expect(page.getByText(/Imported 3 tasks/)).toBeVisible();
    await expect(page.getByRole('button', {name:'Test notification',exact:true})).toBeEnabled();
    expect((await googleState(request)).calls.slice(beforeImport).every(call => call.method === 'GET')).toBe(true);
    await expect(taskRow(nicole, 'Existing Google task')).toHaveCount(2);
    await expect(nicole.getByRole('link', {name:'To do',exact:true})).toHaveAttribute('aria-current','page');
    await expect(taskRow(nicole, 'Shared Chat task for Will')).toHaveCount(1);
    await expect(taskRow(nicole, 'Shared Chat task for Will').getByRole('combobox', {name:'Assignee'}).locator('option:checked')).toHaveText('Will');
    await expect(taskRow(nicole, 'Nicole-only Google task')).toHaveCount(0);
    const dated = taskRow(nicole, 'Existing Google task').filter({has:nicole.locator('input[type="date"][value="2030-11-01"]')});
    await expect(dated.getByRole('textbox', {name:'Description',exact:true})).toHaveValue('Keep these notes\n\n- First subtask\n- Second subtask\n  Subtask notes');
    for (const title of ['First subtask','Second subtask','Completed subtask']) {
      await expect(taskRow(nicole, title)).toHaveCount(0);
    }
    await expect(dated.getByRole('combobox', {name:'Assignee'}).locator('option:checked')).toHaveText('Will');
    await nicole.locator('#old-completed > summary').click();
    await expect(taskRow(nicole, 'Google task already completed')).toHaveCount(0);

    await request.patch(`${source}/${originals[0].id}`, {headers:willAuth,data:{title:'Changed only in Google'}});
    await page.getByRole('button', {name:'Import Google Tasks',exact:true}).click();
    await expect(page.getByText(/Imported 0 tasks. Skipped 3/)).toBeVisible();
    await expect(taskRow(nicole, 'Existing Google task')).toHaveCount(2);
    await expect(taskRow(nicole, 'Changed only in Google')).toHaveCount(0);
    await page.reload();
    await page.getByRole('button', {name:'Import Google Tasks',exact:true}).click();
    await expect(page.getByText(/Imported 0 tasks. Skipped 3/)).toBeVisible();
    await expect(dated.getByRole('textbox', {name:'Description',exact:true})).toHaveValue('Keep these notes\n\n- First subtask\n- Second subtask\n  Subtask notes');
    await expect(taskRow(nicole, 'Shared Chat task for Will')).toHaveCount(1);

    // Import reads the signed-in person's account and skips our existing exports.
    await nicole.getByRole('link', {name:'Settings for Nicole'}).click();
    await nicole.getByRole('button', {name:'Import Google Tasks',exact:true}).click();
    await expect(nicole.getByText(/Imported 1 tasks. Skipped 1/)).toBeVisible();
    await nicole.getByRole('link', {name:'Back to lists'}).click();
    await expect(taskRow(nicole, 'Nicole-only Google task').getByRole('combobox', {name:'Assignee'}).locator('option:checked')).toHaveText('Nicole');
    await nicole.goto(listUrl);
    await expect(taskRow(nicole, 'Friday groceries')).toHaveCount(1);
    await expect(taskRow(nicole, 'Existing Google task')).toHaveCount(0);
    await expect(taskRow(nicole, 'Nicole-only Google task')).toHaveCount(0);
    await page.screenshot({path:'artifacts/e2e/google-import.png',fullPage:true});

    // Reconnecting queues a sync for the user's tasks. Undated Google originals
    // must survive that pass even though ordinary exports require a due date.
    await request.post('http://127.0.0.1:4010/__sync-google', {data:{person:'Will'}});
    await expect.poll(async () => (await googleState(request)).jobs
      .filter(job => job.worker === 'To.SyncWorker')
      .every(job => job.state === 'completed')).toBe(true);
    expect((await googleTasks(request, 'will')).some(task => task.id === originals[1].id)).toBe(true);
    expect((await googleTasks(request, 'will')).some(task => task.id === originals[3].id)).toBe(true);
  });
  await page.getByRole('link', {name:'Back to lists'}).click();
  await page.goto(listUrl);

  const milk = taskRow(page, 'Friday groceries');
  const milkId = await milk.getAttribute('data-task-id');
  const milkRow = page.locator('[data-task-id="' + milkId + '"]');
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).fill('Milk and eggs');
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).press('Enter');
  await expect(page.locator('#quick-title')).toBeFocused();
  await expect(taskRow(nicole, 'Milk and eggs')).toBeVisible();
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).press('Shift+Enter');
  await expect(milkRow.getByRole('textbox', {name:'Description', exact:true})).toBeFocused();
  await milkRow.getByRole('textbox', {name:'Description', exact:true}).fill('Two cartons');
  await milkRow.getByRole('textbox', {name:'Description', exact:true}).press('Tab');
  await expect(taskRow(nicole, 'Milk and eggs').getByRole('textbox', {name:'Description', exact:true})).toHaveValue('Two cartons');
  await milkRow.getByRole('combobox', {name:'Assignee'}).selectOption({label:'Will'});
  await expect(taskRow(nicole, 'Milk and eggs').getByRole('combobox', {name:'Assignee'})).toHaveValue(await milkRow.getByRole('combobox', {name:'Assignee'}).inputValue());
  await expect.poll(async () => (await googleTasks(request, 'nicole')).some(t => t.title === 'Friday groceries')).toBe(false);
  await expect.poll(async () => (await googleTasks(request, 'will')).find(t => t.title === 'Milk and eggs')?.notes).toContain('Two cartons');
  // A field-level save must preserve another person's concurrent edit.
  await milkRow.getByRole('textbox', {name:'Description', exact:true}).fill('Local draft');
  await taskRow(nicole, 'Milk and eggs').getByRole('textbox', {name:'Title', exact:true}).fill('Milk, eggs and bread');
  await taskRow(nicole, 'Milk and eggs').getByRole('textbox', {name:'Title', exact:true}).press('Enter');
  await expect(milkRow.getByRole('textbox', {name:'Title', exact:true})).toHaveValue('Milk, eggs and bread');
  await milkRow.getByRole('textbox', {name:'Description', exact:true}).press('Tab');
  await expect(taskRow(nicole, 'Milk, eggs and bread').getByRole('textbox', {name:'Description', exact:true})).toHaveValue('Local draft');
  page.once('dialog', dialog => dialog.dismiss());
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).fill('');
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).press('Tab');
  await expect(milkRow.getByRole('textbox', {name:'Title', exact:true})).toHaveValue('Milk, eggs and bread');
  await expect(taskRow(nicole, 'Milk, eggs and bread')).toBeVisible();
  const disposable = await createTask(page, 'Delete inline', {description:'The x needs no confirmation'});
  const unexpectedDialogs = [];
  const unexpectedDialog = async dialog => { unexpectedDialogs.push(dialog.message()); await dialog.dismiss(); };
  page.on('dialog', unexpectedDialog);
  await disposable.getByRole('button', {name:'Delete Delete inline', exact:true}).click();
  await expect(disposable).toHaveCount(0);
  page.off('dialog', unexpectedDialog);
  expect(unexpectedDialogs).toEqual([]);
  await expect(taskRow(nicole, 'Delete inline')).toHaveCount(0);

  const cleared = await createTask(page, 'Clear a simple title');
  await cleared.getByRole('textbox', {name:'Title', exact:true}).fill('   ');
  await cleared.getByRole('textbox', {name:'Title', exact:true}).press('Tab');
  await expect(cleared).toHaveCount(0);
  await expect(taskRow(nicole, 'Clear a simple title')).toHaveCount(0);
  const detailed = await createTask(page, 'Clear a detailed title', {description:'Also remove my details', assignee:'Will', due:'2030-10-01'});
  await expect.poll(async () => (await googleTasks(request, 'will')).some(t => t.title === 'Clear a detailed title')).toBe(true);
  page.once('dialog', async dialog => {
    expect(dialog.message()).toContain('Clear a detailed title');
    await dialog.accept();
  });
  await detailed.getByRole('textbox', {name:'Title', exact:true}).fill('');
  await detailed.getByRole('textbox', {name:'Title', exact:true}).press('Tab');
  await expect(detailed).toHaveCount(0);
  await expect(taskRow(nicole, 'Clear a detailed title')).toHaveCount(0);
  await expect.poll(async () => (await googleTasks(request, 'will')).some(t => t.title === 'Clear a detailed title')).toBe(false);

  await plain.getByRole('checkbox', {name: /^Complete /}).click();
  await expect(plain.getByRole('checkbox', {name: /^Reopen /})).toBeChecked();
  await page.reload();
  await expect(taskRow(page, 'No due date')).toBeVisible();
  await expect(taskRow(page, 'No due date').getByRole('checkbox', {name: /^Reopen /})).toBeChecked();
  await page.context().setOffline(true);
  // Chromium's offline emulation preserves existing WebSockets, so close the
  // socket too, as a dropped mobile connection would.
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('#connection-status')).toBeVisible();
  await page.locator('#quick-title').fill('Reconnect draft');
  await page.context().setOffline(false);
  await page.evaluate(() => window.liveSocket.connect());
  await expect(page.locator('.phx-connected')).toBeVisible({timeout:15000});
  await expect(page.locator('#task-title')).toHaveValue('Reconnect draft');
  await page.locator('#task-title').press('Enter');
  await expect(taskRow(page, 'Reconnect draft')).toHaveCount(1);
  await page.screenshot({path:'artifacts/e2e/shared-list.png', fullPage:true});
  await page.setViewportSize({width:390, height:844});
  await expect(page.locator('[id^="task-options-"]')).toHaveCount(0);
  const compact = await plain.evaluate(row => {
    const controls = [row.querySelector('input[type="checkbox"]'), row.querySelector('.task-title'), row.querySelector('select'), row.querySelector('.task-date'), row.querySelector(':scope > button')];
    const checkbox = controls[0].getBoundingClientRect();
    const description = row.querySelector('textarea').getBoundingClientRect();
    return {centers:controls.map(el => {const r=el.getBoundingClientRect(); return r.y+r.height/2}), descriptionBelow:description.top >= checkbox.bottom, descriptionLeft:description.left, titleLeft:controls[1].getBoundingClientRect().left, overflow:document.documentElement.scrollWidth > innerWidth};
  });
  expect(Math.max(...compact.centers)-Math.min(...compact.centers)).toBeLessThan(6);
  expect(compact.overflow).toBe(false);
  expect(compact.descriptionBelow).toBe(true);
  expect(Math.abs(compact.descriptionLeft-compact.titleLeft)).toBeLessThan(1);
  await expect(plain.getByRole('textbox', {name:'Description', exact:true})).not.toHaveAttribute('placeholder');
  await page.screenshot({path:'artifacts/e2e/mobile-list.png', fullPage:true});

  await test.step('Preserve the draft and dialog position', async () => {
    const row = milkRow;
    const before = await row.boundingBox();
    const quick = page.locator('#quick-title');
    const anchor = await quick.boundingBox();
    await expect(page.getByRole('button', {name:'Add', exact:true})).toBeHidden();
    await quick.fill('Typing opens details');
    const dialog = page.getByRole('dialog', {name:'New todo'});
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-title')).toHaveValue('Typing opens details');
    await expect(page.locator('#task-title')).toBeFocused();
    await expect(page.locator('#task-description')).toBeVisible();
    const titleBounds = await page.locator('#task-title').boundingBox();
    for (const dimension of ['x', 'y', 'width', 'height']) {
      expect(Math.abs(titleBounds[dimension] - anchor[dimension])).toBeLessThan(1);
    }
    expect(await dialog.evaluate(el => getComputedStyle(el).backgroundColor)).toBe(await page.locator('body').evaluate(el => getComputedStyle(el).backgroundColor));
    expect(await dialog.evaluate(el => getComputedStyle(el, '::backdrop').backgroundColor)).toBe('rgba(0, 0, 0, 0)');
    expect((await row.boundingBox()).y).toBe(before.y);
    expect(Math.abs((await dialog.boundingBox()).y - anchor.y)).toBeLessThan(2);
    await page.locator('#task-description').fill('Keep this draft');
    await page.locator('#task-due').fill('2030-09-01');
    await page.locator('#task-assignee').selectOption({label:'Will'});
    const assignee = await page.locator('#task-assignee').inputValue();
    await page.locator('#task-title').press('Escape');
    await expect(dialog).toBeHidden();
    await expect(quick).toHaveValue('Typing opens details');
    await expect(quick).toBeFocused();
    await quick.press('End');
    await quick.pressSequentially(' again');
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-title')).toHaveValue('Typing opens details again');
    await expect(page.locator('#task-description')).toHaveValue('Keep this draft');
    await expect(page.locator('#task-due')).toHaveValue('2030-09-01');
    await expect(page.locator('#task-assignee')).toHaveValue(assignee);
    await page.getByRole('button', {name:'Cancel', exact:true}).click();
    await expect(dialog).toBeHidden();
    await expect(quick).toHaveValue('Typing opens details again');
    await expect(quick).toBeFocused();
    await quick.click();
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-title')).toHaveValue('Typing opens details again');
    await expect(page.locator('#task-description')).toHaveValue('Keep this draft');
    await expect(page.locator('#task-due')).toHaveValue('2030-09-01');
    await expect(page.locator('#task-assignee')).toHaveValue(assignee);
    await page.getByRole('button', {name:'Cancel', exact:true}).click();
    await expect(dialog).toBeHidden();
    await expect(quick).toBeFocused();
    await page.getByRole('button', {name:'Add todo to Produce', exact:true}).click();
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-group')).toHaveValue('Produce');
    await page.locator('#task-title').fill('Added via group');
    await page.locator('#task-description').fill('In the same dialog');
    await page.getByRole('button', {name:'Add', exact:true}).click();
    await expect(dialog).toBeHidden();
    await expect(quick).toBeFocused();
    await expect(taskRow(page, 'Added via group')).toHaveAttribute('data-group', 'Produce');
    await quick.fill('Next todo');
    await expect(page.locator('#task-group')).toHaveValue('');
    await page.locator('#task-description').fill('Retained after cancel and outside click');
    await page.locator('#task-group').fill('Draft group');
    await page.getByRole('button', {name:'Cancel', exact:true}).click();
    await expect(dialog).toBeHidden();
    await expect(quick).toBeFocused();
    await expect(quick).toHaveValue('Next todo');
    await quick.fill('Outside click draft');
    await expect(page.locator('#task-description')).toHaveValue('Retained after cancel and outside click');
    await expect(page.locator('#task-group')).toHaveValue('Draft group');
    await dialog.click({position:{x:2,y:2}});
    await expect(dialog).toBeVisible();
    await page.mouse.click(2, 2);
    await expect(dialog).toBeHidden();
    await expect(quick).toHaveValue('Outside click draft');
    await expect(quick).toBeFocused();
    // Real typing must work after dismissal, without focusing a locator first.
    await page.keyboard.type(' resumed');
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-title')).toHaveValue('Outside click draft resumed');
    await page.mouse.click(2, 2);
    await expect(dialog).toBeHidden();
    await expect(quick).toBeFocused();
    await page.setViewportSize({width:390,height:844});
    const phoneAnchor = await quick.boundingBox();
    await page.emulateMedia({colorScheme:'dark'});
    await quick.fill('Phone draft');
    await expect(dialog).toBeVisible();
    expect(await page.locator('#task-assignee').evaluate(el => getComputedStyle(el).backgroundColor)).toBe(await dialog.evaluate(el => getComputedStyle(el).backgroundColor));
    await expect(page.locator('#task-description')).toHaveValue('Retained after cancel and outside click');
    await expect(page.locator('#task-group')).toHaveValue('Draft group');
    const bounds = await dialog.boundingBox();
    expect(bounds.x).toBeGreaterThanOrEqual(0);
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(390);
    const phoneTitle = await page.locator('#task-title').boundingBox();
    for (const dimension of ['x', 'y', 'width', 'height']) {
      expect(Math.abs(phoneTitle[dimension] - phoneAnchor[dimension])).toBeLessThan(1);
    }
    await page.screenshot({path:'artifacts/e2e/stable-task-dialog.png', fullPage:true});
    await page.locator('#task-title').press('Enter');
    await expect(taskRow(page, 'Phone draft').getByRole('textbox', {name:'Description', exact:true})).toHaveValue('Retained after cancel and outside click');
    await expect(taskRow(page, 'Phone draft')).toHaveAttribute('data-group', 'Draft group');
    await expect(quick).toHaveValue('');
    await expect(quick).toBeFocused();
    await quick.click();
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-title')).toHaveValue('');
    await page.locator('#task-title').press('Escape');
    await expect(dialog).toBeHidden();
  });
  await test.step('Recover a lost Google response without duplicates', async () => {
    const retryTitle = 'Recover lost Google response';
    await request.post('http://127.0.0.1:4010/__fail-create');
    const retryRow = await createTask(page, retryTitle, {due:'2030-06-02', assignee:'Will'});
    const retryId = Number(await retryRow.getAttribute('data-task-id'));
    await expect.poll(async () => (await googleState(request)).jobs.find(j => j.worker === 'To.SyncWorker' && j.args.task_id === retryId)?.state).toBe('retryable');
    await expect(page.locator('#sync-status')).toHaveAttribute('data-state', 'retrying');
    await expect(page.locator('[data-task-id] small')).toHaveCount(0);
    // Sync progress remains global when the user looks at a different list.
    await page.getByRole('link', {name:'To do', exact:true}).click();
    await expect(page.locator('#sync-status')).toHaveAttribute('data-state', 'retrying');
    await request.post('http://127.0.0.1:4010/__retry-sync', {data:{title:retryTitle}});
    await expect.poll(async () => (await googleTasks(request, 'will')).filter(t => t.title === retryTitle).length).toBe(1);
    await expect.poll(async () => (await googleState(request)).jobs.find(j => j.worker === 'To.SyncWorker' && j.args.task_id === retryId)?.state).toBe('completed');
    await expect(page.locator('#sync-status')).toHaveAttribute('data-state', 'idle');
    const state = await googleState(request);
    await test.info().attach('google-http-exchange', {body: JSON.stringify(state, null, 2), contentType:'application/json'});
    await page.goto(listUrl);
  });

  // Finish the same household flow by deleting the list and its contents.
  const completedTitle = 'Milk, eggs and bread';
  await milkRow.getByRole('checkbox', {name: /^Complete /}).click();
  const activeTitle = 'Last grocery reminder';
  await createTask(page, activeTitle, {due:'2030-08-01', assignee:'Will'});
  await expect.poll(async () => (await googleTasks(request, 'will')).find(t => t.title === completedTitle)?.status).toBe('completed');
  await editTask(page, milkRow, {due:''});
  await expect.poll(async () => (await googleTasks(request, 'will')).some(t => t.title === completedTitle)).toBe(false);
  await editTask(page, milkRow, {due:'2030-05-03'});
  await expect.poll(async () => (await googleTasks(request, 'will')).find(t => t.title === completedTitle)?.status).toBe('completed');
  await expect.poll(async () => (await googleTasks(request, 'will')).some(t => t.title === activeTitle)).toBe(true);
  await expect.poll(() => reminderJobs(activeTitle).filter(j => j.state === 'scheduled').length).toBe(1);
  await test.step('Reschedule, deliver, and cancel the grocery reminder', async () => {
    const title = activeTitle;
    const row = taskRow(page, title);
    await editTask(page, row, {due:'2030-07-03'});
    await expect.poll(() => reminderJobs(title).find(j => j.state === 'scheduled')?.scheduled_at).toContain('2030-07-02T16:00:00');
    const original = reminderJobs(title).find(j => j.state === 'scheduled');
    // Default 09:00 in Los Angeles is 16:00 UTC during summer.
    expect(original.scheduled_at).toContain('2030-07-02T16:00:00');
    await page.getByRole('link', {name:'Settings for Will'}).click();
    const reminderTime = page.locator('input[type="time"]');
    await reminderTime.fill('08:30');
    await page.getByRole('button', {name:'Save time', exact:true}).click();
    await expect.poll(() => reminderJobs(title).find(j => j.state === 'scheduled')?.scheduled_at).toContain('2030-07-02T15:30:00');
    await expect(page.getByText('Reminder time saved.', {exact:true})).toBeVisible();
    await page.getByRole('link', {name:'Back to lists'}).click();
    await page.goto(listUrl);
    await editTask(page, row, {due:'2030-12-03'});
    await expect.poll(() => reminderJobs(title).find(j => j.state === 'scheduled')?.scheduled_at).toContain('2030-12-02T16:30:00');
    const tomorrow = await page.evaluate(() => {
      const d = new Date(); d.setDate(d.getDate()+1);
      return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
  });
  await editTask(page, row, {due:tomorrow});
  // Today's reminder time may have elapsed, so saving tomorrow's due date
  // need not leave a scheduled job. Wait for the committed date before delivery.
  await expect.poll(() => reminderJobs(title)[0]?.due_on).toBe(tomorrow);
  await request.post('http://127.0.0.1:4010/__run-reminder', {data:{title}});
  await expect.poll(async () => (await googleState(request)).pushes.find(p => p.payload.body === title)?.payload.title).toBe('Due tomorrow');
  const encryptedPush = (await googleState(request)).encrypted_pushes.at(-1);
  expect(encryptedPush).toMatchObject({encoding:'aes128gcm', vapid:true, valid_encrypted_body:true});
  expect(encryptedPush.encrypted_bytes).toBeGreaterThan(103);
  await test.info().attach('encrypted-web-push', {body:JSON.stringify(encryptedPush,null,2), contentType:'application/json'});
  await row.getByRole('checkbox', {name: /^Complete /}).click();
  await expect.poll(() => reminderJobs(title).filter(j => j.state === 'scheduled').length).toBe(0);
  await test.info().attach('reminder-durable-jobs', {body:JSON.stringify(reminderJobs(title),null,2), contentType:'application/json'});
  await row.getByRole('checkbox', {name: /^Reopen /}).click();
  await editTask(page, row, {due:'2030-08-01'});
  await expect.poll(() => reminderJobs(title).filter(j => j.state === 'scheduled').length).toBe(1);
  });

  page.once('dialog', async dialog => {
    expect(dialog.message()).toContain('Groceries');
    expect(dialog.message()).toContain('all its tasks');
    await dialog.dismiss();
  });
  await page.getByRole('button', {name:'Delete list Groceries', exact:true}).click();
  await expect(taskRow(page, activeTitle)).toBeVisible();
  await expect(nicole).toHaveURL(listUrl);

  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', {name:'Delete list Groceries', exact:true}).click();
  for (const tab of [page, nicole]) {
    await expect(tab).toHaveURL(/\/lists$/);
    await expect(tab.getByRole('link', {name:'Groceries', exact:true})).toHaveCount(0);
    await expect(taskRow(tab, activeTitle)).toHaveCount(0);
    await expect(taskRow(tab, completedTitle)).toHaveCount(0);
  }
  await expect.poll(async () => (await googleTasks(request, 'will')).filter(t => [activeTitle, completedTitle].includes(t.title)).length).toBe(0);
  await expect.poll(() => reminderJobs(activeTitle).filter(j => ['scheduled', 'available', 'executing'].includes(j.state)).length).toBe(0);
  // A saved link to a deleted list recovers without resurrecting its contents.
  await page.goto(listUrl);
  await expect(page.getByRole('link', {name:'To do', exact:true})).toHaveAttribute('aria-current', 'page');
  await expect(page.locator('[data-task-id] input[value="No due date"]')).toHaveCount(0);

  // List names can be reused after deletion.
  await page.getByRole('button', {name:'New list', exact:true}).click();
  await page.locator('#list-name').fill('Groceries');
  await page.locator('#list-form').getByRole('button').click();
  await expect(page.getByText('Nothing to do.', {exact:true})).toBeVisible();
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', {name:'Delete list Groceries', exact:true}).click();
  await expect(page).toHaveURL(/\/lists$/);

  // The remaining list cannot be deleted; its tasks survive and it stays usable.
  const lastListUrl = await page.getByRole('link', {name:'To do', exact:true}).getAttribute('href');
  for (const tab of [page, nicole]) {
    await expect(tab.getByRole('button', {name:'Delete list To do', exact:true})).toHaveCount(0);
    await expect(taskRow(tab, 'Body typing')).toBeVisible();
  }
  await page.reload();
  await expect(page.getByRole('link', {name:'To do', exact:true})).toHaveAttribute('href', lastListUrl);
  await expect(page.getByRole('button', {name:'Delete list To do', exact:true})).toHaveCount(0);
  await expect(taskRow(page, 'Body typing')).toBeVisible();
  await createTask(page, 'Fresh start');
  await expect(taskRow(nicole, 'Fresh start')).toBeVisible();
  await page.screenshot({path:'artifacts/e2e/list-deleted.png', fullPage:true});
  await test.info().attach('list-deletion-google-and-reminders', {
    body:JSON.stringify({google:await googleState(request), reminders:reminderJobs(activeTitle)},null,2),
    contentType:'application/json'
  });
  await nicoleContext.close();
});

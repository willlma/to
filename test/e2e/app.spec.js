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

test('shared lists, keyboard entry, details, due ordering, groups, completion and reload', async ({page, browser}) => {
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

  const nicoleContext = await browser.newContext();
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

  const friday = await createTask(page, 'Friday groceries', {description:'Whole milk', due:'2030-05-03', assignee:'Nicole', group:'Dairy'});
  await createTask(page, 'Thursday produce', {due:'2030-05-02', group:'Produce'});
  const plain = await createTask(page, 'No due date');
  await expect(taskRow(nicole, 'Friday groceries')).toBeVisible();
  // Date order applies within a group, so compare two ungrouped rows.
  await createTask(page, 'Earlier ungrouped', {due:'2030-05-01'});
  await createTask(page, 'Later ungrouped', {due:'2030-05-04'});
  const titles = await page.locator('[data-task-id] input[name="task[title]"]').evaluateAll(inputs => inputs.map(input => input.value));
  expect(titles.findIndex(t => t.includes('Earlier ungrouped'))).toBeLessThan(titles.findIndex(t => t.includes('Later ungrouped')));
  expect(titles.findIndex(t => t.includes('Later ungrouped'))).toBeLessThan(titles.findIndex(t => t.includes('No due date')));

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

  const dairyInput = page.locator('input[data-group="Dairy"]');
  await dairyInput.fill('Cold food');
  await dairyInput.blur();
  await expect(page.locator('input[data-group="Cold food"]')).toHaveValue('Cold food');
  await expect(nicole.locator('input[data-group="Cold food"]')).toHaveValue('Cold food');
  await page.locator('input[data-group="Cold food"]').fill('Produce');
  await page.locator('input[data-group="Cold food"]').blur();
  await expect(page.locator('#merge-dialog')).toBeVisible();
  await page.getByRole('button', {name:'Choose another name', exact:true}).click();
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
  await page.getByRole('link', {name:'Back to lists'}).click();
  await page.goto(listUrl);

  const milk = taskRow(page, 'Friday groceries');
  const milkId = await milk.getAttribute('data-task-id');
  const milkRow = page.locator('[data-task-id="' + milkId + '"]');
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).fill('Milk and eggs');
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).press('Enter');
  await expect(taskRow(nicole, 'Milk and eggs')).toBeVisible();
  await milkRow.getByRole('textbox', {name:'Description', exact:true}).fill('Two cartons');
  await milkRow.getByRole('textbox', {name:'Description', exact:true}).press('Tab');
  await expect(taskRow(nicole, 'Milk and eggs').getByRole('textbox', {name:'Description', exact:true})).toHaveValue('Two cartons');
  await milkRow.getByRole('combobox', {name:'Assignee'}).selectOption({label:'Will'});
  await expect(taskRow(nicole, 'Milk and eggs').getByRole('combobox', {name:'Assignee'})).toHaveValue(await milkRow.getByRole('combobox', {name:'Assignee'}).inputValue());
  // A field-level save must preserve another person's concurrent edit.
  await milkRow.getByRole('textbox', {name:'Description', exact:true}).fill('Local draft');
  await taskRow(nicole, 'Milk and eggs').getByRole('textbox', {name:'Title', exact:true}).fill('Milk, eggs and bread');
  await taskRow(nicole, 'Milk and eggs').getByRole('textbox', {name:'Title', exact:true}).press('Enter');
  await expect(milkRow.getByRole('textbox', {name:'Title', exact:true})).toHaveValue('Milk, eggs and bread');
  await milkRow.getByRole('textbox', {name:'Description', exact:true}).press('Tab');
  await expect(taskRow(nicole, 'Milk, eggs and bread').getByRole('textbox', {name:'Description', exact:true})).toHaveValue('Local draft');
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).fill('');
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).press('Tab');
  await expect(milkRow.getByRole('alert')).toBeVisible();
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).fill('Milk, eggs and bread');
  await milkRow.getByRole('textbox', {name:'Title', exact:true}).press('Enter');
  await expect(milkRow.getByRole('alert')).toHaveCount(0);
  const disposable = await createTask(page, 'Delete inline');
  page.once('dialog', dialog => dialog.accept());
  await disposable.getByRole('button', {name:'Delete Delete inline', exact:true}).click();
  await expect(disposable).toHaveCount(0);
  await expect(taskRow(nicole, 'Delete inline')).toHaveCount(0);

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
    const controls = [row.querySelector('input[type="checkbox"]'), row.querySelector('select'), row.querySelector('.task-date'), row.querySelector(':scope > button')];
    return {centers:controls.map(el => {const r=el.getBoundingClientRect(); return r.y+r.height/2}), overflow:document.documentElement.scrollWidth > innerWidth};
  });
  expect(Math.max(...compact.centers)-Math.min(...compact.centers)).toBeLessThan(6);
  expect(compact.overflow).toBe(false);
  await page.screenshot({path:'artifacts/e2e/mobile-list.png', fullPage:true});
  await nicoleContext.close();
});

test('touch drag changes groups, cancels outside a target, and survives reload', async ({browser}) => {
  const context = await browser.newContext({viewport:{width:390,height:844}, isMobile:true, hasTouch:true});
  const page = await context.newPage();
  await signIn(page);
  await page.getByRole('button', {name:'New list', exact:true}).click();
  await page.locator('#list-name').fill('Touch grouping');
  await page.locator('#list-form').getByRole('button').click();
  await expect(page.getByRole('link', {name:'Touch grouping',exact:true})).toBeVisible();
  await createTask(page, 'Group anchor', {group:'Errands'});
  const row = await createTask(page, 'Touch task');
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
  const group = await page.locator('input[data-group="Errands"]').boundingBox();
  await drag({x:group.x+group.width/2,y:group.y+group.height/2});
  await expect(row).toHaveAttribute('data-group','Errands');
  await expect(row.getByRole('checkbox')).not.toBeChecked();
  await drag({x:380,y:10});
  await expect(row).toHaveAttribute('data-group','Errands');
  await expect(row.getByRole('checkbox')).not.toBeChecked();
  await page.reload();
  await expect(page.locator('[data-task-id="'+id+'"]').getByRole('textbox', {name:'Title',exact:true})).toHaveValue('Touch task');
  await expect(page.locator('[data-task-id="'+id+'"]')).toHaveAttribute('data-group','Errands');
  await page.screenshot({path:'artifacts/e2e/touch-grouping.png',fullPage:true});
  await context.close();
});

test('OAuth denies unknown identities and invalid state', async ({page}) => {
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

test('durable Google export follows completion, reassignment and removed eligibility', async ({page, browser, request}) => {
  const context = await browser.newContext();
  await signIn(await context.newPage(), 'Nicole');
  await context.close();
  await signIn(page);
  const title = 'Google synchronization';
  const row = await createTask(page, title, {due:'2030-06-01', assignee:'Will'});
  await expect.poll(async () => (await googleTasks(request, 'will')).find(t => t.title === title)?.due).toBe('2030-06-01T00:00:00Z');
  await row.getByRole('checkbox', {name: /^Complete /}).click();
  await expect.poll(async () => (await googleTasks(request, 'will')).find(t => t.title === title)?.status).toBe('completed');
  await editTask(page, row, {assignee:'Nicole'});
  await expect.poll(async () => (await googleTasks(request, 'will')).some(t => t.title === title)).toBe(false);
  await expect.poll(async () => (await googleTasks(request, 'nicole')).find(t => t.title === title)?.status).toBe('completed');
  await editTask(page, row, {due:''});
  await expect.poll(async () => (await googleTasks(request, 'nicole')).some(t => t.title === title)).toBe(false);
  await page.reload();
  await expect(taskRow(page, title)).toBeVisible();
  const retryTitle = 'Recover lost Google response';
  await request.post('http://127.0.0.1:4010/__fail-create');
  const retryRow = await createTask(page, retryTitle, {due:'2030-06-02', assignee:'Will'});
  const retryId = Number(await retryRow.getAttribute('data-task-id'));
  await expect.poll(async () => (await googleState(request)).jobs.find(j => j.worker === 'To.SyncWorker' && j.args.task_id === retryId)?.state).toBe('retryable');
  await expect(retryRow.getByText('Sync retrying', {exact:true})).toBeVisible();
  await request.post('http://127.0.0.1:4010/__retry-sync', {data:{title:retryTitle}});
  await expect.poll(async () => (await googleTasks(request, 'will')).filter(t => t.title === retryTitle).length).toBe(1);
  await expect.poll(async () => (await googleState(request)).jobs.find(j => j.worker === 'To.SyncWorker' && j.args.task_id === retryId)?.state).toBe('completed');
  const state = await googleState(request);
  await test.info().attach('google-http-exchange', {body: JSON.stringify(state, null, 2), contentType:'application/json'});
});

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

test('day-before reminders use device timezone, reschedule and cancel on completion', async ({page, request}) => {
  await signIn(page);
  const title = 'Reminder scheduling';
  const row = await createTask(page, title, {due:'2030-07-03', assignee:'Will'});
  await expect.poll(() => reminderJobs(title).filter(j => j.state === 'scheduled').length).toBe(1);
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
});

test('quick entry validation belongs to its input and clears after saving', async ({page}) => {
  await signIn(page);
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

test('ungrouped todos precede groups while preserving due-date order', async ({page}) => {
  await signIn(page);
  await page.getByRole('button', {name:'New list', exact:true}).click();
  await page.locator('#list-name').fill('Grouping order');
  await page.locator('#list-form').getByRole('button').click();
  await createTask(page, 'Grouped early', {due:'2030-01-01', group:'Groceries'});
  await createTask(page, 'Ungrouped undated');
  await createTask(page, 'Ungrouped dated', {due:'2030-02-01'});
  const titles = page.locator('[data-task-id] input[name="task[title]"]');
  await expect(titles).toHaveCount(3);
  expect(await titles.nth(0).inputValue()).toBe('Ungrouped dated');
  expect(await titles.nth(1).inputValue()).toBe('Ungrouped undated');
  expect(await titles.nth(2).inputValue()).toBe('Grouped early');
  await page.reload();
  await expect(titles.nth(0)).toHaveValue('Ungrouped dated');
  await expect(titles.nth(1)).toHaveValue('Ungrouped undated');
  await expect(titles.nth(2)).toHaveValue('Grouped early');
});


test('quick entry becomes an anchored dialog and group plus prepopulates it', async ({page}) => {
  await signIn(page);
  const row = await createTask(page, 'Modal fixture', {group:'Modal groceries'});
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
  expect((await row.boundingBox()).y).toBe(before.y);
  expect(Math.abs((await dialog.boundingBox()).y - anchor.y)).toBeLessThan(2);
  await page.locator('#task-title').press('Escape');
  await expect(dialog).toBeHidden();
  await expect(quick).toHaveValue('');
  await page.getByRole('button', {name:'Add todo to Modal groceries', exact:true}).click();
  await expect(dialog).toBeVisible();
  await expect(page.locator('#task-group')).toHaveValue('Modal groceries');
  await page.locator('#task-title').fill('Added via group');
  await page.locator('#task-description').fill('In the same dialog');
  await page.getByRole('button', {name:'Add', exact:true}).click();
  await expect(dialog).toBeHidden();
  await expect(taskRow(page, 'Added via group')).toHaveAttribute('data-group', 'Modal groceries');
  await quick.fill('Next todo');
  await expect(page.locator('#task-group')).toHaveValue('');
  await page.getByRole('button', {name:'Cancel', exact:true}).click();
  await expect(dialog).toBeHidden();
  await expect(quick).toBeFocused();
  await quick.fill('Outside click draft');
  await dialog.click({position:{x:2,y:2}});
  await expect(dialog).toBeVisible();
  await page.mouse.click(2, 2);
  await expect(dialog).toBeHidden();
  await expect(quick).toHaveValue('');
  await expect(quick).toBeFocused();
  await page.setViewportSize({width:390,height:844});
  await quick.fill('Phone draft');
  await expect(dialog).toBeVisible();
  const bounds = await dialog.boundingBox();
  expect(bounds.x).toBeGreaterThanOrEqual(0);
  expect(bounds.x + bounds.width).toBeLessThanOrEqual(390);
});

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
  await expect(page).toHaveURL(/\/lists(?:\/\d+)?$/);
  const listUrl = page.url();
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
  await expect(page.getByRole('dialog')).toBeHidden();
  await expect(page).toHaveURL(listUrl);
  const id = await row.getAttribute('data-task-id');
  return page.locator('[data-task-id="' + id + '"]');
}

async function expectAnchoredDialog(page, anchor) {
  anchor ||= await page.locator('#quick-title').boundingBox();
  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();
  await expect.poll(async () => {
    const title = await page.locator('#task-title').boundingBox();
    return Math.max(...['x','y','height'].map(key => Math.abs(title[key] - anchor[key])));
  }).toBeLessThan(1);
  const submit = dialog.locator('button[type="submit"]');
  await expect(submit).toBeVisible();
  const button = await submit.boundingBox();
  const title = await page.locator('#task-title').boundingBox();
  expect(Math.abs(button.y - title.y), 'Task creation and editing keep submit inline with the title').toBeLessThan(1);
  expect(button.x).toBeGreaterThanOrEqual(title.x + title.width);
  const bounds = await dialog.boundingBox();
  expect(bounds.x).toBe(0);
  expect(bounds.width).toBe(page.viewportSize().width);
  expect(Math.abs(bounds.y - anchor.y)).toBeLessThan(1);
  expect(Math.abs(bounds.y + bounds.height - page.viewportSize().height)).toBeLessThan(1);
  const header = await page.locator('header').boundingBox();
  expect(header.y).toBeGreaterThanOrEqual(0);
  expect(header.y + header.height).toBeLessThanOrEqual(bounds.y);
  await expect(page.getByRole('navigation', {name:'Lists',includeHidden:true})).toBeVisible();
}

async function expectListDialogActions(dialog) {
  const save = await dialog.getByRole('button', {name:'Save',exact:true}).boundingBox();
  const cancel = await dialog.getByRole('button', {name:'Cancel',exact:true}).boundingBox();
  expect(Math.abs(save.y - cancel.y)).toBeLessThan(1);
  expect(cancel.x - (save.x + save.width)).toBeGreaterThanOrEqual(0);
  expect(cancel.x - (save.x + save.width)).toBeLessThan(16);
  const trash = dialog.getByRole('button', {name:/^Delete/});
  if (await trash.count()) {
    const bounds = await trash.boundingBox();
    const actions = await dialog.locator('.dialog-actions').boundingBox();
    expect(bounds.x).toBeGreaterThan(cancel.x + cancel.width);
    expect(Math.abs(bounds.x + bounds.width - actions.x - actions.width)).toBeLessThan(1);
  }
}

async function deleteTask(page, row) {
  await expect(row.getByRole('button', {name:/^Delete /})).toHaveCount(0);
  await row.getByRole('button', {name:/^Edit /}).click();
  const dialog = page.getByRole('dialog', {name:'Edit todo',exact:true});
  await dialog.getByRole('button', {name:'Delete',exact:true}).click();
  await expect(dialog).toBeHidden();
  await expect(row).toHaveCount(0);
  await expect(page.locator('#quick-title')).toBeFocused();
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
  const mockNotifications = subscription => {
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
  };
  await page.context().addInitScript(mockNotifications, deviceSubscription);
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
  await test.step('Omit update history for a legacy task with matching timestamps', async () => {
    await taskRow(page, 'Unedited legacy fixture').getByRole('button', {name:'Edit Unedited legacy fixture',exact:true}).click();
    const history = page.locator('#task-history');
    await expect(history).toContainText('Created by Will');
    await expect(history).not.toContainText(/Updated|Changed:/);
    await expect(history.locator('time')).toHaveCount(1);
    await page.screenshot({path:'artifacts/e2e/task-history-legacy-unedited.png',fullPage:true});
    await page.getByRole('button', {name:'Cancel',exact:true}).click();
  });
  await test.step('Separate completions at local midnight and restore reopened tasks', async () => {
    const completed = page.locator('#completed-tasks');
    const recent = taskRow(page, 'Recent completion fixture');
    await expect(completed).not.toHaveAttribute('open', '');
    await expect(completed.locator('[data-task-id]')).toHaveCount(1);
    await expect(completed.locator('summary')).toHaveText('Completed (1)');
    await expect(page.locator('#completed-tasks ~ section')).toHaveCount(0);
    await expect(recent).toBeVisible();
    await expect(recent.getByRole('checkbox')).toBeChecked();
    await recent.getByRole('button', {name:'Edit Recent completion fixture',exact:true}).click();
    await expect(page.locator('#task-history')).toContainText('Created by Will');
    await expect(page.locator('#task-history p').nth(1)).toContainText('Updated by Nicole at');
    await expect(page.locator('#task-history')).not.toContainText(/unavailable|weren’t recorded|Changed:/);
    await page.screenshot({path:'artifacts/e2e/task-history-legacy-other-editor.png',fullPage:true});
    await page.getByRole('button', {name:'Cancel',exact:true}).click();
    await expect(page.locator('section[data-drop-group="Housekeeping"]').locator('[data-task-id]')).toHaveCount(1);
    await completed.locator('summary').click();
    const archived = taskRow(page, 'Archived fixture');
    await expect(archived).toBeVisible();
    await page.screenshot({path:'artifacts/e2e/completed-section.png', fullPage:true});
    const editArchived = archived.getByRole('button', {name:'Edit Archived fixture',exact:true});
    await editArchived.click();
    await expect(page.getByRole('dialog', {name:'Edit todo',exact:true})).toBeVisible();
    await expect(page.locator('#task-title')).toHaveValue('Archived fixture');
    await expect(page.locator('#task-history')).toContainText('Created by Will');
    await expect(page.locator('#task-history p').nth(1)).toContainText('Updated at');
    await expect(page.locator('#task-history p').nth(1)).not.toContainText('by Will');
    await expect(page.locator('#task-history')).not.toContainText(/unavailable|weren’t recorded|Changed:/);
    await page.screenshot({path:'artifacts/e2e/task-history-legacy-same-editor.png',fullPage:true});
    await page.locator('#task-title').press('Escape');
    await expect(editArchived).toBeFocused();
    await archived.getByRole('checkbox').uncheck();
    await expect(completed).toHaveCount(0);
    await expect(page.locator('section[data-drop-group="Housekeeping"]').locator('[data-task-id]')).toHaveCount(2);
    await expect(archived.getByRole('checkbox')).not.toBeChecked();
    await page.reload();
    await expect(archived).toBeVisible();
    await expect(archived.getByRole('checkbox')).not.toBeChecked();
    // Completing again keeps the task in place until the next local midnight.
    await archived.getByRole('checkbox').check();
    await expect(archived).toBeVisible();
    await expect(completed).toHaveCount(0);
  });

  const nicoleContext = await browser.newContext({viewport:{width:390,height:844}, isMobile:true, hasTouch:true});
  const nicoleSubscription = {...deviceSubscription, endpoint:'https://fcm.googleapis.com/nicole-e2e'};
  await nicoleContext.addInitScript(mockNotifications, nicoleSubscription);
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
  await test.step('Edit list names without exposing deletion in the header', async () => {
    const dialog = page.getByRole('dialog',{name:'Edit list',exact:true});
    const name = dialog.getByRole('textbox',{name:'List name',exact:true});
    const url = page.url();
    await expect(page.locator('header').getByRole('button',{name:/^Delete list/})).toHaveCount(0);
    await expect(page.getByRole('navigation',{name:'Lists'}).getByRole('button',{name:/^Edit list/})).toHaveCount(1);
    await page.getByRole('button',{name:'Edit list Groceries',exact:true}).click();
    await expect(name).toBeFocused();
    await expectListDialogActions(dialog);
    expect(await name.evaluate(el => [el.selectionStart,el.selectionEnd])).toEqual([0,'Groceries'.length]);
    await page.screenshot({path:'artifacts/e2e/edit-list-desktop.png',fullPage:true});
    await name.fill('Discard this name');
    await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
    await expect(dialog).toBeHidden();
    await expect(page.getByRole('button',{name:'Edit list Groceries',exact:true})).toBeFocused();
    await page.getByRole('button',{name:'Edit list Groceries',exact:true}).click();
    await expect(name).toHaveValue('Groceries');
    await name.fill('Also discard this name');
    await name.press('Escape');
    await expect(dialog).toBeHidden();
    await expect(nicole.getByRole('link',{name:'Groceries',exact:true})).toBeVisible();

    await page.getByRole('button',{name:'Edit list Groceries',exact:true}).click();
    await name.fill('To do');
    await dialog.getByRole('button',{name:'Save',exact:true}).click();
    await expect(dialog.getByRole('alert')).toContainText('has already been taken');
    await expect(nicole.getByRole('link',{name:'Groceries',exact:true})).toBeVisible();
    await name.fill('   ');
    await dialog.getByRole('button',{name:'Save',exact:true}).click();
    await expect(dialog.getByRole('alert')).toContainText("can't be blank");
    await name.fill(' Errands ');
    await name.press('Enter');
    await expect(dialog).toBeHidden();
    for (const tab of [page,nicole]) {
      await expect(tab.getByRole('link',{name:'Errands',exact:true})).toHaveAttribute('aria-current','page');
      await expect(taskRow(tab,'Friday groceries')).toBeVisible();
      await expect(tab).toHaveURL(url);
    }
    const mobileDialog = nicole.getByRole('dialog',{name:'Edit list',exact:true});
    await nicole.getByRole('button',{name:'Edit list Errands',exact:true}).tap();
    await expectListDialogActions(mobileDialog);
    await page.screenshot({path:'artifacts/e2e/list-renamed.png',fullPage:true});
    await nicole.screenshot({path:'artifacts/e2e/edit-list-mobile.png',fullPage:true});
    await mobileDialog.getByRole('textbox',{name:'List name',exact:true}).fill('Groceries');
    await mobileDialog.getByRole('button',{name:'Save',exact:true}).click();
    await expect(mobileDialog).toBeHidden();
    await expect(page.getByRole('link',{name:'Groceries',exact:true})).toBeVisible();
    await page.reload();
    await expect(page.getByRole('link',{name:'Groceries',exact:true})).toHaveAttribute('aria-current','page');
  });
  // Date order applies within a group, so compare two ungrouped rows.
  await createTask(page, 'Earlier ungrouped', {due:'2030-05-01'});
  await createTask(page, 'Later ungrouped', {due:'2030-05-04'});
  const titles = await page.locator('[data-task-id] input[name="task[title]"]').evaluateAll(inputs => inputs.map(input => input.value));
  expect(titles.findIndex(t => t.includes('Earlier ungrouped'))).toBeLessThan(titles.findIndex(t => t.includes('Later ungrouped')));
  expect(titles.findIndex(t => t.includes('No due date'))).toBeLessThan(titles.findIndex(t => t.includes('Later ungrouped')));
  expect(titles.findIndex(t => t.includes('No due date'))).toBeLessThan(titles.findIndex(t => t.includes('Friday groceries')));
  expect(titles.findIndex(t => t.includes('No due date'))).toBeLessThan(titles.findIndex(t => t.includes('Thursday produce')));

  await test.step('Show years, highlight overdue dates only, and put distant dates after undated tasks', async () => {
    const today = new Date().toISOString().slice(0, 10);
    const year = Number(today.slice(0, 4));
    const offsetDate = days => {
      const date = new Date(today + 'T12:00:00Z');
      date.setUTCDate(date.getUTCDate() + days);
      return date.toISOString().slice(0, 10);
    };
    const fixtures = [
      ['Previous year', `${year - 1}-06-15`],
      ['Current year', `${year}-06-15`],
      ['Next year', `${year + 1}-06-15`],
      ['Yesterday', offsetDate(-1)],
      ['Today', today],
      ['Within 30 days', offsetDate(30)],
      ['Beyond 30 days', offsetDate(31)]
    ];
    for (const [title, due] of fixtures) await createTask(page, title, {due});
    await expect(taskRow(page, 'Previous year').locator('.task-date span')).toHaveText(`Jun 15, ${year - 1}`);
    await expect(taskRow(page, 'Current year').locator('.task-date span')).toHaveText('Jun 15');
    await expect(taskRow(page, 'Next year').locator('.task-date span')).toHaveText(`Jun 15, ${year + 1}`);
    const yesterday = taskRow(page, 'Yesterday');
    await expect(yesterday).toHaveClass(/overdue/);
    await expect(taskRow(page, 'Today')).not.toHaveClass(/overdue/);
    await page.emulateMedia({colorScheme:'light'});
    await expect(yesterday.locator('.task-date')).toHaveCSS('color', 'rgb(154, 52, 18)');
    await expect(yesterday.locator('.task-title')).toHaveCSS('color', await taskRow(page, 'Today').locator('.task-title').evaluate(el => getComputedStyle(el).color));
    await page.emulateMedia({colorScheme:'dark'});
    await expect(yesterday.locator('.task-date')).toHaveCSS('color', 'rgb(251, 146, 60)');
    await expect(yesterday.locator('.task-title')).toHaveCSS('color', await taskRow(page, 'Today').locator('.task-title').evaluate(el => getComputedStyle(el).color));
    await page.emulateMedia({colorScheme:'light'});
    const ordered = await page.locator('[data-task-id] input[name="task[title]"]').evaluateAll(inputs => inputs.map(input => input.value));
    expect(ordered.indexOf('Within 30 days')).toBeLessThan(ordered.indexOf('No due date'));
    expect(ordered.indexOf('No due date')).toBeLessThan(ordered.indexOf('Beyond 30 days'));
    await yesterday.getByRole('checkbox').check();
    await expect(yesterday).not.toHaveClass(/overdue/);
    await page.screenshot({path:'artifacts/e2e/deadlines.png', fullPage:true});
    for (const [title] of fixtures) await deleteTask(page, taskRow(page, title));
  });

  await test.step('Move between lists without losing task details', async () => {
    const transfer = await createTask(page, 'Transfer details', {
      description:'Keep these notes', due:'2030-05-03', assignee:'Nicole', group:'Dairy'
    });
    const transferId = Number(await transfer.getAttribute('data-task-id'));
    await expect.poll(async () => (await googleState(request)).jobs.filter(j => j.worker === 'To.SyncWorker' && j.args.task_id === transferId).at(-1)?.state).toBe('completed');
    const remote = (await googleTasks(request,'nicole')).find(t => t.title === 'Transfer details');
    const beforeSync = await googleState(request);
    const source = page.getByRole('link', {name:'To do', exact:true});
    await transfer.getByRole('checkbox').dragTo(source);
    await expect(transfer).toHaveCount(0);
    await expect(taskRow(nicole, 'Transfer details')).toHaveCount(0);
    await source.click();
    const moved = taskRow(page, 'Transfer details');
    await expect(moved).toHaveAttribute('data-group', '');
    await expect(moved.getByLabel('Description', {exact:true})).toHaveValue('Keep these notes');
    await expect(moved.getByLabel('Due date', {exact:true})).toHaveValue('2030-05-03');
    await expect(moved.getByLabel('Assignee', {exact:true}).locator('option:checked')).toHaveText('Nicole');
    await expect(moved.getByRole('checkbox')).not.toBeChecked();
    await moved.getByRole('button',{name:'Edit Transfer details',exact:true}).click();
    await expect(page.locator('#task-history')).toContainText('Changed: Group, list.');
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    await expect(page.getByRole('dialog')).toBeHidden();
    await expect(moved.getByRole('button',{name:'Edit Transfer details',exact:true})).toBeFocused();
    await moved.getByRole('checkbox').press('Alt+ArrowRight');
    await expect(moved).toHaveCount(0);
    await page.getByRole('link', {name:'Groceries', exact:true}).click();
    await expect(transfer).toBeVisible();
    await expect(taskRow(nicole, 'Transfer details')).toBeVisible();
    await transfer.getByRole('button',{name:'Edit Transfer details',exact:true}).click();
    await page.locator('#task-group').fill('Quiet group');
    await page.getByRole('dialog').getByRole('button',{name:'Save',exact:true}).click();
    await expect(transfer).toHaveAttribute('data-group','Quiet group');
    await transfer.getByRole('button',{name:'Edit Transfer details',exact:true}).click();
    await expect(page.locator('#task-history')).toContainText('Changed: Group.');
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    const afterSync = await googleState(request);
    const syncJobs = state => state.jobs.filter(j => j.worker === 'To.SyncWorker' && j.args.task_id === transferId);
    const remoteCalls = state => state.calls.filter(c => c.path.endsWith('/'+remote.id));
    expect(syncJobs(afterSync)).toEqual(syncJobs(beforeSync));
    expect(remoteCalls(afterSync)).toEqual(remoteCalls(beforeSync));
    // Reconnecting/replaying a sync must not resend an unchanged payload.
    await request.post('http://127.0.0.1:4010/__sync-google',{data:{person:'Nicole'}});
    await expect.poll(async () => syncJobs(await googleState(request)).at(-1)?.state).toBe('completed');
    expect(remoteCalls(await googleState(request))).toEqual(remoteCalls(beforeSync));
    await deleteTask(page, transfer);
  });

  // Moving groups must persist across browsers, preserve completion and keep due-date sorting.
  const inGroup = (tab, group) => tab.locator('section').filter({has:tab.locator('input[data-group=' + JSON.stringify(group) + ']')});
  await plain.getByRole('checkbox').dragTo(page.locator('input[data-group="Dairy"]'));
  await expect(inGroup(nicole, 'Dairy').locator('[data-task-id]').filter({has:nicole.locator('input[value="No due date"]')})).toBeVisible();
  await expect(plain.getByRole('checkbox')).not.toBeChecked();
  await friday.getByRole('checkbox').dragTo(page.locator('input[data-group="Produce"]'));
  await expect(inGroup(nicole, 'Produce').locator('[data-task-id]').filter({has:nicole.locator('input[value="Friday groceries"]')})).toBeVisible();
  await friday.getByRole('checkbox').dragTo(page.locator('input[data-group="Dairy"]'));
  await expect(inGroup(page, 'Dairy').locator('input[value="Friday groceries"]')).toBeVisible();
  await test.step('Highlight one target around all ungrouped tasks', async () => {
    const ungrouped = page.locator('section[data-drop-group=""]');
    await expect(ungrouped).toHaveCount(1);
    await expect(ungrouped.locator('[data-task-id]')).toHaveCount(3);
    await expect(page.locator('#ungroup-target')).toHaveCount(0);
    const grip = await plain.getByRole('checkbox').boundingBox();
    const target = await taskRow(page, 'Earlier ungrouped').boundingBox();
    await page.mouse.move(grip.x + grip.width / 2, grip.y + grip.height / 2);
    await page.mouse.down();
    await page.mouse.move(target.x + target.width / 2, target.y + target.height / 2, {steps:8});
    await expect(ungrouped).toHaveClass('drop-target');
    await expect(ungrouped).toHaveCSS('outline-style', 'dashed');
    await expect(page.locator('.drop-target')).toHaveCount(1);
    await expect(ungrouped.locator('.drop-target')).toHaveCount(0);
    await page.screenshot({path:'artifacts/e2e/ungrouped-drop-target.png',fullPage:true});
    await page.mouse.up();
  });
  await expect(plain).toHaveAttribute('data-group', '');
  await expect(taskRow(nicole, 'No due date')).toHaveAttribute('data-group', '');
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
  await expect(friday.locator('button[phx-click="edit-task"]')).toBeVisible();
  const listUrl = page.url();
  await expect(page.locator('#reminder-form')).toBeHidden();
  await page.getByRole('link', {name:'Settings for Will'}).click();
  await expect(page).toHaveURL(/\/settings$/);
  await expect(page.getByRole('heading', {name:'Settings', exact:true})).toBeVisible();
  await expect(page.locator('#task-form')).toHaveCount(0);
  await expect(page.locator('#reminder-form')).toBeVisible();
  await expect(page.locator('#enable-notifications')).toHaveCSS('margin-top', '16px');
  const importBounds = await page.getByRole('button', {name:'Import Google Tasks',exact:true}).boundingBox();
  const signOutBounds = await page.getByRole('button', {name:'Sign out',exact:true}).boundingBox();
  expect(signOutBounds.y - importBounds.y - importBounds.height).toBeGreaterThanOrEqual(12);
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
    expect((await googleState(request)).encrypted_pushes.at(-1)).toMatchObject({vapid:true,valid_encrypted_body:true,valid_topic:true});
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
  const disposable = await createTask(page, 'Delete inline', {description:'Deleting from the dialog needs no confirmation'});
  const unexpectedDialogs = [];
  const unexpectedDialog = async dialog => { unexpectedDialogs.push(dialog.message()); await dialog.dismiss(); };
  page.on('dialog', unexpectedDialog);
  await deleteTask(page, disposable);
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
    const controls = [row.querySelector('input[type="checkbox"]'), row.querySelector('.task-title'), row.querySelector('select'), row.querySelector('.task-date'), ...row.querySelectorAll(':scope > button')];
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

  await test.step('Hide compact description scrollbars and scroll while editing', async () => {
    const description = plain.getByRole('textbox', {name:'Description', exact:true});
    const original = await description.inputValue();
    const longDescription = Array.from({length:12}, (_, i) => `Description line ${i + 1}`).join('\n');
    await description.fill(longDescription);
    await description.press('Tab');
    await expect(description).toHaveCSS('overflow-y', 'hidden');
    await page.screenshot({path:'artifacts/e2e/compact-description.png',fullPage:true});
    await description.click();
    await expect(description).toHaveCSS('overflow-y', 'auto');
    await expect(description).toHaveCSS('height', '80px');
    expect(await description.evaluate(el => {
      el.scrollTop = el.scrollHeight;
      return el.scrollTop;
    })).toBeGreaterThan(0);
    await description.press('Tab');
    await plain.getByRole('textbox', {name:'Title',exact:true}).click();
    await expect(plain.getByRole('textbox', {name:'Title',exact:true})).toBeFocused();
    await expect(page.locator('#task-dialog')).toBeHidden();
    await expect(description).toHaveCSS('overflow-y', 'hidden');
    await description.fill(original);
    await description.press('Tab');
  });

  await test.step('Keep quick entry fixed with Add inline, show list tabs, and cover tasks with the dialog', async () => {
    const row = milkRow;
    await page.setViewportSize({width:1280,height:800});
    const before = await row.boundingBox();
    const quick = page.locator('#quick-title');
    const anchor = await quick.boundingBox();
    const header = await page.locator('header').boundingBox();
    await expect(page.getByRole('button', {name:'Add', exact:true})).toBeHidden();
    await quick.fill('Typing opens details');
    const dialog = page.getByRole('dialog', {name:'New todo'});
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-title')).toHaveValue('Typing opens details');
    await expect(page.locator('#task-title')).toBeFocused();
    await expect(page.locator('#task-description')).toBeVisible();
    await expectAnchoredDialog(page, anchor);
    expect(await page.locator('header').boundingBox()).toEqual(header);
    await page.screenshot({path:'artifacts/e2e/anchored-task-dialog-desktop.png',fullPage:true});
    await expect(page.locator('#task-title')).toHaveAttribute('enterkeyhint', 'done');
    expect(await dialog.evaluate(el => getComputedStyle(el).backgroundColor)).toBe(await page.locator('body').evaluate(el => getComputedStyle(el).backgroundColor));
    expect(await dialog.evaluate(el => getComputedStyle(el, '::backdrop').backgroundColor)).toBe('rgba(0, 0, 0, 0)');
    expect((await row.boundingBox()).y).toBe(before.y);
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
    await page.locator('#task-description').fill('Retained after cancel');
    await page.locator('#task-group').fill('Draft group');
    await page.getByRole('button', {name:'Cancel', exact:true}).click();
    await expect(dialog).toBeHidden();
    await expect(quick).toBeFocused();
    await expect(quick).toHaveValue('Next todo');
    await quick.fill('Cancelled draft');
    await expect(page.locator('#task-description')).toHaveValue('Retained after cancel');
    await expect(page.locator('#task-group')).toHaveValue('Draft group');
    await page.locator('#task-description').click();
    await expect(dialog).toBeVisible();
    await dialog.getByRole('button', {name:'Cancel', exact:true}).click();
    await expect(dialog).toBeHidden();
    await expect(quick).toHaveValue('Cancelled draft');
    await expect(quick).toBeFocused();
    // Real typing must work after dismissal, without focusing a locator first.
    await page.keyboard.type(' resumed');
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-title')).toHaveValue('Cancelled draft resumed');
    await dialog.getByRole('button', {name:'Cancel', exact:true}).click();
    await expect(dialog).toBeHidden();
    await expect(quick).toBeFocused();
    await page.setViewportSize({width:390,height:844});
    await page.emulateMedia({colorScheme:'dark'});
    const phoneAnchor = await quick.boundingBox();
    await quick.fill('Phone draft');
    await expect(dialog).toBeVisible();
    expect(await page.locator('#task-assignee').evaluate(el => getComputedStyle(el).backgroundColor)).toBe(await dialog.evaluate(el => getComputedStyle(el).backgroundColor));
    await expect(page.locator('#task-description')).toHaveValue('Retained after cancel');
    await expect(page.locator('#task-group')).toHaveValue('Draft group');
    await expectAnchoredDialog(page, phoneAnchor);
    await page.setViewportSize({width:360,height:320});
    await expectAnchoredDialog(page);
    expect(await dialog.evaluate(el => el.scrollHeight > el.clientHeight)).toBe(true);
    await dialog.getByRole('button', {name:'Cancel',exact:true}).scrollIntoViewIfNeeded();
    await expect(dialog.getByRole('button', {name:'Cancel',exact:true})).toBeInViewport();
    await page.setViewportSize({width:390,height:844});
    await expectAnchoredDialog(page);
    await page.screenshot({path:'artifacts/e2e/stable-task-dialog.png', fullPage:true});
    await page.locator('#task-title').press('Enter');
    await expect(taskRow(page, 'Phone draft').getByRole('textbox', {name:'Description', exact:true})).toHaveValue('Retained after cancel');
    await expect(taskRow(page, 'Phone draft')).toHaveAttribute('data-group', 'Draft group');
    await expect(quick).toHaveValue('');
    await expect(quick).toBeFocused();
    await quick.click();
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-title')).toHaveValue('');
    await page.locator('#task-title').press('Escape');
    await expect(dialog).toBeHidden();
  });
  await test.step('Dismiss outside clicks without moving quick entry or losing drafts', async () => {
    const measurements = [];
    const quick = page.locator('#quick-title');
    const dialog = page.getByRole('dialog', {name:'New todo',exact:true});
    const listUrl = page.url();
    for (const viewport of [{width:1280,height:800}, {width:390,height:844}]) {
      await page.setViewportSize(viewport);
      const before = await quick.boundingBox();
      const tab = await page.locator('nav a').first().boundingBox();
      const outside = [
        {name:'list tabs', x:tab.x + tab.width/2, y:tab.y + tab.height/2},
        {name:'side margin', x:2, y:before.y + 20},
        {name:'below the form', x:viewport.width/2, y:viewport.height - 2}
      ];
      for (const point of outside) {
        const title = `Outside click: ${viewport.width}, ${point.name}`;
        await quick.fill(title);
        await page.locator('#task-description').fill('Preserve outside-click notes');
        await page.locator('#task-due').fill('2031-01-02');
        await page.locator('#task-description').click();
        await expect(dialog).toBeVisible();
        await expectAnchoredDialog(page, before);
        const opened = await page.locator('#task-title').boundingBox();
        await page.mouse.click(point.x, point.y);
        await expect(dialog).toBeHidden();
        await expect(page).toHaveURL(listUrl);
        await expect(quick).toHaveValue(title);
        await expect(quick).toBeFocused();
        const after = await quick.boundingBox();
        expect(after).toEqual(before);
        measurements.push({viewport, outside:point.name, before, opened, after});
        await page.keyboard.press('End');
        await page.keyboard.type(' resumed');
        await expectAnchoredDialog(page, before);
        await expect(page.locator('#task-title')).toHaveValue(`${title} resumed`);
        await expect(page.locator('#task-description')).toHaveValue('Preserve outside-click notes');
        await expect(page.locator('#task-due')).toHaveValue('2031-01-02');
        await page.locator('#task-title').press('Escape');
        await expect(dialog).toBeHidden();
        expect(await quick.boundingBox()).toEqual(before);
      }
      await page.screenshot({path:`artifacts/e2e/outside-dismissal-${viewport.width}.png`,fullPage:true});
    }
    await test.info().attach('outside-click-input-positions', {
      body:JSON.stringify(measurements,null,2), contentType:'application/json'
    });
  });
  await test.step('Reopen row details, cancel edits, and save without losing a new-task draft', async () => {
    const row = await createTask(page, 'Dialog editing', {description:'Original details', due:'2030-09-04', assignee:'Will', group:'Dialog group'});
    const quick = page.locator('#quick-title');
    const dialog = page.getByRole('dialog', {name:'Edit todo', exact:true});
    await quick.fill('Unfinished new task');
    await page.locator('#task-description').fill('Keep my new-task notes');
    await page.getByRole('button', {name:'Cancel', exact:true}).click();
    await expect(page.locator('#task-dialog')).toBeHidden();
    const edit = row.getByRole('button', {name:'Edit Dialog editing', exact:true});
    await edit.focus();
    await edit.press('Enter');
    await expect(dialog).toBeVisible();
    await expect(page.locator('#task-title')).toBeFocused();
    await expect(page.locator('#task-title')).toHaveValue('Dialog editing');
    const history = page.locator('#task-history');
    await expect(history).toContainText('Created by Will');
    await expect(history).toContainText('No edits yet.');
    const createdAt = await history.locator('time').first().getAttribute('datetime');
    expect(Number.isNaN(Date.parse(createdAt))).toBe(false);
    await expect(page.locator('#task-description')).toHaveValue('Original details');
    await expect(page.locator('#task-due')).toHaveValue('2030-09-04');
    await expect(page.locator('#task-assignee').locator('option:checked')).toHaveText('Will');
    await expect(page.locator('#task-group')).toHaveValue('Dialog group');
    await expectAnchoredDialog(page);
    await page.screenshot({path:'artifacts/e2e/edit-task-dialog-mobile.png',fullPage:true});
    await page.locator('#task-description').fill('Discard these edits');
    await page.locator('#task-description').press('Escape');
    await expect(dialog).toBeHidden();
    await expect(edit).toBeFocused();
    await expect(row.getByRole('textbox', {name:'Description', exact:true})).toHaveValue('Original details');
    await expect(quick).toHaveValue('Unfinished new task');
    await quick.click();
    await expect(page.locator('#task-description')).toHaveValue('Keep my new-task notes');
    await page.getByRole('button', {name:'Cancel', exact:true}).click();
    await edit.click();
    await expect(page.locator('#task-description')).toHaveValue('Original details');
    await expect(history).toContainText('No edits yet.');
    await page.locator('#task-title').fill('Discard title');
    await page.mouse.click(2,2);
    await expect(dialog).toBeHidden();
    await expect(row.getByRole('textbox', {name:'Title',exact:true})).toHaveValue('Dialog editing');
    await expect(edit).toBeFocused();
    await page.setViewportSize({width:1280,height:800});
    await edit.click();
    await expectAnchoredDialog(page);
    await page.locator('#task-title').fill('Dialog edited');
    await page.locator('#task-description').fill('Saved details');
    await page.locator('#task-due').fill('2030-09-05');
    await page.locator('#task-assignee').selectOption({label:'Nicole'});
    await page.locator('#task-group').fill('Edited group');
    await page.screenshot({path:'artifacts/e2e/edit-task-dialog.png',fullPage:true});
    await dialog.getByRole('button', {name:'Save', exact:true}).click();
    await expect(dialog).toBeHidden();
    await expect(row.getByRole('button', {name:'Edit Dialog edited', exact:true})).toBeFocused();
    await expect(row.getByRole('textbox', {name:'Title',exact:true})).toHaveValue('Dialog edited');
    await expect(row.getByRole('textbox', {name:'Description',exact:true})).toHaveValue('Saved details');
    await expect(row.getByLabel('Due date', {exact:true})).toHaveValue('2030-09-05');
    await expect(row.getByRole('combobox', {name:'Assignee'}).locator('option:checked')).toHaveText('Nicole');
    await expect(row).toHaveAttribute('data-group','Edited group');
    await row.getByRole('button',{name:'Edit Dialog edited',exact:true}).click();
    await expect(history.locator('p').nth(1)).toContainText('Updated at');
    await expect(history).toContainText('Changed: Title, description, due date, assignee, group.');
    await expect(history.locator('time').first()).toHaveAttribute('datetime',createdAt);
    const editedAt = await history.locator('time').nth(1).getAttribute('datetime');
    expect(Date.parse(editedAt)).toBeGreaterThanOrEqual(Date.parse(createdAt));
    await page.screenshot({path:'artifacts/e2e/task-history.png',fullPage:true});
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    // Opening and saving without changes must not credit the other person with an edit.
    await taskRow(nicole,'Dialog edited').getByRole('button',{name:'Edit Dialog edited',exact:true}).tap();
    await nicole.getByRole('button',{name:'Save',exact:true}).click();
    await expect(nicole.getByRole('dialog')).toBeHidden();
    await row.getByRole('button',{name:'Edit Dialog edited',exact:true}).click();
    await expect(history.locator('p').nth(1)).toContainText('Updated at');
    await expect(history).toContainText('Changed: Title, description, due date, assignee, group.');
    await expect(history.locator('time').nth(1)).toHaveAttribute('datetime',editedAt);
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    await row.getByRole('checkbox').click();
    await row.getByRole('button', {name:'Edit Dialog edited', exact:true}).click();
    await page.locator('#task-description').fill('Completed task details');
    await taskRow(nicole, 'Dialog edited').getByRole('button', {name:'Edit Dialog edited',exact:true}).tap();
    const remoteTitle = nicole.locator('#task-title');
    await remoteTitle.fill('Dialog edited remotely');
    await remoteTitle.press('Enter');
    await expect(row.getByRole('textbox', {name:'Title',exact:true})).toHaveValue('Dialog edited remotely');
    await page.locator('#task-title').press('Enter');
    await expect(row.getByRole('textbox', {name:'Title',exact:true})).toHaveValue('Dialog edited remotely');
    await expect(row.getByRole('checkbox')).toBeChecked();
    await expect(row.getByRole('textbox', {name:'Description',exact:true})).toHaveValue('Completed task details');
    await row.getByRole('button',{name:'Edit Dialog edited remotely',exact:true}).click();
    await expect(history).toContainText('Created by Will');
    await expect(history.locator('p').nth(1)).toContainText('Updated at');
    await expect(history).toContainText('Changed: Description.');
    await expect(history.locator('time').first()).toHaveAttribute('datetime',createdAt);
    await page.getByRole('button',{name:'Cancel',exact:true}).click();
    await quick.click();
    await expect(page.locator('#task-title')).toHaveValue('Unfinished new task');
    await expect(page.locator('#task-description')).toHaveValue('Keep my new-task notes');
    await page.getByRole('button', {name:'Cancel', exact:true}).click();
    await deleteTask(page, row);
    await quick.click();
    await expect(page.locator('#task-title')).toHaveValue('Unfinished new task');
    await expect(page.locator('#task-description')).toHaveValue('Keep my new-task notes');
    await expect(page.getByRole('dialog').getByRole('button', {name:'Delete',exact:true})).toHaveCount(0);
    await page.getByRole('button', {name:'Cancel',exact:true}).click();
  });
  await test.step('Save locally and stay quiet during slow Google deletion', async () => {
    const title = 'Delete with slow sync completion';
    const row = await createTask(page, title, {due:'2030-10-02',assignee:'Will'});
    const id = Number(await row.getAttribute('data-task-id'));
    await expect.poll(async () => (await googleTasks(request, 'will')).some(t => t.title === title)).toBe(true);
    for (const tab of [page,nicole]) await expect(tab.locator('#sync-status')).toHaveAttribute('data-state','idle');
    await request.post('http://127.0.0.1:4010/__delay-sync-completion', {data:{task_id:id}});
    await deleteTask(page, row);
    const status = page.locator('#sync-status');
    await expect.poll(async () => (await googleState(request)).jobs.filter(j => j.worker === 'To.SyncWorker' && j.args.task_id === id).at(-1)?.state).toBe('executing');
    await expect.poll(async () => (await googleTasks(request, 'will')).some(t => t.title === title)).toBe(false);
    for (const tab of [page,nicole]) await expect(tab.locator('#sync-status')).toBeHidden();
    await expect(status.locator('svg')).toHaveCount(0);
    await page.screenshot({path:'artifacts/e2e/deletion-sync-pending.png',fullPage:true});
    await expect.poll(async () => (await googleState(request)).jobs.filter(j => j.worker === 'To.SyncWorker' && j.args.task_id === id).at(-1)?.state).toBe('completed');
    // No navigation, edits, or reload may be needed to clear either person's header.
    for (const tab of [page,nicole]) {
      await expect(tab.locator('#sync-status')).toHaveAttribute('data-state','idle');
      await expect(tab.locator('#sync-status')).toBeHidden();
    }
    await page.screenshot({path:'artifacts/e2e/deletion-sync-complete.png',fullPage:true});
    await test.info().attach('deletion-sync-completed-jobs', {
      body:JSON.stringify((await googleState(request)).jobs.filter(j => j.args.task_id === id),null,2),
      contentType:'application/json'
    });
  });
  await test.step('Recover a lost Google response without duplicates', async () => {
    const retryTitle = 'Recover lost Google response';
    await request.post('http://127.0.0.1:4010/__fail-create');
    const retryRow = await createTask(page, retryTitle, {due:'2030-06-02', assignee:'Will'});
    const retryId = Number(await retryRow.getAttribute('data-task-id'));
    await expect.poll(async () => (await googleState(request)).jobs.find(j => j.worker === 'To.SyncWorker' && j.args.task_id === retryId)?.state).toBe('retryable');
    await expect(page.locator('#sync-status')).toHaveText('Saved here. Google sync failed; retrying automatically.');
    await expect(page.locator('#sync-status')).toBeVisible();
    await expect(retryRow).toBeVisible();
    await expect(nicole.locator('#sync-status')).toBeVisible();
    await expect(page.locator('[data-task-id] small')).toHaveCount(0);
    // Sync progress remains global when the user looks at a different list.
    await page.getByRole('link', {name:'To do', exact:true}).click();
    await page.reload();
    await expect(page.locator('#sync-status')).toBeVisible();
    await page.screenshot({path:'artifacts/e2e/google-sync-failure.png',fullPage:true});
    await request.post('http://127.0.0.1:4010/__delay-sync-completion',{data:{task_id:retryId}});
    await request.post('http://127.0.0.1:4010/__retry-sync', {data:{title:retryTitle}});
    await expect.poll(async () => (await googleState(request)).jobs.find(j => j.worker === 'To.SyncWorker' && j.args.task_id === retryId)?.state).toBe('executing');
    await expect(page.locator('#sync-status')).toBeVisible();
    await expect.poll(async () => (await googleTasks(request, 'will')).filter(t => t.title === retryTitle).length).toBe(1);
    await expect.poll(async () => (await googleState(request)).jobs.find(j => j.worker === 'To.SyncWorker' && j.args.task_id === retryId)?.state).toBe('completed');
    for (const tab of [page,nicole]) await expect(tab.locator('#sync-status')).toBeHidden();
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
  expect(encryptedPush).toMatchObject({encoding:'aes128gcm', vapid:true, valid_encrypted_body:true,valid_topic:true});
  expect(encryptedPush.encrypted_bytes).toBeGreaterThan(103);
  await test.info().attach('encrypted-web-push', {body:JSON.stringify(encryptedPush,null,2), contentType:'application/json'});
  await row.getByRole('checkbox', {name: /^Complete /}).click();
  await expect.poll(() => reminderJobs(title).filter(j => j.state === 'scheduled').length).toBe(0);
  await test.info().attach('reminder-durable-jobs', {body:JSON.stringify(reminderJobs(title),null,2), contentType:'application/json'});
  await row.getByRole('checkbox', {name: /^Reopen /}).click();
  await editTask(page, row, {due:'2030-08-01'});
  await expect.poll(() => reminderJobs(title).filter(j => j.state === 'scheduled').length).toBe(1);
  });

  await page.getByRole('button',{name:'Edit list Groceries',exact:true}).click();
  page.once('dialog', async dialog => {
    expect(dialog.message()).toContain('Groceries');
    expect(dialog.message()).toContain('all its tasks');
    await dialog.dismiss();
  });
  await page.getByRole('button', {name:'Delete list Groceries', exact:true}).click();
  await expect(taskRow(page, activeTitle)).toBeVisible();
  await expect(page.getByRole('dialog',{name:'Edit list',exact:true})).toBeVisible();
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
  await page.getByRole('button',{name:'Edit list Groceries',exact:true}).click();
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', {name:'Delete list Groceries', exact:true}).click();
  await expect(page).toHaveURL(/\/lists$/);

  // The remaining list cannot be deleted; its tasks survive and it stays usable.
  const lastListUrl = await page.getByRole('link', {name:'To do', exact:true}).getAttribute('href');
  for (const tab of [page, nicole]) {
    await tab.getByRole('button',{name:'Edit list To do',exact:true}).click();
    const dialog = tab.getByRole('dialog',{name:'Edit list',exact:true});
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('button', {name:'Delete list To do', exact:true})).toHaveCount(0);
    await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
    await expect(dialog).toBeHidden();
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
  await test.step('Skip sync jobs for tasks that have no Google copy', async () => {
    const row = await createTask(page,'Never exported',{description:'Local task'});
    const id = Number(await row.getAttribute('data-task-id'));
    await row.getByRole('textbox',{name:'Description',exact:true}).fill('Local edit');
    await row.getByRole('textbox',{name:'Description',exact:true}).press('Tab');
    await row.getByRole('checkbox').check();
    await deleteTask(page,row);
    const state = await googleState(request);
    expect(state.jobs.filter(j => j.worker === 'To.SyncWorker' && j.args.task_id === id)).toEqual([]);
    expect(state.calls.filter(c => JSON.stringify(c.body).includes(`[to task ${id}]`))).toEqual([]);
  });
  await test.step('Keep local-only edits and deletions away from Google', async () => {
    const title = 'Local-only deletion';
    const row = await createTask(page,title,{due:'2030-10-03',assignee:'Will'});
    await expect.poll(async () => (await googleTasks(request,'will')).some(t => t.title === title)).toBe(true);
    await expect(page.locator('#sync-status')).toHaveAttribute('data-state','idle');
    await request.post('http://127.0.0.1:4010/__google-sync-enabled',{data:{enabled:false}});
    const before = await googleState(request);
    await deleteTask(page,row);
    await createTask(page,'Local-only task',{due:'2030-10-04',assignee:'Will'});
    await page.reload();
    await expect(taskRow(page,'Local-only task')).toBeVisible();
    await expect(page.locator('#sync-status')).toHaveAttribute('data-state','idle');
    await expect(page.locator('#sync-status')).toBeHidden();
    await page.getByRole('link',{name:'Settings for Will'}).click();
    await expect(page.getByText('Google sync is disabled for local development.',{exact:true})).toBeVisible();
    await expect(page.locator('#google-import-form')).toHaveCount(0);
    const after = await googleState(request);
    expect(after.calls).toEqual(before.calls);
    expect(after.jobs.filter(j => j.worker === 'To.SyncWorker')).toEqual(before.jobs.filter(j => j.worker === 'To.SyncWorker'));
    expect(Object.values(after.tasks.will).some(t => t.title === title)).toBe(true);
    await page.screenshot({path:'artifacts/e2e/local-google-sync-disabled.png',fullPage:true});
    await test.info().attach('local-only-google-calls',{body:JSON.stringify({before:before.calls.length,after:after.calls.length}),contentType:'application/json'});
  });
  await test.step('Notify the other assignee on creation and surface notification failures without losing tasks', async () => {
    const listUrl = new URL(lastListUrl, page.url()).href;
    await page.goto(listUrl);
    await nicole.goto(listUrl);
    const before = (await googleState(request)).pushes.length;
    const missing = await createTask(page,'Assignment without notifications',{assignee:'Nicole'});
    await expect(page.getByRole('alert')).toHaveText("Task saved, but Nicole doesn't have notifications set up.");
    await expect(taskRow(nicole,'Assignment without notifications')).toBeVisible();
    await page.screenshot({path:'artifacts/e2e/assignment-notifications-missing.png',fullPage:true});
    await page.reload();
    await expect(missing).toBeVisible();

    await createTask(page,'Self-assigned task',{assignee:'Will'});
    await createTask(page,'Unassigned task');
    await createTask(nicole,'Self-assigned without notifications',{assignee:'Nicole'});
    for (const tab of [page,nicole]) await expect(tab.locator('#notification-error')).toHaveCount(0);
    expect((await googleState(request)).pushes).toHaveLength(before);

    const assigned = await createTask(nicole,'Nicole assigned Will an undated task',{assignee:'Will'});
    await expect.poll(async () => (await googleState(request)).pushes.filter(p => p.payload.body === 'Nicole assigned Will an undated task').length).toBe(1);
    const push = (await googleState(request)).pushes.at(-1);
    expect(push).toMatchObject({endpoint:deviceSubscription.endpoint,payload:{title:'Nicole assigned you a task',body:'Nicole assigned Will an undated task',url:new URL(listUrl).pathname}});
    await assigned.getByRole('button',{name:/^Edit /}).click();
    await nicole.locator('#task-description').fill('Editing should not notify again');
    await nicole.getByRole('button',{name:'Save',exact:true}).click();
    await expect(nicole.getByRole('dialog')).toBeHidden();
    expect((await googleState(request)).pushes).toHaveLength(before + 1);

    await nicole.getByRole('link',{name:'Settings for Nicole'}).click();
    await nicole.getByRole('button',{name:'Enable notifications',exact:true}).click();
    await expect(nicole.getByRole('button',{name:'Test notification',exact:true})).toBeEnabled();
    await nicole.goto(listUrl);
    await createTask(page,'Will assigned Nicole a task',{assignee:'Nicole'});
    await expect.poll(async () => (await googleState(request)).pushes.filter(p => p.payload.body === 'Will assigned Nicole a task').length).toBe(1);
    expect((await googleState(request)).pushes.at(-1)).toMatchObject({endpoint:nicoleSubscription.endpoint,payload:{title:'Will assigned you a task'}});
    await expect(page.locator('#notification-error')).toHaveCount(0);

    await request.post('http://127.0.0.1:4010/__push-response',{data:{status:503}});
    await createTask(page,'Saved despite failed notification',{assignee:'Nicole'});
    await expect(page.getByRole('alert')).toHaveText("Task saved, but couldn't notify Nicole.");
    await expect(taskRow(nicole,'Saved despite failed notification')).toBeVisible();
    await request.post('http://127.0.0.1:4010/__push-response',{data:{status:410}});
    await createTask(page,'Expired notification subscription',{assignee:'Nicole'});
    await expect(page.getByRole('alert')).toHaveText("Task saved, but Nicole doesn't have notifications set up.");
    await expect(taskRow(nicole,'Expired notification subscription')).toBeVisible();
    await page.screenshot({path:'artifacts/e2e/assignment-notifications-expired.png',fullPage:true});
    await test.info().attach('assignment-notifications',{body:JSON.stringify((await googleState(request)).pushes.slice(before),null,2),contentType:'application/json'});
    await page.getByRole('link',{name:'Settings for Will'}).click();
    await expect(page.getByRole('heading',{name:'Settings',exact:true})).toBeVisible();
  });
  await nicoleContext.close();
});

test('dialog routes follow browser history on desktop and mobile', async ({page,browser}) => {
  await signIn(page);
  const base = await page.locator('nav a[aria-current="page"]').getAttribute('href');
  await page.goto(base);
  const row = await createTask(page,'History task');
  const taskId = await row.getAttribute('data-task-id');
  const mobileContext = await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true});
  const mobile = await mobileContext.newPage();
  await signIn(mobile,'Nicole');
  for (const [label,tab] of [['desktop',page],['mobile',mobile]]) {
    await tab.goto(base);
    const listName = await tab.locator('nav a[aria-current="page"]').innerText();
    const listDialog = tab.getByRole('dialog',{name:'Edit list',exact:true});
    const taskDialog = tab.locator('#task-dialog');
    const saved = tab.locator(`[data-task-id="${taskId}"]`);
    await tab.evaluate(() => { window.dialogHistoryMarker = 'same document'; });

    await tab.getByRole('button',{name:`Edit list ${listName}`,exact:true}).click();
    await expect(tab).toHaveURL(new RegExp(`${base}/edit$`));
    await listDialog.getByRole('textbox',{name:'List name',exact:true}).fill('Unsaved list name');
    await tab.goBack();
    await expect(tab).toHaveURL(new RegExp(`${base}$`));
    await expect(listDialog).toBeHidden();
    await tab.goForward();
    await expect(listDialog.getByRole('textbox',{name:'List name',exact:true})).toHaveValue(listName);
    const listHistoryLength = await tab.evaluate(() => history.length);
    await listDialog.getByRole('button',{name:'Save',exact:true}).click();
    await expect(listDialog).toBeHidden();
    await expect(tab).toHaveURL(new RegExp(`${base}$`));
    expect(await tab.evaluate(() => history.length)).toBe(listHistoryLength);

    await tab.locator('#quick-title').fill(`${label} history draft`);
    await expect(tab).toHaveURL(new RegExp(`${base}/tasks/new$`));
    await tab.locator('#task-description').fill('Preserve the complete draft on Back');
    await expect(tab.locator('#task-title')).toHaveValue(`${label} history draft`);
    await tab.goBack();
    await expect(taskDialog).toBeHidden();
    await expect(tab.locator('#quick-title')).toHaveValue(`${label} history draft`);
    await expect(tab).toHaveURL(new RegExp(`${base}$`));
    await tab.goForward();
    await expect(tab.locator('#task-description')).toHaveValue('Preserve the complete draft on Back');
    await taskDialog.getByRole('button',{name:'Cancel',exact:true}).click();
    await expect(taskDialog).toBeHidden();
    await expect(tab).toHaveURL(new RegExp(`${base}$`));

    const originalDescription = await saved.getByRole('textbox',{name:'Description',exact:true}).inputValue();
    await saved.getByRole('button',{name:'Edit History task',exact:true}).click();
    await expect(tab).toHaveURL(new RegExp(`${base}/tasks/${taskId}/edit$`));
    await tab.locator('#task-description').fill('Discard on Back');
    await tab.goBack();
    await expect(taskDialog).toBeHidden();
    await expect(saved.getByRole('textbox',{name:'Description',exact:true})).toHaveValue(originalDescription);
    await expect(tab.locator('#quick-title')).toHaveValue(`${label} history draft`);
    await tab.goForward();
    await expect(tab.locator('#task-description')).toHaveValue(originalDescription);
    await tab.locator('#task-description').fill(`${label} saved edit`);
    const taskHistoryLength = await tab.evaluate(() => history.length);
    await taskDialog.getByRole('button',{name:'Save',exact:true}).click();
    await expect(taskDialog).toBeHidden();
    await expect(tab).toHaveURL(new RegExp(`${base}$`));
    await expect(saved.getByRole('textbox',{name:'Description',exact:true})).toHaveValue(`${label} saved edit`);
    expect(await tab.evaluate(() => history.length)).toBe(taskHistoryLength);
    expect(await tab.evaluate(() => window.dialogHistoryMarker)).toBe('same document');
    await tab.locator('#quick-title').click();
    await expect(tab.locator('#task-description')).toHaveValue('Preserve the complete draft on Back');
    await taskDialog.getByRole('button',{name:'Cancel',exact:true}).click();
    await expect(taskDialog).toBeHidden();
    await tab.screenshot({path:`artifacts/e2e/dialog-history-${label}.png`,fullPage:true});

    await tab.goto(`${base}/edit`);
    await expect(listDialog).toBeVisible();
    await listDialog.getByRole('button',{name:'Cancel',exact:true}).click();
    await expect(tab).toHaveURL(new RegExp(`${base}$`));
    await tab.goto(`${base}/tasks/${taskId}/edit`);
    await tab.reload();
    await expect(tab.locator('#task-description')).toHaveValue(`${label} saved edit`);
    await taskDialog.getByRole('button',{name:'Cancel',exact:true}).click();
    await expect(tab).toHaveURL(new RegExp(`${base}$`));
    const disposable = await createTask(tab,`${label} deleted history task`);
    await deleteTask(tab,disposable);
    await tab.goForward();
    await expect(tab).toHaveURL(new RegExp(`${base}$`));
    await expect(taskDialog).toBeHidden();
    await expect(disposable).toHaveCount(0);
  }
  await mobileContext.close();
});

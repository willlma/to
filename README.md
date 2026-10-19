# To

A small shared to-do app for Nicole and Will. Phoenix LiveView, SQLite, Oban,
Google sign-in, and an installable PWA. No SPA or offline synchronization.

## Development

Requires Elixir 1.18+, Erlang/OTP 27+, a C compiler, Node.js, and pnpm 12.6.0. Setup installs Chromium for E2E.
In the prepared Codex cloud snapshot, first source `/workspace/.toolchain/activate`.
Use the existing checkout; cloud tasks are already isolated, so no worktree is needed.
The snapshot uses OTP 27.3.4.10, which fixes an HTTP header bug that prevented
Hex downloads through the cloud proxy. Setup uses Hex directly, with TLS,
registry signature, and package checksum verification enabled.

```sh
bash scripts/setup.sh
APP_DEV_LOGIN=true mix phx.server
```

For new worktrees, use `bash scripts/setup.sh` as the install/setup script.
The script runs the standard Phoenix `mix setup`, then installs Playwright for
E2E tests. For development without E2E tests, `mix setup` alone is enough.
Install the required runtimes, Hex, and Rebar once on the machine.
No PostgreSQL or Docker service is needed.
Each worktree has its own database. To run multiple development servers, give
each a different port, for example `PORT=4001 APP_DEV_LOGIN=true mix phx.server`.

The explicit development login option provides Nicole/Will links without Google
credentials. It is absent from production builds. Normal Google sign-in requires
all five OAuth settings below. `mix setup` is also available on a standard machine.

Component hooks and styles are colocated in HEEx using LiveView 1.2. `app.js`
imports the generated hook and CSS manifests and starts LiveSocket; `app.css`
contains shared element defaults. `ToWeb.ColocatedCSS` extracts styles without
rewriting selectors; component styles use their existing classes and IDs.
Compile before bundling assets so LiveView can generate both manifests.

## Behavior

- Shared named lists; the first is **To do**.
- Delete list asks for confirmation and removes all its active and completed
  tasks for both people, cancels reminders, and queues deletion of their Google
  copies. The last remaining list cannot be deleted.
- Typing outside another control focuses quick entry. Starting a todo opens a
  full-screen native dialog that hides the todos. Add sits beside the title, and
  the title requests a Done keyboard action on phones. Enter saves from the
  title; Shift+Enter focuses the description. Escape or Cancel
  collapses the details and keeps the draft; resuming typing opens it again.
  The plus beside a group opens the same dialog with that group filled in.
- Click a task's title or description to edit inline; blur or Enter saves.
  Enter from a title focuses quick entry; Shift+Enter focuses its description.
  Shift+Enter in a description adds a line. Empty descriptions have no placeholder.
  The checkbox toggles completion; × deletes immediately.
  Clearing a title and leaving the field also deletes;
  tasks with a description, date, assignee, group, or completion require confirmation
  when deleted by clearing the title. Cancel restores the title.
  The assignee circle opens the native selector, and clicking the date opens the
  native picker. Dates display compactly as **May 3**, adding the year when it differs from
  the current year; the full date remains in the picker and hover tooltip. Undated tasks show only a
  calendar icon. Assignees show W or N in an outlined circle; unassigned tasks
  show the same circle empty.
  Drag from a task's checkbox to a group to change its group, or outside the group
  into the task area, the No group drop area, or the current list link to ungroup it.
  Drop on another list link to move it to that list and clear its group, preserving
  the task's other details. With the checkbox focused, Alt+Up/Down moves between
  groups; Alt+Left/Right moves between lists. Tasks still sort by due date.
- Your initial in a circle opens a separate settings page with sign-out. The list-name form stays hidden until
  you click the plus beside the lists. Controls share one compact row on phones,
  with the description immediately below the title.
- Tasks have a required title and optional description, date-only `due_on`,
  assignee Nicole or Will, and a plain-string group (`nested_under`).
- Ungrouped tasks appear before named groups. Within each section, overdue tasks and
  dates within the next 30 days precede undated tasks; dates more than 30 days away
  follow undated tasks. Groups stay together, ordered by their first task in this order;
  each group's tasks use the same deadline ordering. Equal dates use creation time/id.
  Dates outside the current UTC year include the year. Incomplete overdue tasks
  use dark orange, with a lighter shade in dark mode. No position column; undated
  ordering is provisional.
- Group names save after a pause or on blur. A collision opens a merge-or-rename
  dialog. Clearing a name ungroups its tasks.
- Tasks completed today remain in place until midnight in America/Los_Angeles,
  then move into a collapsed **Completed** section at the end of their original
  list. Open lists schedule one refresh for the next midnight, including daylight
  saving changes; opening a list also recalculates the section. There is no minute
  polling. Reopening restores the task to its group and deadline order; completing
  again keeps it in place until the next midnight. Tasks are not deleted.
- Actor IDs and creation/update timestamps are stored. No version-history table.
- Google sync is **one way**: eligible assigned, dated tasks from every app list
  go to that person's existing default Google Tasks list. App lists are not
  created in Google Tasks. Completion, edits, reassignment, deletion,
  and removal of eligibility update/remove the copy. Google edits are not imported.
  A single header indicator shows sync progress and retries across all lists.
- Settings has **Import Google Tasks** to copy incomplete tasks from your default
  Google list into the default app list (the oldest remaining list), assigned to you.
  Undated tasks are included. Incomplete subtasks become bullets in their parent's
  description, preserving existing notes. Importing does not modify Google.
  Chat tasks assigned to the signed-in person are included; both people must
  import separately. Unassigned Chat tasks are unavailable through the Tasks API.
  Imported tasks remain linked to their originals: deleting them here also
  deletes the original task, including its Chat task.
  You can repeat it to pick up new tasks; Google IDs prevent duplicates even
  after local edits, reassignment, or deletion. Existing app exports are skipped,
  and re-importing never updates existing tasks from Google.
- Assigned tasks get a day-before push at each person's configurable reminder
  time, using each subscribed browser's timezone. Unassigned tasks have no reminder.
  Rescheduling/completion cancels obsolete jobs; already elapsed reminders are skipped.
- A dropped connection preserves the live form through LiveView recovery. Closing
  or reloading the page does not promise draft recovery. Concurrent edits use the
  last saved values; there is no conflict-resolution interface in this first pass.

## Google and push setup

For local development, put the variables below under `[env]` in
`mise.local.toml` in the project root (ignored by Git). Use TOML assignments
such as `GOOGLE_CLIENT_ID = "your-client-id"`. Mise loads it automatically:

```sh
mise trust mise.local.toml
mise exec -- mix phx.server
```

If mise is activated in your shell, you can run `mix phx.server` directly.
Production should supply the variables through the hosting provider's secrets
and environment settings.

Create a Google OAuth **Web application**, enable Google Tasks API, and add the
exact callback URL to its authorized redirect URIs. For localhost it is normally
`http://localhost:4000/auth/google/callback`; production uses your HTTPS host.
Allowlist both Google accounts as test users if the consent screen is in testing.
Google testing-mode refresh tokens may expire after seven days with Tasks scopes.
Each person signs in separately and grants Tasks access.

| Variable | Purpose |
| --- | --- |
| `GOOGLE_CLIENT_ID` | OAuth application ID |
| `GOOGLE_CLIENT_SECRET` | OAuth secret; supply securely |
| `GOOGLE_REDIRECT_URI` | Exact authorized callback URL |
| `NICOLE_GOOGLE_EMAIL` | Nicole's allowed Google email |
| `WILL_GOOGLE_EMAIL` | Will's allowed Google email |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | Matching Web Push key pair |
| `VAPID_SUBJECT` | Contact URI, such as `mailto:you@example.com` |
| `SECRET_KEY_BASE` | Stable production cookie/token encryption secret |
| `DATABASE_PATH` | Production SQLite file on persistent storage |
| `PHX_HOST` | Production hostname |

Generate VAPID keys using `ExNudge.generate_vapid_keys/0` and supply them securely;
never commit secret values. Refresh tokens are encrypted using `SECRET_KEY_BASE`,
which must be retained across deployments. Notification permissions are requested
only after a click. On iOS 16.4+, install the PWA on the Home Screen and open it
there first. Real device delivery requires HTTPS, valid VAPID keys, and consent.

Server network access needs `oauth2.googleapis.com`, `openidconnect.googleapis.com`,
`tasks.googleapis.com`, and the browser's push provider (Apple, Google, or Mozilla).
The browser opens `accounts.google.com` for login. Codex development credentials
are separate from production Fly secrets.

## End-to-end verification

```sh
pnpm test:e2e
```

One continuous household journey signs in once per person, creates and edits
shared tasks, checks Google exports and reminders as those tasks change, exercises
desktop and touch interaction, and finishes with deletion and recovery checks.
Named steps organize the report without separate tests or repeated sign-in.

The runner starts a real Phoenix server with a separate disposable SQLite database
and local OAuth/Google Tasks/push boundary simulations. It exercises LiveView,
Ecto, durable Oban jobs, shared browser sessions, scheduling, and the real
ExNudge encryption/VAPID/HTTP path against a local simulated push provider. It never sends
real Google tasks or notifications. Browser traces, screenshots, and an HTML report
are saved under `artifacts/e2e/`; reproduce by rerunning the command. The generated
unit tests were omitted. The suite does not establish real Google consent or iOS
push delivery; those require configured accounts/devices.

## Deployment

Codex cloud runs the app directly; it does not need a nested container. Fly uses
an OCI image to supply its VM filesystem. The Dockerfile is deployment packaging
and builds an Alpine/musl release. Both build and runtime stages must
remain compatible. `fly.toml` assumes one always-on machine with `/data/to.db` on
a volume; sleeping would delay reminder jobs. Before deploying, choose an available
app name/region, update `PHX_HOST`, create the `to_data` volume in that region, and
set the variables above with `fly secrets`. Generate `SECRET_KEY_BASE` with
`mix phx.gen.secret`. Deploy a single machine (`fly deploy --ha=false`). Startup
runs migrations through the existing Ecto migrator.

One machine means no automatic database failover. Configure and test SQLite-aware
backups that include the WAL, or use SQLite's online backup API; copying only the
live `.db` file is insufficient. A Fly volume is not a backup.

Production is deployed at `https://town.fly.dev` in `sjc` with one 512 MB machine
and a 1 GB `to_data` volume. Google OAuth must authorize
`https://town.fly.dev/auth/google/callback`. Credentials and the stable
`SECRET_KEY_BASE` live in Fly secrets; retain that key across deployments.
Production has its own database; local development tasks are not copied.
Scheduled volume snapshots are enabled with five-day retention. Snapshot restore
has not yet been tested, and snapshots do not replace an independent backup.

Container builds may require authenticated Docker Hub access if its anonymous
pull-rate limit is reached.

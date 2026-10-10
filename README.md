# To

A small shared to-do app for Nicole and Will. Phoenix LiveView, SQLite, Oban,
Google sign-in, and an installable PWA. No SPA or offline synchronization.

## Development

Requires Elixir 1.18+, Erlang/OTP 27+, a C compiler, Node.js, and Chromium for E2E.
In the prepared Codex cloud snapshot, first source `/workspace/.toolchain/activate`.
Use the existing checkout; cloud tasks are already isolated, so no worktree is needed.
The snapshot uses OTP 27.3.4.10, which fixes an HTTP header bug that prevented
Hex downloads through the cloud proxy. Setup uses Hex directly, with TLS,
registry signature, and package checksum verification enabled.

```sh
bash scripts/setup.sh
APP_DEV_LOGIN=true mix phx.server
```

The explicit development login option provides Nicole/Will links without Google
credentials. It is absent from production builds. Normal Google sign-in requires
all five OAuth settings below. `mix setup` is also available on a standard machine.

## Behavior

- Shared named lists; the first is **To do**.
- Typing outside another control focuses quick entry; Enter saves, Shift+Enter
  opens the description and task details.
- Click a task's title or description to edit inline; blur or Enter saves, and
  Shift+Enter adds a description line. The checkbox toggles completion, the
  assignee circle opens the native selector, and clicking the date opens the
  native picker. Dates display compactly as **May 3**; the full date, including
  year, remains in the picker and hover tooltip. Undated tasks show only a
  calendar icon. Assignees show W or N in an outlined circle; unassigned tasks
  show the same circle empty.
  Drag from a task's checkbox to a group to move it, or to the list heading to
  ungroup it. With the checkbox focused, Alt+Up/Down moves between groups.
  Moving changes the group; tasks still sort by due date.
- Your name opens settings and sign-out. The list-name form stays hidden until
  you click the plus beside the lists. Controls share one compact row on phones,
  with the description immediately below the title.
- Tasks have a required title and optional description, date-only `due_on`,
  assignee Nicole or Will, and a plain-string group (`nested_under`).
- Dated tasks precede undated tasks. Groups stay together, ordered by their first
  due task; each group's tasks sort by due date. Equal dates use creation time/id.
  No position column; undated ordering is provisional.
- Group names save after a pause or on blur. A collision opens a merge-or-rename
  dialog. Clearing a name ungroups its tasks.
- Completion remains in place for 24 hours, then appears in **Old Completed Items**
  in the original list. This is a view, not a database move.
- Actor IDs and creation/update timestamps are stored. No version-history table.
- Google sync is **one way**: eligible assigned, dated tasks go to that person's
  dedicated **To** Google task list. Completion, edits, reassignment, deletion,
  and removal of eligibility update/remove the copy. Google edits are not imported.
- Assigned tasks get a day-before push at each person's configurable reminder
  time, using each subscribed browser's timezone. Unassigned tasks have no reminder.
  Rescheduling/completion cancels obsolete jobs; already elapsed reminders are skipped.
- A dropped connection preserves the live form through LiveView recovery. Closing
  or reloading the page does not promise draft recovery. Concurrent edits use the
  last saved values; there is no conflict-resolution interface in this first pass.

## Google and push setup

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
npm run test:e2e
```

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

Container builds may require authenticated Docker Hub access if its anonymous
pull-rate limit is reached. No image has been published or app deployed by this task.

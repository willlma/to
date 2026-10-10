defmodule ToWeb.ListLive do
  use ToWeb, :live_view
  alias To.{Accounts, Reminders, Tasks}
  alias To.Tasks.Task

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Tasks.subscribe_lists()
      Process.send_after(self(), :refresh_completed, 60_000)
    end

    {:ok,
     assign(socket,
       lists: Tasks.list_lists(),
       users: Accounts.list_users(),
       form: task_form(),
       show_list_form: false,
       merge: nil,
       inline_errors: %{},
       notice: nil,
       vapid_key: Application.get_env(:ex_nudge, :vapid_public_key)
     )}
  end

  def handle_params(params, _uri, socket) do
    list =
      case params["id"] do
        nil -> hd(Tasks.list_lists())
        id -> Tasks.get_list!(id)
      end

    if connected?(socket) do
      if socket.assigns[:list],
        do: Phoenix.PubSub.unsubscribe(To.PubSub, "tasks:#{socket.assigns.list.id}")

      Tasks.subscribe(list.id)
    end

    {:noreply,
     socket
     |> assign(list: list, show_list_form: false, inline_errors: %{}, merge: nil)
     |> load_tasks()}
  end

  def handle_event("validate", %{"task" => attrs}, socket) do
    form =
      %Task{} |> Tasks.change_task(attrs) |> Map.put(:action, :validate) |> to_form(as: :task)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("create", %{"task" => attrs}, socket) do
    case Tasks.create_task(socket.assigns.current_user, socket.assigns.list.id, attrs) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> assign(form: task_form(), notice: nil)
         |> load_tasks()
         |> push_event("task-saved", %{})}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :task))}
    end
  end

  def handle_event("create-list", %{"name" => name}, socket) do
    case Tasks.create_list(%{name: name}) do
      {:ok, list} ->
        {:noreply,
         socket |> assign(lists: Tasks.list_lists()) |> push_patch(to: ~p"/lists/#{list.id}")}

      {:error, _} ->
        {:noreply, assign(socket, notice: "Use a new, non-empty list name.")}
    end
  end

  def handle_event("toggle-list-form", _, socket),
    do: {:noreply, assign(socket, show_list_form: !socket.assigns.show_list_form)}

  def handle_event("toggle", %{"id" => id}, socket) do
    task = Tasks.get_task!(socket.assigns.list.id, id)
    {:noreply, result(socket, Tasks.toggle_task(socket.assigns.current_user, task))}
  end

  def handle_event("move-task", %{"id" => id, "group" => group}, socket) do
    task = Tasks.get_task!(socket.assigns.list.id, id)

    {:noreply,
     result(socket, Tasks.update_task(socket.assigns.current_user, task, %{nested_under: group}))}
  end

  def handle_event(
        "save-inline",
        %{"task_id" => id, "task" => attrs, "_target" => ["task", field]},
        socket
      )
      when field in ["title", "description", "due_on", "assignee_id", "nested_under"] do
    task = Tasks.get_task!(socket.assigns.list.id, id)

    # Save only the changed field so a stale form cannot overwrite the other user's edits.
    case Tasks.update_task(socket.assigns.current_user, task, Map.take(attrs, [field])) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(inline_errors: Map.delete(socket.assigns.inline_errors, task.id))
         |> load_tasks()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           inline_errors:
             Map.put(socket.assigns.inline_errors, task.id, errors(to_form(changeset)))
         )}
    end
  end

  def handle_event("save-inline", _, socket), do: {:noreply, socket}

  def handle_event("delete", %{"id" => id}, socket) do
    {:noreply,
     result(
       socket,
       Tasks.delete_task(socket.assigns.current_user, Tasks.get_task!(socket.assigns.list.id, id))
     )}
  end

  def handle_event("rename-group", %{"group" => %{"old" => old, "name" => name}}, socket),
    do: rename(socket, old, name)

  def handle_event("rename-group-blur", %{"old" => old, "value" => name}, socket),
    do: rename(socket, old, name)

  def handle_event("merge", _, socket) do
    %{old: old, name: name} = socket.assigns.merge

    case Tasks.rename_group(socket.assigns.current_user, socket.assigns.list.id, old, name,
           merge: true
         ) do
      {:ok, _} -> {:noreply, socket |> assign(merge: nil) |> load_tasks()}
      {:error, _} -> {:noreply, assign(socket, notice: "The groups couldn't be merged.")}
    end
  end

  def handle_event("cancel-merge", _, socket) do
    name = socket.assigns.merge.old

    {:noreply,
     socket |> assign(merge: nil) |> load_tasks() |> push_event("focus-group", %{name: name})}
  end

  def handle_event("reminder-time", %{"time" => time}, socket) do
    case Reminders.update_reminder_time(socket.assigns.current_user, time) do
      {:ok, user} ->
        {:noreply, assign(socket, current_user: user, notice: "Reminder time saved.")}

      {:error, _} ->
        {:noreply, assign(socket, notice: "Choose a valid reminder time.")}
    end
  end

  def handle_info({:tasks_changed, _}, socket), do: {:noreply, load_tasks(socket)}

  def handle_info(:lists_changed, socket),
    do: {:noreply, assign(socket, lists: Tasks.list_lists())}

  def handle_info(:refresh_completed, socket) do
    Process.send_after(self(), :refresh_completed, 60_000)
    {:noreply, load_tasks(socket)}
  end

  defp rename(socket, old, name) do
    case Tasks.rename_group(socket.assigns.current_user, socket.assigns.list.id, old, name) do
      {:ok, _} ->
        {:noreply, load_tasks(socket)}

      {:error, :merge_required} ->
        {:noreply, assign(socket, merge: %{old: old, name: String.trim(name)})}

      {:error, _} ->
        {:noreply, assign(socket, notice: "Group names must be at most 100 characters.")}
    end
  end

  defp load_tasks(socket) do
    cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)

    tasks = Tasks.list_tasks(socket.assigns.list.id)

    {old, current} =
      tasks
      |> Enum.split_with(fn task ->
        task.completed_at && DateTime.compare(task.completed_at, cutoff) != :gt
      end)

    assign(socket,
      groups: groups(current),
      old_tasks: old,
      sync_statuses: Map.new(tasks, &{&1.id, To.Sync.status(&1)})
    )
  end

  # Groups follow their earliest task's due date; tasks within each group keep due-date order.
  defp groups(tasks) do
    tasks
    |> Enum.reduce([], fn task, groups ->
      key = task.nested_under || {:task, task.id}

      case Enum.find_index(groups, fn {name, _} -> name == key end) do
        nil -> groups ++ [{key, [task]}]
        index -> List.update_at(groups, index, fn {name, items} -> {name, items ++ [task]} end)
      end
    end)
  end

  defp task_form, do: to_form(Tasks.change_task(%Task{}), as: :task)
  defp result(socket, {:ok, _}), do: load_tasks(socket)

  defp result(socket, {:error, _}),
    do: assign(socket, notice: "Could not save. Please try again.")

  defp date(nil), do: nil
  defp date(value), do: Date.to_iso8601(value)
  defp value(form, field), do: form[field].value

  defp errors(form),
    do:
      Enum.map(form.errors, fn {_field, {message, opts}} ->
        Enum.reduce(opts, message, fn {key, val}, text ->
          String.replace(text, "%{#{key}}", to_string(val))
        end)
      end)

  defp task_row(assigns) do
    ~H"""
    <li
      id={"task-#{@task.id}"}
      data-task-id={@task.id}
      data-group={@task.nested_under || ""}
      class={if @task.completed_at, do: "completed"}
    >
      <input
        type="checkbox"
        checked={@task.completed_at != nil}
        phx-click="toggle"
        phx-value-id={@task.id}
        title="Click to complete; drag to a group. Alt + arrow keys move between groups."
        aria-label={
          if @task.completed_at, do: "Reopen #{@task.title}", else: "Complete #{@task.title}"
        }
      />
      <.form
        for={%{}}
        id={"inline-task-#{@task.id}"}
        phx-hook="InlineTask"
        phx-change="save-inline"
        phx-submit="save-inline"
      >
        <input type="hidden" name="task_id" value={@task.id} />
        <input
          class="task-title"
          name="task[title]"
          value={@task.title}
          aria-label="Title"
          required
          maxlength="300"
          phx-debounce="blur"
        />
        <textarea
          name="task[description]"
          aria-label="Description"
          placeholder="Description"
          rows="1"
          phx-debounce="blur"
        >{@task.description}</textarea>
        <label
          class="task-assignee"
          title={if @task.assignee, do: @task.assignee.name, else: "Unassigned"}
        >
          <span aria-hidden="true">{if @task.assignee, do: String.first(@task.assignee.name)}</span>
          <select name="task[assignee_id]" aria-label="Assignee">
            <option value="">Unassigned</option>
            <option
              :for={user <- @users}
              value={user.id}
              selected={@task.assignee_id == user.id}
            >
              {user.name}
            </option>
          </select>
        </label>
        <label class="task-date" title={date(@task.due_on) || "Set due date"}>
          <input type="date" name="task[due_on]" value={date(@task.due_on)} aria-label="Due date" />
          <span :if={@task.due_on}>{Calendar.strftime(@task.due_on, "%b %-d")}</span>
          <svg :if={is_nil(@task.due_on)} viewBox="0 0 24 24" aria-hidden="true">
            <path d="M7 3v4m10-4v4M4 10h16M5 5h14a1 1 0 0 1 1 1v14H4V6a1 1 0 0 1 1-1Z" />
          </svg>
        </label>
      </.form>
      <button
        phx-click="delete"
        phx-value-id={@task.id}
        data-confirm="Delete this task?"
        aria-label={"Delete #{@task.title}"}
      >×</button>
      <small :if={@status in [:pending, :error, :not_connected]}>{sync_label(@status)}</small>
      <p :for={error <- @errors} role="alert">{error}</p>
    </li>
    """
  end

  defp sync_label(:pending), do: "Sync pending"
  defp sync_label(:error), do: "Sync retrying"
  defp sync_label(:not_connected), do: "Google not connected"

  def render(assigns) do
    ~H"""
    <main id="to-app" phx-hook="QuickEntry">
      <header>
        <details
          id="user-menu"
          phx-mounted={JS.ignore_attributes("open")}
          phx-click-away={JS.remove_attribute("open", to: "#user-menu")}
          phx-window-keydown={JS.remove_attribute("open", to: "#user-menu")}
          phx-key="Escape"
        >
          <summary>{@current_user.name}</summary>
          <h2>Settings</h2>
          <p>Assigned tasks remind you the day before, in each browser's timezone.</p>
          <.form for={%{}} id="reminder-form" phx-submit="reminder-time">
            <label>Reminder time<input
              name="time"
              type="time"
              value={Time.to_iso8601(@current_user.reminder_time)}
              required
            /></label><button>Save time</button>
          </.form>
          <button
            id="enable-notifications"
            type="button"
            phx-hook="Notifications"
            data-vapid-key={@vapid_key || ""}
          >Enable notifications</button>
          <p id="notification-status" role="status" phx-update="ignore"></p>
          <p><a href="/auth/google">Connect Google Tasks</a></p>
          <small>On iPhone, add To to your Home Screen before enabling notifications.</small>
          <.form for={%{}} action="/logout" method="delete"><button>Sign out</button></.form>
        </details>
      </header>
      <p id="connection-status" role="status" hidden>
        Reconnecting… Your changes will need a connection.
      </p>
      <p :if={@notice} role="status">{@notice}</p>
      <nav aria-label="Lists">
        <.link
          :for={list <- @lists}
          patch={~p"/lists/#{list.id}"}
          aria-current={if list.id == @list.id, do: "page"}
        >{list.name}</.link>
        <button
          type="button"
          phx-click="toggle-list-form"
          aria-label="New list"
          aria-expanded={to_string(@show_list_form)}
          aria-controls="list-form"
        >+</button>
      </nav>
      <.form
        :if={@show_list_form}
        for={%{}}
        id="list-form"
        phx-submit="create-list"
        phx-mounted={JS.focus(to: "#list-name")}
      >
        <input id="list-name" name="name" aria-label="New list name" placeholder="New list" required /><button>Create list</button>
      </.form>
      <h1 data-drop-group="" title="Drop a task here to remove its group">{@list.name}</h1>
      <.form for={@form} id="task-form" phx-change="validate" phx-submit="create">
        <input
          id="task-title"
          name="task[title]"
          value={value(@form, :title)}
          placeholder="Start typing a task…"
          aria-label="Task title"
          required
          maxlength="300"
          phx-debounce="300"
          autocomplete="off"
          autofocus
        />
        <button>Add</button>
        <details id="task-details" phx-mounted={JS.ignore_attributes("open")}>
          <summary>Details <small>Shift + Enter</small></summary>
          <label>Description<textarea
            id="task-description"
            name="task[description]"
            phx-debounce="300"
          >{value(@form, :description)}</textarea></label>
          <label>Due date<input
            id="task-due"
            type="date"
            name="task[due_on]"
            value={value(@form, :due_on)}
          /></label>
          <label>Assignee<select id="task-assignee" name="task[assignee_id]"><option value="">
            Unassigned
          </option><option
            :for={user <- @users}
            value={user.id}
            selected={to_string(value(@form, :assignee_id)) == to_string(user.id)}
          >
            {user.name}
          </option></select></label>
          <label>Group<input
            id="task-group"
            name="task[nested_under]"
            value={value(@form, :nested_under)}
            maxlength="100"
            phx-debounce="300"
          /></label>
        </details>
        <p :for={error <- errors(@form)} role="alert">{error}</p>
      </.form>
      <p :if={@groups == []}>Nothing to do.</p>
      <section
        :for={{group, items} <- @groups}
        data-drop-group={if is_binary(group), do: group, else: ""}
      >
        <.form
          :if={is_binary(group)}
          for={%{}}
          id={"group-#{Enum.min_by(items, & &1.id).id}"}
          phx-change="rename-group"
        >
          <input type="hidden" name="group[old]" value={group} />
          <input
            name="group[name]"
            value={group}
            aria-label="Group name"
            data-group={group}
            maxlength="100"
            phx-debounce="400"
            phx-blur="rename-group-blur"
            phx-value-old={group}
          />
        </.form>
        <ul class={if is_binary(group), do: "grouped"}>
          <.task_row
            :for={task <- items}
            task={task}
            status={@sync_statuses[task.id]}
            users={@users}
            errors={@inline_errors[task.id] || []}
          />
        </ul>
      </section>
      <details :if={@old_tasks != []} id="old-completed">
        <summary>Old Completed Items ({length(@old_tasks)})</summary><ul>
          <.task_row
            :for={task <- @old_tasks}
            task={task}
            status={@sync_statuses[task.id]}
            users={@users}
            errors={@inline_errors[task.id] || []}
          />
        </ul>
      </details>
      <dialog :if={@merge} id="merge-dialog" phx-hook="MergeDialog" aria-labelledby="merge-title">
        <h2 id="merge-title">Merge groups?</h2><p>
          “{@merge.name}” already exists. Combine “{@merge.old}” with it?
        </p>
        <button phx-click="merge">Merge groups</button><button phx-click="cancel-merge">Choose another name</button>
      </dialog>
    </main>
    """
  end
end

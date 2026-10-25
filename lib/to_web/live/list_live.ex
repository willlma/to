defmodule ToWeb.ListLive do
  use ToWeb, :live_view
  alias To.{Accounts, Tasks}
  alias To.Tasks.Task

  @completion_time_zone "America/Los_Angeles"

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Tasks.subscribe_lists()
      To.Sync.subscribe()
      schedule_completed_refresh()
    end

    {:ok,
     assign(socket,
       lists: Tasks.list_lists(),
       users: Accounts.list_users(),
       form: task_form(),
       editing_task: nil,
       new_task_form: nil,
       show_list_form: false,
       list_form: nil,
       current_path: nil,
       dialog_back: false,
       task_dialog_open: false,
       merge: nil,
       inline_errors: %{},
       notification_error: nil,
       notice: nil
     )}
  end

  def handle_params(params, uri, socket) do
    lists = Tasks.list_lists()
    previous_path = socket.assigns.current_path

    list =
      case params["id"] do
        nil -> hd(lists)
        id -> Tasks.get_list(id) || hd(lists)
      end

    if connected?(socket) && socket.assigns[:list] != list do
      if socket.assigns[:list],
        do: Phoenix.PubSub.unsubscribe(To.PubSub, "tasks:#{socket.assigns.list.id}")

      Tasks.subscribe(list.id)
    end

    socket =
      if socket.assigns.editing_task do
        assign(socket,
          form: socket.assigns.new_task_form || task_form(),
          editing_task: nil,
          new_task_form: nil
        )
      else
        socket
      end

    socket =
      socket
      |> assign(
        lists: lists,
        list: list,
        show_list_form: false,
        list_form: nil,
        task_dialog_open: false,
        current_path: URI.parse(uri).path,
        dialog_back:
          socket.assigns.live_action != :index && previous_path in ["/lists", "/lists/#{list.id}"],
        inline_errors: %{},
        merge: nil
      )
      |> load_tasks()

    socket =
      if params["id"] && params["id"] != to_string(list.id),
        do: socket |> apply_action(:index, params) |> push_patch(to: ~p"/lists", replace: true),
        else: apply_action(socket, socket.assigns.live_action, params)

    {:noreply, socket}
  end

  defp apply_action(socket, :index, _params),
    do: push_event(socket, "task-edit-closed", %{})

  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(list_form: socket.assigns.list |> Tasks.change_list() |> to_form(), notice: nil)
    |> push_event("task-edit-closed", %{})
  end

  defp apply_action(socket, :new_task, _params) do
    socket |> assign(task_dialog_open: true) |> push_event("open-task", %{})
  end

  defp apply_action(socket, :edit_task, %{"task_id" => id}) do
    case Tasks.get_task(socket.assigns.list.id, id) do
      nil ->
        socket
        |> apply_action(:index, %{})
        |> push_patch(to: ~p"/lists/#{socket.assigns.list.id}", replace: true)

      task ->
        socket
        |> assign(
          task_dialog_open: true,
          editing_task: task,
          new_task_form: socket.assigns.form,
          form: task |> Tasks.change_task() |> to_form(as: :task)
        )
        |> push_event("open-task", %{id: task.id})
    end
  end

  def handle_event("validate", %{"task" => attrs}, socket) do
    form =
      (socket.assigns.editing_task ||
         %Task{
           list_id: socket.assigns.list.id,
           created_by_id: socket.assigns.current_user.id,
           updated_by_id: socket.assigns.current_user.id
         })
      |> Tasks.change_task(attrs)
      |> Map.put(:action, :validate)
      |> to_form(as: :task)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("open-task", %{"group" => group}, socket) do
    {:noreply,
     socket
     |> assign(form: task_form(%{nested_under: group}))
     |> push_patch(to: ~p"/lists/#{socket.assigns.list.id}/tasks/new")}
  end

  def handle_event("new-task", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list.id}/tasks/new")}
  end

  def handle_event("edit-task", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list.id}/tasks/#{id}/edit")}
  end

  def handle_event("cancel-edit", _, socket) do
    {:noreply, close_dialog(socket)}
  end

  def handle_event("update-task", %{"task" => attrs}, socket) do
    changeset = Tasks.change_task(socket.assigns.editing_task, attrs)

    result =
      if changeset.valid? do
        task = Tasks.get_task!(socket.assigns.list.id, socket.assigns.editing_task.id)
        # Only fields changed in this dialog should overwrite the latest saved task.
        Tasks.update_task(socket.assigns.current_user, task, changeset.changes)
      else
        {:error, %{changeset | action: :update}}
      end

    case result do
      {:ok, _task} ->
        {:noreply, socket |> load_tasks() |> close_dialog()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :task))}
    end
  end

  def handle_event("create", %{"task" => attrs}, socket) do
    case Tasks.create_task(socket.assigns.current_user, socket.assigns.list.id, attrs) do
      {:ok, task} ->
        notification_error =
          case To.Reminders.notify_assignment(task) do
            :ok ->
              nil

            {:error, :not_subscribed} ->
              "Task saved, but #{task.assignee.name} doesn't have notifications set up."

            {:error, :not_configured} ->
              "Task saved, but notifications aren't configured on the server."

            {:error, _} ->
              "Task saved, but couldn't notify #{task.assignee.name}."
          end

        {:noreply,
         socket
         |> assign(form: task_form(), notice: nil, notification_error: notification_error)
         |> load_tasks()
         |> push_event("task-saved", %{})
         |> close_dialog()}

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

  def handle_event("edit-list", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/lists/#{socket.assigns.list.id}/edit")}
  end

  def handle_event("cancel-list-edit", _, socket),
    do: {:noreply, close_dialog(socket)}

  def handle_event("rename-list", %{"list" => %{"name" => name}}, socket) do
    case Tasks.rename_list(socket.assigns.list, name) do
      {:ok, list} ->
        {:noreply,
         socket |> assign(list: list, lists: Tasks.list_lists(), notice: nil) |> close_dialog()}

      {:error, changeset} ->
        {:noreply, assign(socket, list_form: to_form(changeset))}
    end
  end

  def handle_event("delete-list", _, socket) do
    case Tasks.delete_list(socket.assigns.current_user, socket.assigns.list) do
      {:ok, _} ->
        {:noreply, push_patch(socket, to: ~p"/lists", replace: true)}

      {:error, :last_list} ->
        {:noreply, assign(socket, notice: "Keep at least one list.")}

      {:error, _} ->
        {:noreply, assign(socket, notice: "Could not delete this list. Please try again.")}
    end
  end

  def handle_event("set-completed", %{"task_id" => id, "completed" => completed}, socket)
      when completed in ["true", "false"] do
    case Tasks.set_completed(socket.assigns.current_user, id, completed == "true") do
      {:ok, _} ->
        {:noreply, load_tasks(socket)}

      {:error, :not_found} ->
        {:noreply, load_tasks(socket)}

      {:error, _} ->
        {:noreply, assign(socket, notice: "Could not save the checkmark. Please try again.")}
    end
  end

  # Recover only a changed checkbox, so stale untouched forms cannot overwrite
  # another person's completion changes while this browser was disconnected.
  def handle_event(
        "recover-completion",
        %{"completed" => value, "baseline" => baseline} = params,
        socket
      ) do
    if value != baseline,
      do: handle_event("set-completed", params, socket),
      else: {:noreply, socket}
  end

  def handle_event("move-task", %{"id" => id, "group" => group}, socket) do
    task = Tasks.get_task!(socket.assigns.list.id, id)

    {:noreply,
     result(socket, Tasks.update_task(socket.assigns.current_user, task, %{nested_under: group}))}
  end

  def handle_event("move-to-list", %{"id" => id, "list_id" => list_id}, socket) do
    task = Tasks.get_task!(socket.assigns.list.id, id)
    {:noreply, result(socket, Tasks.move_task(socket.assigns.current_user, task, list_id))}
  end

  def handle_event(
        "save-inline",
        %{"task_id" => id, "task" => attrs, "_target" => ["task", field]},
        socket
      )
      when field in ["title", "description", "due_on", "assignee_id", "nested_under"] do
    task = Tasks.get_task!(socket.assigns.list.id, id)

    if field == "title" && String.trim(attrs["title"] || "") == "" do
      if task.description not in [nil, ""] || task.due_on || task.assignee_id ||
           task.nested_under || task.completed_at do
        {:noreply, push_event(socket, "confirm-task-delete", %{id: task.id, title: task.title})}
      else
        {:noreply, result(socket, Tasks.delete_task(socket.assigns.current_user, task))}
      end
    else
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
  end

  def handle_event("save-inline", _, socket), do: {:noreply, socket}

  def handle_event("delete", %{"id" => id}, socket) do
    task = Tasks.get_task!(socket.assigns.list.id, id)
    outcome = Tasks.delete_task(socket.assigns.current_user, task)

    socket =
      if match?({:ok, _}, outcome) && socket.assigns.editing_task &&
           socket.assigns.editing_task.id == task.id,
         do: close_dialog(socket),
         else: socket

    {:noreply, result(socket, outcome)}
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

  def handle_info({:tasks_changed, _}, socket), do: {:noreply, load_tasks(socket)}

  def handle_info({:sync_status, status}, socket),
    do: {:noreply, assign(socket, sync_status: status)}

  def handle_info(:lists_changed, socket) do
    lists = Tasks.list_lists()
    socket = assign(socket, lists: lists)

    socket =
      case Enum.find(lists, &(&1.id == socket.assigns.list.id)) do
        nil -> push_patch(socket, to: ~p"/lists", replace: true)
        list -> assign(socket, list: list)
      end

    {:noreply, socket}
  end

  def handle_info(:refresh_completed, socket) do
    schedule_completed_refresh()
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

  defp schedule_completed_refresh do
    now = DateTime.now!(@completion_time_zone)

    next_midnight =
      now
      |> DateTime.to_date()
      |> Date.add(1)
      |> DateTime.new!(~T[00:00:00], @completion_time_zone)

    Process.send_after(
      self(),
      :refresh_completed,
      DateTime.diff(next_midnight, now, :millisecond)
    )
  end

  defp close_dialog(socket) do
    socket = assign(socket, notice: nil)

    if socket.assigns.dialog_back,
      do: socket |> assign(dialog_back: false) |> push_event("dialog-back", %{}),
      else: push_patch(socket, to: ~p"/lists/#{socket.assigns.list.id}", replace: true)
  end

  defp load_tasks(socket) do
    today = DateTime.now!(@completion_time_zone) |> DateTime.to_date()
    cutoff = DateTime.new!(today, ~T[00:00:00], @completion_time_zone)

    tasks = Tasks.list_tasks(socket.assigns.list.id)

    {completed, current} =
      tasks
      |> Enum.split_with(fn task ->
        task.completed_at && DateTime.before?(task.completed_at, cutoff)
      end)

    assign(socket,
      groups: groups(current),
      completed_tasks: completed,
      sync_status: To.Sync.status()
    )
  end

  # Ungrouped tasks come first; each section keeps its existing due-date order.
  defp groups([]), do: []

  defp groups(tasks) do
    tasks
    |> Enum.reduce([{nil, []}], fn task, groups ->
      key = task.nested_under

      case Enum.find_index(groups, fn {name, _} -> name == key end) do
        nil -> groups ++ [{key, [task]}]
        index -> List.update_at(groups, index, fn {name, items} -> {name, items ++ [task]} end)
      end
    end)
    |> Enum.sort_by(fn {name, _} -> is_binary(name) end)
  end

  defp task_form(attrs \\ %{}), do: to_form(Tasks.change_task(%Task{}, attrs), as: :task)
  defp result(socket, {:ok, _}), do: load_tasks(socket)

  defp result(socket, {:error, _}),
    do: assign(socket, notice: "Could not save. Please try again.")

  defp date(nil), do: nil
  defp date(value), do: Date.to_iso8601(value)

  defp deadline_section(%{due_on: nil}), do: :undated

  defp deadline_section(%{due_on: due_on}) do
    if Date.compare(due_on, Date.add(Date.utc_today(), 30)) == :gt,
      do: :later,
      else: :soon
  end

  defp date_label(value) do
    format = if value.year == Date.utc_today().year, do: "%b %-d", else: "%b %-d, %Y"
    Calendar.strftime(value, format)
  end

  defp overdue?(task),
    do:
      is_nil(task.completed_at) && task.due_on != nil &&
        Date.before?(task.due_on, Date.utc_today())

  defp value(form, field), do: form[field].value

  defp errors(form),
    do:
      Enum.map(form.errors, fn {_field, {message, opts}} ->
        Enum.reduce(opts, message, fn {key, val}, text ->
          String.replace(text, "%{#{key}}", to_string(val))
        end)
      end)

  attr :field, Phoenix.HTML.FormField, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true

  defp field_errors(assigns) do
    assigns =
      assign(assigns, :errors, if(used_input?(assigns.field), do: assigns.field.errors, else: []))

    ~H"""
    <p :if={@errors != []} id={@id} role="alert">
      <span :for={{message, opts} <- @errors}>
        {@label} {Enum.reduce(opts, message, fn {key, val}, text ->
          String.replace(text, "%{#{key}}", to_string(val))
        end)}
      </span>
    </p>
    """
  end

  defp history_time(time) do
    time
    |> DateTime.shift_zone!(@completion_time_zone)
    |> Calendar.strftime("%b %-d, %Y at %H:%M %Z")
  end

  defp history_fields(fields) do
    labels = %{
      "title" => "title",
      "description" => "description",
      "due_on" => "due date",
      "assignee_id" => "assignee",
      "nested_under" => "group",
      "list_id" => "list",
      "completed_at" => "completion",
      "deleted_at" => "deletion"
    }

    fields |> Enum.map_join(", ", &Map.get(labels, &1, &1)) |> String.capitalize()
  end

  attr :task, Task, required: true

  defp task_history(assigns) do
    ~H"""
    <div id="task-history">
      <p>
        <small>
          Created by {@task.created_by.name} ·
          <time datetime={DateTime.to_iso8601(@task.created_at)}>{history_time(@task.created_at)}</time>
        </small>
      </p>
      <p :if={@task.last_changed_fields != nil || @task.updated_at != @task.created_at}>
        <small>
          <%= if @task.last_changed_fields == [] do %>
            No edits yet.
          <% else %>
            Updated {if @task.updated_by_id != @task.created_by_id, do: "by #{@task.updated_by.name}"} at
            <time datetime={DateTime.to_iso8601(@task.updated_at)}>{history_time(@task.updated_at)}</time>
            <%= if @task.last_changed_fields != nil do %>
              <br /> Changed: {history_fields(@task.last_changed_fields)}.
            <% end %>
          <% end %>
        </small>
      </p>
    </div>
    """
  end

  defp task_row(assigns) do
    ~H"""
    <style :type={ToWeb.ColocatedCSS}>
      [data-task-id] { display: grid; grid-template-columns: 1.1rem minmax(0, 1fr) auto auto auto; align-items: center; column-gap: .25rem; padding: .1rem 0; }
      [data-task-id] input[data-completion] { grid-area: 1 / 1; width: 1.1rem; height: 1.1rem; margin: 0; padding: 0; cursor: grab; touch-action: none; }
      [data-task-id] > form { display: contents; }
      [data-task-id] form > input, [data-task-id] textarea { width: 100%; min-width: 0; box-sizing: border-box; border: 0; padding: 0; }
      .task-title { grid-area: 1 / 2; line-height: 1.2; }
      [data-task-id] textarea { grid-area: 2 / 2; min-height: .9rem; height: .9rem; margin: 0; font-size: .75rem; line-height: 1.2; color: light-dark(#6b6b6b, #aaa); overflow: hidden; }
      [data-task-id] textarea:focus { overflow: auto; }
      [data-task-id] textarea::placeholder { color: inherit; opacity: 1; }
      .task-assignee { grid-area: 1 / 3; position: relative; margin: 0; }
      .task-assignee select { position: absolute; inset: 0; width: 100%; height: 100%; margin: 0; padding: 0; opacity: 0; cursor: pointer; }
      .task-assignee:has(select:focus-visible) .person-circle { border-color: light-dark(#706b60, #c4beae); }
      .task-assignee span { pointer-events: none; }
      .task-date { grid-area: 1 / 4; position: relative; display: flex; align-items: center; justify-content: center; min-width: 1.5rem; height: 1.5rem; margin: 0; font-size: .72rem; }
      .overdue .task-date { color: light-dark(#9a3412, #fb923c); }
      .task-date input { position: absolute; inset: 0; width: 100%; height: 100%; margin: 0; padding: 0; border: 0; opacity: 0; cursor: pointer; }
      .task-date input::-webkit-calendar-picker-indicator { position: absolute; inset: 0; width: 100%; height: 100%; padding: 0; margin: 0; cursor: pointer; }
      .task-date:has(input:focus-visible) { box-shadow: inset 0 0 0 1px light-dark(#706b60, #c4beae); }
      .task-date span { white-space: nowrap; padding: 0 .15rem; pointer-events: none; }
      [data-task-id] svg, #task-dialog svg, #edit-list svg, #list-edit-dialog svg { width: .9rem; height: .9rem; vertical-align: middle; fill: none; stroke: currentColor; stroke-width: 1.5; pointer-events: none; }
      [data-task-id] > small, [data-task-id] > p { grid-column: 1 / -1; margin: .25rem 0; }
      [data-task-id] > button { grid-area: 1 / 5; padding: .2rem .3rem; border: 0; }
      .dragging { opacity: .45; }
      .completed .task-title { text-decoration: line-through; opacity: .6; }
      @media (max-width: 36rem) {
        [data-task-id] textarea:focus { height: 5rem; }
      }
      [data-task-id] form > input:focus-visible, [data-task-id] textarea:focus-visible, [data-task-id] button:focus-visible { box-shadow: inset 0 0 0 1px light-dark(#706b60, #c4beae); }
    </style>
    <li
      id={"task-#{@task.id}"}
      data-task-id={@task.id}
      data-group={@task.nested_under || ""}
      class={[@task.completed_at && "completed", overdue?(@task) && "overdue"]}
    >
      <.form
        for={%{}}
        id={"completion-#{@task.id}"}
        phx-change="set-completed"
        phx-auto-recover="recover-completion"
      >
        <input type="hidden" name="task_id" value={@task.id} />
        <input type="hidden" name="baseline" value={to_string(@task.completed_at != nil)} />
        <input type="hidden" name="completed" value="false" />
        <input
          type="checkbox"
          name="completed"
          value="true"
          data-completion
          checked={@task.completed_at != nil}
          title="Click to complete; drag to a group or list. Alt + Up/Down changes group; Alt + Left/Right changes list."
          aria-label={
            if @task.completed_at, do: "Reopen #{@task.title}", else: "Complete #{@task.title}"
          }
        />
      </.form>
      <.form
        for={%{}}
        id={"inline-task-#{@task.id}"}
        phx-hook=".InlineTask"
        phx-change="save-inline"
        phx-submit="save-inline"
      >
        <input type="hidden" name="task_id" value={@task.id} />
        <input
          class="task-title"
          name="task[title]"
          value={@task.title}
          aria-label="Title"
          maxlength="300"
          phx-debounce="blur"
        />
        <textarea
          name="task[description]"
          aria-label="Description"
          rows="1"
          phx-debounce="blur"
        >{@task.description}</textarea>
        <label
          class="task-assignee"
          title={if @task.assignee, do: @task.assignee.name, else: "Unassigned"}
        >
          <.person_circle user={@task.assignee} />
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
          <%= if @task.due_on do %>
            <span>{date_label(@task.due_on)}</span>
          <% else %>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M7 3v4m10-4v4M4 10h16M5 5h14a1 1 0 0 1 1 1v14H4V6a1 1 0 0 1 1-1Z" />
            </svg>
          <% end %>
        </label>
      </.form>
      <button
        id={"edit-task-#{@task.id}"}
        phx-click="edit-task"
        phx-value-id={@task.id}
        aria-label={"Edit #{@task.title}"}
        title="Edit todo"
      >
        <.pen_icon />
      </button>
      <p :for={error <- @errors} role="alert">{error}</p>
    </li>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".InlineTask">
      export default {
        mounted() {
          this.handleEvent("confirm-task-delete", ({id, title}) => {
            if (this.el.querySelector('[name="task_id"]').value !== String(id)) return
            if (window.confirm(`Delete “${title}” and its details?`)) this.pushEvent("delete", {id})
            else this.el.querySelector('.task-title').value = title
          })
          this.keydown = event => {
            if (event.key === "Enter" && !event.isComposing && event.target.matches('.task-title')) {
              event.preventDefault()
              if (event.shiftKey) this.el.querySelector('textarea').focus()
              else document.getElementById('quick-title').focus()
              return
            }
            if (event.key === "Enter" && !event.shiftKey && !event.isComposing &&
              event.target.matches('input:not([type="date"]), textarea')) {
              event.preventDefault()
              event.target.blur()
            }
          }
          this.click = event => {
            if (event.target.matches('input[type="date"]')) {
              try {
                if (event.target.showPicker) {
                  event.target.showPicker()
                  // Avoid also triggering the native indicator's default action.
                  event.preventDefault()
                }
              } catch (_) { /* Native picker remains available. */ }
            }
          }
          this.el.addEventListener("keydown", this.keydown)
          this.el.addEventListener("click", this.click)
        },
        destroyed() {
          this.el.removeEventListener("keydown", this.keydown)
          this.el.removeEventListener("click", this.click)
        }
      }
    </script>
    """
  end

  defp sync_label(:retrying), do: "Saved here. Google sync failed; retrying automatically."
  defp sync_label(:error), do: "Saved here. Google sync failed after repeated attempts."
  defp sync_label(:idle), do: ""

  def render(assigns) do
    ~H"""
    <style :type={ToWeb.ColocatedCSS}>
        header, nav, #list-form, #task-form { display: flex; gap: .75rem; align-items: center; flex-wrap: wrap; }
        header { min-height: 2rem; flex-wrap: nowrap; }
        header > a { text-decoration: none; flex-shrink: 0; }
        header nav { flex: 1; min-width: 0; flex-wrap: nowrap; overflow-x: auto; }
        nav > * { flex-shrink: 0; white-space: nowrap; }
        nav button { border: 0; }
        [aria-current="page"] { font-weight: bold; }
        #quick-title, #task-title, #list-edit-name { width: 100%; box-sizing: border-box; }
        #quick-title { margin: 1rem 0; }
        #task-dialog { position: fixed; inset: var(--task-top, 0px) 0 0; box-sizing: border-box; margin: 0; padding: 0 .5rem; border: 0; border-radius: 0; width: 100%; height: calc(100vh - var(--task-top, 0px)); height: calc(100dvh - var(--task-top, 0px)); max-width: none; max-height: none; overflow-y: auto; }
      #task-form { display: block; max-width: 44rem; margin: 0 auto; }
      .task-entry { display: flex; align-items: center; gap: .5rem; }
      .task-entry input { flex: 1; min-width: 0; }
      .task-entry button { flex-shrink: 0; }
      .dialog-actions { display: flex; gap: .5rem; align-items: center; }
      .dialog-actions [phx-click^="delete"] { border: 0; margin-left: auto; }
      .dialog-actions [phx-click^="delete"]:focus-visible { outline: 1px solid currentColor; }
      #task-dialog .dialog-actions svg, #list-edit-dialog .dialog-actions svg { width: 1.5rem; height: 1.5rem; }
      #edit-list { padding: .2rem .3rem; margin-left: -.5rem; }
      #list-edit-dialog { width: min(26rem, calc(100% - 2rem)); box-sizing: border-box; }
      #list-edit-dialog .dialog-actions { margin-top: 1rem; }
      body:has(#task-dialog[open]) { overflow: hidden; }
      section[data-drop-group=""] { min-height: 2rem; }
        #task-form fieldset { border: 0; margin: 0; padding: 0; }
        #task-form > [role="alert"] { flex-basis: 100%; margin: 0; }
        .drop-target { outline: 1px dashed #888; outline-offset: 2px; }
        .grouped { margin-left: .75rem; margin-top: .25rem; }
        form[id^="group-"] { margin-top: .35rem; display: flex; align-items: center; gap: .25rem; }
        form[id^="group-"] button { border: 0; padding: .15rem .3rem; }
        form[id^="group-"] input { border-color: transparent; font-weight: bold; width: auto; min-width: 0; max-width: calc(100% - 2rem); padding: .15rem 0; }
        form[id^="group-"] input:focus { border-color: #aaa; }
        nav button:focus-visible, form[id^="group-"] button:focus-visible { box-shadow: inset 0 0 0 1px light-dark(#706b60, #c4beae); }
    </style>
    <main id="to-app" phx-hook=".QuickEntry">
      <header>
        <nav aria-label="Lists">
          <%= for list <- @lists do %>
            <.link
              patch={~p"/lists/#{list.id}"}
              aria-current={if list.id == @list.id, do: "page"}
              data-drop-list={list.id}
              data-drop-group={if list.id == @list.id, do: ""}
              title={
                if list.id == @list.id,
                  do: "Drop a task here to remove its group",
                  else: "Drop a task here to move it to #{list.name}"
              }
            >{list.name}</.link>
            <button
              :if={list.id == @list.id}
              id="edit-list"
              type="button"
              phx-click="edit-list"
              aria-label={"Edit list #{list.name}"}
              title="Edit list"
            ><.pen_icon /></button>
          <% end %>
          <button
            type="button"
            phx-click="toggle-list-form"
            aria-label="New list"
            aria-expanded={to_string(@show_list_form)}
            aria-controls="list-form"
          >+</button>
        </nav>
        <.link navigate={~p"/settings"} aria-label={"Settings for #{@current_user.name}"}>
          <.person_circle user={@current_user} />
        </.link>
      </header>
      <p id="connection-status" role="status" hidden>
        Reconnecting… Keep this page open to recover checkmarks when connected.
      </p>
      <p :if={@notice && !@list_form} role="status">{@notice}</p>
      <dialog
        :if={@list_form}
        id="list-edit-dialog"
        phx-hook=".ListDialog"
        phx-mounted={JS.ignore_attributes(["open"])}
        aria-label="Edit list"
      >
        <.form for={@list_form} id="list-edit-form" phx-submit="rename-list">
          <input
            id="list-edit-name"
            aria-label="List name"
            name={@list_form[:name].name}
            value={@list_form[:name].value}
            aria-describedby="list-edit-name-errors"
            required
            maxlength="100"
          />
          <.field_errors field={@list_form[:name]} id="list-edit-name-errors" label="List name" />
          <p :if={@notice} role="alert">{@notice}</p>
          <div class="dialog-actions">
            <button phx-disable-with="Saving…">Save</button>
            <button type="button" phx-click="cancel-list-edit">Cancel</button>
            <button
              :if={length(@lists) > 1}
              type="button"
              phx-click="delete-list"
              data-confirm={"Delete “#{@list.name}” and all its tasks? This cannot be undone."}
              aria-label={"Delete list #{@list.name}"}
              title="Delete list"
            ><.trash_icon /></button>
          </div>
        </.form>
      </dialog>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ListDialog">
        export default {
          mounted() {
            this.el.showModal()
            const name = this.el.querySelector("input")
            name.focus()
            name.select()
            this.el.addEventListener("cancel", event => {
              event.preventDefault()
              this.pushEvent("cancel-list-edit", {})
            })
            this.el.addEventListener("click", event => {
              if (event.target === this.el) this.pushEvent("cancel-list-edit", {})
            })
          },
          destroyed() { document.getElementById("edit-list")?.focus({preventScroll: true}) }
        }
      </script>
      <.form
        :if={@show_list_form}
        for={%{}}
        id="list-form"
        phx-submit="create-list"
        phx-mounted={JS.focus(to: "#list-name")}
      >
        <input id="list-name" name="name" aria-label="New list name" placeholder="New list" required /><button>Create list</button>
      </.form>
      <input
        id="quick-title"
        value={value(@new_task_form || @form, :title)}
        placeholder="Start typing a task…"
        aria-label="Task title"
        autocomplete="off"
        maxlength="300"
        enterkeyhint="done"
        autofocus
      />
      <p :if={@notification_error} id="notification-error" role="alert">{@notification_error}</p>
      <p id="sync-status" role="status" data-state={@sync_status} hidden={@sync_status == :idle}>
        {sync_label(@sync_status)}
      </p>
      <dialog
        id="task-dialog"
        phx-hook=".TaskDialog"
        phx-mounted={JS.ignore_attributes(["open", "style"])}
        data-open={to_string(@task_dialog_open)}
        data-editing-id={@editing_task && @editing_task.id}
        aria-label={if @editing_task, do: "Edit todo", else: "New todo"}
      >
        <.form
          for={@form}
          id="task-form"
          phx-change="validate"
          phx-submit={if @editing_task, do: "update-task", else: "create"}
        >
          <%!-- Keep Add/Save beside the title in both task modes. Only the list dialog puts Save beside Cancel. --%>
          <div class="task-entry">
            <input
              id="task-title"
              aria-describedby="task-title-errors"
              name="task[title]"
              value={value(@form, :title)}
              placeholder="Start typing a task…"
              aria-label="Task title"
              required
              maxlength="300"
              autocomplete="off"
              enterkeyhint="done"
            />
            <button type="submit" phx-disable-with="Saving…">
              {if @editing_task, do: "Save", else: "Add"}
            </button>
          </div>
          <.field_errors field={@form[:title]} id="task-title-errors" label="Todo" />
          <fieldset>
            <label>Description<textarea
              aria-describedby="task-description-errors"
              id="task-description"
              name="task[description]"
            >{value(@form, :description)}</textarea></label>
            <.field_errors
              field={@form[:description]}
              id="task-description-errors"
              label="Description"
            />
            <label>Due date<input
              aria-describedby="task-due-errors"
              id="task-due"
              type="date"
              name="task[due_on]"
              value={value(@form, :due_on)}
            /></label>
            <.field_errors field={@form[:due_on]} id="task-due-errors" label="Due date" />
            <label>Assignee<select
              id="task-assignee"
              aria-describedby="task-assignee-errors"
              name="task[assignee_id]"
            ><option value="">
              Unassigned
            </option><option
              :for={user <- @users}
              value={user.id}
              selected={to_string(value(@form, :assignee_id)) == to_string(user.id)}
            >
              {user.name}
            </option></select></label>
            <.field_errors field={@form[:assignee_id]} id="task-assignee-errors" label="Assignee" />
            <label>Group<input
              aria-describedby="task-group-errors"
              id="task-group"
              name="task[nested_under]"
              value={value(@form, :nested_under)}
              maxlength="100"
            /></label>
            <.field_errors field={@form[:nested_under]} id="task-group-errors" label="Group" />
            <div class="dialog-actions">
              <button type="button" data-cancel-task>Cancel</button>
              <button
                :if={@editing_task}
                type="button"
                phx-click="delete"
                phx-value-id={@editing_task.id}
                aria-label="Delete"
                title="Delete todo"
              >
                <.trash_icon />
              </button>
            </div>
          </fieldset>
          <.task_history :if={@editing_task} task={@editing_task} />
        </.form>
      </dialog>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".TaskDialog">
        export default {
          mounted() {
            this.quick = document.getElementById("quick-title")
            this.form = this.el.querySelector("form")
            this.title = this.el.querySelector("#task-title")
            this.position = () => {
              this.el.style.setProperty("--task-top", `${this.quick.getBoundingClientRect().top}px`)
            }
            this.open = () => {
              if (!this.editing) this.returnTo = null
              if (this.quick.getBoundingClientRect().top < 0) window.scrollTo(0, 0)
              this.position()
              if (!this.el.open) {
                this.el.showModal()
                if (this.el.dataset.open !== "true") {
                  this.pendingNewTask = true
                  this.pushEvent("new-task", {})
                }
              }
              this.el.scrollTop = 0
              this.title.focus({preventScroll: true})
            }
            this.input = () => {
              if (!this.quick.value) return
              const value = this.quick.value
              const start = this.quick.selectionStart
              const end = this.quick.selectionEnd
              this.title.value = value
              this.open()
              this.title.setSelectionRange(start, end)
              this.title.dispatchEvent(new Event("input", {bubbles: true}))
            }
            this.cancel = () => {
              this.pendingNewTask = false
              this.el.querySelector(":focus")?.blur()
              if (!this.editing) {
                const task = Object.fromEntries(Array.from(new FormData(this.form))
                  .filter(([name]) => name.startsWith("task["))
                  .map(([name, value]) => [name.slice(5, -1), value]))
                this.pushEvent("validate", {task})
              }
              this.pushEvent("cancel-edit", {})
            }
            this.restoreFocus = () => {
              const target = document.getElementById(this.returnTo) || this.quick
              target.blur()
              target.focus({preventScroll: true})
            }
            this.closed = () => {
              requestAnimationFrame(() => {
                if (this.el.open) return
                // WebKit can retain DOM focus after dismissal without accepting keys.
                // Avoid stealing focus if the user has already moved to another control.
                const target = document.getElementById(this.returnTo) || this.quick
                if (document.activeElement === target) this.restoreFocus()
              })
            }
            this.cancelEvent = event => { event.preventDefault(); this.cancel() }
            this.click = event => {
              if (event.target === this.el || event.target.closest("[data-cancel-task]")) this.cancel()
            }
            this.keydown = event => {
              if (event.key !== "Enter" || event.isComposing || event.target !== this.title) return
              event.preventDefault()
              if (event.shiftKey) this.el.querySelector("#task-description").focus()
              else this.form.requestSubmit()
            }
            this.navigate = event => {
              if (event.detail.pop && this.el.open) this.el.querySelector(":focus")?.blur()
            }
            window.addEventListener("resize", this.position)
            window.addEventListener("phx:navigate", this.navigate)
            this.quick.addEventListener("input", this.input)
            this.quick.addEventListener("click", this.open)
            this.el.addEventListener("cancel", this.cancelEvent)
            this.el.addEventListener("close", this.closed)
            this.el.addEventListener("click", this.click)
            this.el.addEventListener("keydown", this.keydown)
            this.handleEvent("open-task", ({id}) => {
              this.pendingNewTask = false
              this.editing = !!id
              this.returnTo = id ? `edit-task-${id}` : null
              this.open()
            })
            this.handleEvent("task-edit-closed", () => {
              if (this.pendingNewTask) {
                this.pushEvent("new-task", {})
                return
              }
              this.editing = false
              if (this.el.open) {
                this.el.close()
                this.restoreFocus()
              }
            })
            this.handleEvent("task-saved", () => {
              this.pendingNewTask = false
              this.form.reset()
              this.quick.value = ""
              this.el.close()
              this.restoreFocus()
            })
            if (this.el.dataset.open === "true") {
              this.editing = !!this.el.dataset.editingId
              this.returnTo = this.editing ? `edit-task-${this.el.dataset.editingId}` : null
              this.open()
            }
          },
          destroyed() {
            window.removeEventListener("resize", this.position)
            window.removeEventListener("phx:navigate", this.navigate)
            this.quick.removeEventListener("input", this.input)
            this.quick.removeEventListener("click", this.open)
            this.el.removeEventListener("cancel", this.cancelEvent)
            this.el.removeEventListener("close", this.closed)
            this.el.removeEventListener("click", this.click)
            this.el.removeEventListener("keydown", this.keydown)
          }
        }
      </script>
      <p :if={@groups == []}>Nothing to do.</p>
      <section
        :for={{group, items} <- @groups}
        aria-label={if is_nil(group), do: "Ungrouped tasks"}
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
            size={max(String.length(group), 1)}
            data-group={group}
            maxlength="100"
            phx-debounce="400"
            phx-blur="rename-group-blur"
            phx-value-old={group}
          />
          <button
            type="button"
            phx-click="open-task"
            phx-value-group={group}
            aria-label={"Add todo to #{group}"}
          >+</button>
        </.form>
        <ul class={if is_binary(group), do: "grouped"}>
          <%= for {section, index} <- Enum.with_index(Enum.chunk_by(items, &deadline_section/1)) do %>
            <li :if={index > 0}><hr /></li>
            <.task_row
              :for={task <- section}
              task={task}
              users={@users}
              errors={@inline_errors[task.id] || []}
            />
          <% end %>
        </ul>
      </section>
      <details
        :if={@completed_tasks != []}
        id="completed-tasks"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary>Completed ({length(@completed_tasks)})</summary><ul>
          <.task_row
            :for={task <- @completed_tasks}
            task={task}
            users={@users}
            errors={@inline_errors[task.id] || []}
          />
        </ul>
      </details>
      <dialog :if={@merge} id="merge-dialog" phx-hook=".MergeDialog" aria-labelledby="merge-title">
        <h2 id="merge-title">Merge groups?</h2><p>
          “{@merge.name}” already exists. Combine “{@merge.old}” with it?
        </p>
        <button phx-click="merge">Merge groups</button><button phx-click="cancel-merge">Choose another name</button>
      </dialog>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".MergeDialog">
        export default {
          mounted() {
            this.el.showModal()
            this.el.addEventListener("cancel", event => { event.preventDefault(); this.pushEvent("cancel-merge", {}) })
          }
        }
      </script>
    </main>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".QuickEntry">
      export default {
        mounted() {
          this.handleEvent("dialog-back", () => window.history.back())
          this.keydown = event => {
            const title = document.getElementById("quick-title")
            if (event.altKey && ["ArrowLeft", "ArrowRight"].includes(event.key) &&
              event.target.matches('input[data-completion]')) {
              event.preventDefault()
              const lists = [...this.el.querySelectorAll("[data-drop-list]")]
              const current = lists.findIndex(el => el.getAttribute("aria-current") === "page")
              const target = lists[current + (event.key === "ArrowRight" ? 1 : -1)]
              if (target) this.pushEvent("move-to-list", {
                id: event.target.closest("li").dataset.taskId, list_id: target.dataset.dropList
              })
            } else if (event.altKey && ["ArrowUp", "ArrowDown"].includes(event.key) &&
              event.target.matches('input[data-completion]')) {
              event.preventDefault()
              const row = event.target.closest("li")
              const groups = [...new Set([...this.el.querySelectorAll("[data-drop-group]")].map(el => el.dataset.dropGroup))]
              const index = Math.max(0, Math.min(groups.length - 1,
                groups.indexOf(row.dataset.group) + (event.key === "ArrowDown" ? 1 : -1)))
              this.pushEvent("move-task", {id: row.dataset.taskId, group: groups[index]})
            } else if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey && !event.isComposing &&
              !event.target.closest('input, textarea, select, button, summary, a, [contenteditable], dialog')) {
              title.focus()
            }
          }
          window.addEventListener("keydown", this.keydown)
          this.clearDrag = () => {
            if (!this.drag) return
            this.drag.row.classList.remove("dragging")
            this.drag.target?.classList.remove("drop-target")
            if (this.drag.grip.hasPointerCapture(this.drag.pointerId)) {
              this.drag.grip.releasePointerCapture(this.drag.pointerId)
            }
            this.drag = null
          }
          this.pointerdown = event => {
            this.skipClick = false
            if (!event.isPrimary || event.button !== 0 || !event.target.matches('input[data-completion]')) return
            this.drag = {row: event.target.closest("li"), grip: event.target,
              pointerId: event.pointerId, x: event.clientX, y: event.clientY, active: false}
            event.target.setPointerCapture(event.pointerId)
          }
          this.pointermove = event => {
            const drag = this.drag
            if (!drag || event.pointerId !== drag.pointerId) return
            if (!drag.active && Math.hypot(event.clientX - drag.x, event.clientY - drag.y) < 6) return
            drag.active = true
            event.preventDefault()
            drag.row.classList.add("dragging")
            const target = document.elementFromPoint(event.clientX, event.clientY)?.closest("[data-drop-group], [data-drop-list]")
            drag.target?.classList.remove("drop-target")
            drag.target = this.el.contains(target) ? target : null
            drag.target?.classList.add("drop-target")
          }
          this.pointerup = event => {
            const drag = this.drag
            if (!drag || event.pointerId !== drag.pointerId) return
            if (drag.active) {
              this.skipClick = true
              if (event.type === "pointerup" && drag.target) {
                if (drag.target.dataset.dropList && drag.target.getAttribute("aria-current") !== "page") {
                  this.pushEvent("move-to-list", {id: drag.row.dataset.taskId, list_id: drag.target.dataset.dropList})
                } else if (drag.target.dataset.dropGroup !== undefined && drag.target.dataset.dropGroup !== drag.row.dataset.group) {
                  this.pushEvent("move-task", {id: drag.row.dataset.taskId, group: drag.target.dataset.dropGroup})
                }
              }
            }
            this.clearDrag()
          }
          this.click = event => {
            if (this.skipClick && event.detail > 0) {
              event.preventDefault()
              event.stopImmediatePropagation()
              this.skipClick = false
            }
          }
          this.el.addEventListener("pointerdown", this.pointerdown)
          this.el.addEventListener("pointermove", this.pointermove)
          this.el.addEventListener("pointerup", this.pointerup)
          this.el.addEventListener("pointercancel", this.pointerup)
          this.el.addEventListener("click", this.click, true)
          this.handleEvent("focus-group", ({name}) => {
            const input = [...document.querySelectorAll("input[data-group]")].find(input => input.dataset.group === name)
            if (input) { input.focus(); input.select() }
          })
        },
        disconnected() { document.getElementById("connection-status").hidden = false },
        reconnected() { document.getElementById("connection-status").hidden = true },
        destroyed() {
          this.clearDrag()
          window.removeEventListener("keydown", this.keydown)
          this.el.removeEventListener("pointerdown", this.pointerdown)
          this.el.removeEventListener("pointermove", this.pointermove)
          this.el.removeEventListener("pointerup", this.pointerup)
          this.el.removeEventListener("pointercancel", this.pointerup)
          this.el.removeEventListener("click", this.click, true)
        }
      }
    </script>
    """
  end
end

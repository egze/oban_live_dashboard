defmodule Oban.LiveDashboard do
  use Phoenix.LiveDashboard.PageBuilder, refresher?: true

  import Phoenix.LiveDashboard.Helpers, only: [format_value: 2]
  import Ecto.Query

  @impl true
  def menu_link(_, _) do
    {:ok, "Oban"}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_table
      id="oban_jobs"
      dom_id="oban-jobs"
      page={@page}
      row_attrs={&row_attrs/1}
      row_fetcher={&fetch_jobs/2}
      title="Oban Jobs"
      search={false}
    >
      <:col field={:id} header="ID" sortable={:desc} />
      <:col field={:state} sortable={:desc} />
      <:col field={:queue} sortable={:desc} />
      <:col field={:worker} sortable={:desc} />
      <:col :let={job} field={:attempt} header="Attempts" sortable={:desc}>
        <%= job.attempt %>/<%= job.max_attempts %>
      </:col>
      <:col :let={job} field={:inserted_at} sortable={:desc}>
        <%= format_value(job.inserted_at) %>
      </:col>
      <:col :let={job} field={:scheduled_at} sortable={:desc}>
        <%= format_value(job.scheduled_at) %>
      </:col>
    </.live_table>
    <.live_modal
      :if={@job != nil}
      id="modal"
      title="Job"
      return_to={live_dashboard_path(@socket, @page, params: %{})}
    >
      <div class="mb-4 btn-toolbar" role="toolbar" aria-label="Oban Job actions">
        <div class="btn-group" role="group">
          <button type="button" class="btn btn-primary btn-sm mr-2" phx-click="run_job" phx-value-job={@job.id} disabled={!can_retry_job?(@job)}>Retry Job</button>
        </div>
        <div class="btn-group" role="group">
          <button type="button" class="btn btn-primary btn-sm" phx-click="cancel_job" phx-value-job={@job.id} disabled={!can_cancel_job?(@job)}>Cancel Job</button>
        </div>
      </div>
      <div class="tabular-info">
        <.label_value_list>
          <:elem label="ID"><%= @job.id %></:elem>
          <:elem label="State"><%= @job.state %></:elem>
          <:elem label="Queue"><%= @job.queue %></:elem>
          <:elem label="Worker"><%= @job.worker %></:elem>
          <:elem label="Args"><%= format_value(@job.args, nil) %></:elem>
          <:elem :if={@job.meta != %{}} label="Meta"><%= format_value(@job.meta, nil) %></:elem>
          <:elem :if={@job.tags != []} label="Tags"><%= format_value(@job.tags, nil) %></:elem>
          <:elem :if={@job.errors != []} label="Errors"><%= format_errors(@job.errors) %></:elem>
          <:elem label="Attempts"><%= @job.attempt %>/<%= @job.max_attempts %></:elem>
          <:elem label="Priority"><%= @job.priority %></:elem>
          <:elem label="Attempted at"><%= format_value(@job.attempted_at) %></:elem>
          <:elem :if={@job.cancelled_at} label="Cancelled at">
            <%= format_value(@job.cancelled_at) %>
          </:elem>
          <:elem :if={@job.completed_at} label="Completed at">
            <%= format_value(@job.completed_at) %>
          </:elem>
          <:elem :if={@job.discarded_at} label="Discarded at">
            <%= format_value(@job.discarded_at) %>
          </:elem>
          <:elem label="Inserted at"><%= format_value(@job.inserted_at) %></:elem>
          <:elem label="Scheduled at"><%= format_value(@job.scheduled_at) %></:elem>
        </.label_value_list>
      </div>
    </.live_modal>
    """
  end

  @impl true
  def handle_params(%{"params" => %{"job" => job_id}}, _url, socket) do
    case fetch_job(job_id) do
      {:ok, job} ->
        {:noreply, assign(socket, job: job)}

      :error ->
        to = live_dashboard_path(socket, socket.assigns.page, params: %{})
        {:noreply, push_patch(socket, to: to)}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, job: nil)}
  end

  @impl true
  def handle_refresh(socket) do
    {:noreply,
     Phoenix.Component.update(socket, :job, fn
       nil -> nil
       %{id: job_id} -> get_job(job_id)
     end)}
  end

  @impl true
  def handle_event("show_job", params, socket) do
    to = live_dashboard_path(socket, socket.assigns.page, params: params)
    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("run_job", %{"job" => job_id}, socket) do
    with {:ok, job} <- fetch_job(job_id),
         :ok <- Oban.Engine.retry_job(Oban.config(), job),
         # Refresh job
         {:ok, job} <- fetch_job(job.id) do
      {:noreply, assign(socket, :job, job)}
    else
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_job", %{"job" => job_id}, socket) do
    with {:ok, job} <- fetch_job(job_id),
         :ok <- Oban.Engine.cancel_job(Oban.config(), job) do
      to = live_dashboard_path(socket, socket.assigns.page, params: %{})
      {:noreply, push_patch(socket, to: to)}
    else
      _ ->
        {:noreply, socket}
    end
  end

  defp get_job(id) do
    Oban.Repo.get(Oban.config(), Oban.Job, id)
  end

  defp fetch_jobs(params, _node) do
    total_jobs = Oban.Repo.aggregate(Oban.config(), Oban.Job, :count)
    jobs = Oban.Repo.all(Oban.config(), jobs_query(params)) |> Enum.map(&Map.from_struct/1)
    {jobs, total_jobs}
  end

  defp fetch_job(id) do
    case get_job(id) do
      nil ->
        :error

      job ->
        {:ok, job}
    end
  end

  defp can_retry_job?(%Oban.Job{state: state}), do: state not in ["available", "executing"]

  defp can_cancel_job?(%Oban.Job{state: state}), do: state != "cancelled"

  defp jobs_query(%{sort_by: sort_by, sort_dir: sort_dir, limit: l}) do
    Oban.Job
    |> limit(^l)
    |> order_by({^sort_dir, ^sort_by})
  end

  defp row_attrs(job) do
    [
      {"phx-click", "show_job"},
      {"phx-value-job", job[:id]},
      {"phx-page-loading", true}
    ]
  end

  defp format_errors(errors) do
    Enum.map(errors, &Map.get(&1, "error"))
  end

  def format_value(%DateTime{} = datetime) do
    DateTime.to_string(datetime)
  end

  def format_value(nil), do: nil
end

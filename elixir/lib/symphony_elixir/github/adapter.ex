defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.{AgentTool, Client}
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @active_states ["open"]
  @terminal_states ["closed"]

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <-
           validate_states(
             tracker_settings.active_states,
             @active_states,
             :missing_github_active_states
           ),
         :ok <-
           validate_states(
             tracker_settings.terminal_states,
             @terminal_states,
             :missing_github_terminal_states
           ) do
      Client.validate_settings(tracker_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @spec open_human_gate(Issue.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def open_human_gate(%Issue{native_ref: %{"repo" => repo, "number" => number}}, body, required_labels)
      when is_binary(repo) and is_integer(number) and is_binary(body) do
    settings = Config.settings!().tracker
    issue_path = "/repos/#{repo}/issues/#{number}"

    with {:ok, %{status: status}} when status in 200..299 <-
           Client.request("POST", issue_path <> "/comments", %{}, %{"body" => body}, tracker_settings: settings),
         {:ok, %{status: label_status}} when label_status in 200..299 <-
           Client.request("POST", issue_path <> "/labels", %{}, %{"labels" => ["human-gate"]}, tracker_settings: settings),
         :ok <- remove_required_labels(issue_path, required_labels, settings) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  def open_human_gate(_issue, _body, _required_labels), do: {:error, :invalid_github_issue_reference}

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Client.secret_environment_names(tracker_settings)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp remove_required_labels(_issue_path, [], _settings), do: :ok

  defp remove_required_labels(issue_path, [label | rest], settings) when is_binary(label) do
    path = issue_path <> "/labels/" <> URI.encode(label, &URI.char_unreserved?/1)

    case Client.request("DELETE", path, %{}, nil, tracker_settings: settings) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 ->
        remove_required_labels(issue_path, rest, settings)

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp remove_required_labels(issue_path, [_invalid | rest], settings), do: remove_required_labels(issue_path, rest, settings)

  defp validate_states(states, allowed_states, _missing_error) when is_list(states) do
    if Enum.all?(states, &(normalize_state(&1) in allowed_states)) do
      :ok
    else
      {:error, :invalid_github_states}
    end
  end

  defp validate_states(_states, _allowed_states, missing_error), do: {:error, missing_error}

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end

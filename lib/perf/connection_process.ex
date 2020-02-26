defmodule Perf.ConnectionProcess do
  use GenServer

  require Logger

  defstruct [:conn, :params, request: %{}]

  def start_link({scheme, host, port, id}) do
    #conn_name = via(id)
    {:ok, pid} = GenServer.start_link(__MODULE__, {scheme, host, port}, name: id)
    send(pid, :late_init)
    #{:ok, conn_name}
    {:ok, pid}
  end

  def request(pid, method, path, headers, body) do
    :timer.tc(fn  ->
      GenServer.call(pid, {:request, method, path, headers, body})
    end)
  end

  ## Callbacks

  @impl true
  def init({scheme, host, port}) do
    state = %__MODULE__{conn: nil, params: {scheme, host, port}}
    {:ok, state}
  end

  @impl true
  def handle_info(:late_init, state = %__MODULE__{params: {scheme, host, port}}) do
    case Mint.HTTP.connect(scheme, host, port) do
      {:ok, conn} -> {:noreply, put_in(state.conn, conn)}
      {:error, _} -> {:noreply, state}
    end
  end


  @impl true
  def handle_call({:request, _, _, _, _}, _, state = %__MODULE__{conn: nil}) do
    Logger.error(fn -> "Invalid connection state: nil" end)
    send(self(), :late_init)
    Process.sleep(200)
    {:reply, {:error_conn, "Invalid connection state: nil"}, state}
  end

  @impl true
  def handle_call({:request, method, path, headers, body}, from, state) do
    init_time = :erlang.monotonic_time(:micro_seconds)
    case Mint.HTTP.request(state.conn, method, path, headers, body) do
      {:ok, conn, request_ref} ->
        state = put_in(state.conn, conn)
        state = put_in(state.request, %{from: from, response: %{}, ref: request_ref, init: init_time})
        {:noreply, state}

      {:error, conn, reason} ->
        state = put_in(state.conn, conn)
        send(self(), :late_init)
        {:reply, {:error_conn, reason}, state}
    end
  end

  @impl true
  def handle_info(message, state) do
    case Mint.HTTP.stream(state.conn, message) do
      :unknown ->
        Logger.error(fn -> "Received unknown message: " <> inspect(message) end)
        {:noreply, state}

      {:ok, conn, responses} ->
        state = put_in(state.conn, conn)
        state = Enum.reduce(responses, state, &process_response/2)
        {:noreply, state}

      {:error, conn, reason, responses} ->
        {scheme, host, port} = state.params
        case state.request do
          %{response: response, from: from, ref: request_ref} -> GenServer.reply(from, {:fail, response})
          _ -> nil
        end
        {:ok, new_conn} = Mint.HTTP.connect(scheme, host, port)
        state = put_in(state.conn, new_conn)
        {:noreply, state}
    end
  end

  defp process_response({:status, request_ref, status}, state) do
    case state.request do
      %{response: resp} -> put_in(state.request.response[:status], status)
      _ -> state
    end

  end

  defp process_response({:headers, request_ref, headers}, state) do
    state
  end

  defp process_response({:data, request_ref, new_data}, state) do
    state
  end
  
  defp process_response({:done, request_ref}, state) do
    case state.request do
      %{response: response, from: from, ref: request_ref, init: init} ->
        GenServer.reply(from, {:ok, :erlang.monotonic_time(:micro_seconds) - init})
        put_in(state.request, %{})
      _ -> put_in(state.request, %{})
    end
  end

end
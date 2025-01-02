defmodule RaRa do
  use GenServer
  require Logger

  @doc """
  Configuration for a Ra cluster node
  """
  defmodule Config do
    defstruct [
      # Unique identifier for this node
      :node_id,
      # Name of the Ra cluster
      :cluster_name,
      # Directory for persistence
      :data_dir,
      # List of other cluster members
      :members
    ]
  end

  defmodule State do
    defstruct [
      # Ra node configuration
      :config,
      # Ra server identifier
      :ra_server_id,
      # Current graph database state
      :graph_state,
      # Map of pending transactions
      :pending_txns
    ]
  end

  # Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: via_tuple(config.node_id))
  end

  def join_cluster(node_id, cluster_node) do
    GenServer.call(via_tuple(node_id), {:join_cluster, cluster_node})
  end

  def begin_transaction(node_id) do
    GenServer.call(via_tuple(node_id), :begin_transaction)
  end

  def commit_transaction(node_id, tx_id) do
    GenServer.call(via_tuple(node_id), {:commit_transaction, tx_id})
  end

  def add_vertex(node_id, tx_id, type, vertex_id, properties) do
    GenServer.call(via_tuple(node_id), {:add_vertex, tx_id, type, vertex_id, properties})
  end

  def add_edge(node_id, tx_id, from_id, to_id, type, properties) do
    GenServer.call(via_tuple(node_id), {:add_edge, tx_id, from_id, to_id, type, properties})
  end

  def query(node_id, pattern) do
    GenServer.call(via_tuple(node_id), {:query, pattern})
  end

  def get_cluster_members(node_id) do
    GenServer.call(via_tuple(node_id), :get_members)
  end

  def stop_node(node_id) do
    Supervisor.terminate_child(RaRa.Supervisor, node_id)
  end

  def define_schema(node_id, tx_id, type, properties) do
    GenServer.call(via_tuple(node_id), {:define_schema, tx_id, type, properties})
  end

  # Server Implementation

  def init(config) do
    Logger.info("Starting Ra node #{config.node_id}")

    # Initialize Ra server
    ra_server_id = {config.cluster_name, config.node_id}
    machine = {:module, RaRa.StateMachine, %{}, []}

    ra_server_config = %{
      reference: config.cluster_name,
      name: config.node_id,
      data_dir: config.data_dir,
      machine: machine,
      cluster_name: config.cluster_name
    }

    case :ra.start_server(ra_server_id, ra_server_config) do
      {:ok, _} ->
        state = %State{
          config: config,
          ra_server_id: ra_server_id,
          graph_state: %GraphDatabase.State{
            graph: LibGraph.new(:directed),
            schema: %{},
            transactions: %{},
            locks: %{},
            transaction_counter: 0
          },
          pending_txns: %{}
        }

        {:ok, state}

      error ->
        {:stop, error}
    end
  end

  def handle_call({:join_cluster, cluster_node}, _from, state) do
    target_server_id = {state.config.cluster_name, cluster_node}

    case :ra.add_member(state.ra_server_id, target_server_id) do
      {:ok, _, _} ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:begin_transaction, from, state) do
    command = {:begin_transaction, from}

    case :ra.process_command(state.ra_server_id, command) do
      {:ok, tx_id, _leader_id} ->
        new_state = put_in(state.pending_txns[tx_id], from)
        {:noreply, new_state}

      {:timeout, _} ->
        {:reply, {:error, :timeout}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:commit_transaction, tx_id}, from, state) do
    command = {:commit_transaction, tx_id, from}

    case :ra.process_command(state.ra_server_id, command) do
      {:ok, result, _} ->
        {:reply, result, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:add_vertex, tx_id, type, vertex_id, properties}, from, state) do
    command = {:add_vertex, tx_id, type, vertex_id, properties, from}

    case :ra.process_command(state.ra_server_id, command) do
      {:ok, result, _} ->
        {:reply, result, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:get_members, _from, state) do
    case :ra.members(state.ra_server_id) do
      {:ok, members, _leader} ->
        {:reply, members, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:define_schema, tx_id, type, properties}, _from, state) do
    command = {:define_schema, tx_id, type, properties}

    case :ra.process_command(state.ra_server_id, command) do
      {:ok, result, _} ->
        {:reply, result, state}

      error ->
        {:reply, error, state}
    end
  end

  # Handle other database operations similarly...

  # Private Functions

  defp via_tuple(node_id) do
    {:via, Registry, {RaRa.Registry, node_id}}
  end
end
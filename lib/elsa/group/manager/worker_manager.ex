defmodule Elsa.Group.Manager.WorkerManager do
  @moduledoc """
  Provides functions to encapsulate the management of worker
  processes by the consumer group manager.
  """
  import Record, only: [defrecord: 2, extract: 2]
  import Elsa.Group.Supervisor, only: [registry: 1]

  defrecord :brod_received_assignment, extract(:brod_received_assignment, from_lib: "brod/include/brod.hrl")

  defmodule WorkerState do
    @moduledoc """
    Tracks the running state of the worker process from the perspective of the group manager.
    """
    defstruct [:pid, :ref, :generation_id, :topic, :partition, :latest_offset]
  end

  @doc """
  Retrieve the generation id, used in tracking assignments of workers to topic/partition,
  from the worker state map.
  """
  @spec get_generation_id(map(), String.t(), integer()) :: integer()
  def get_generation_id(workers, topic, partition) do
    Map.get(workers, {topic, partition})
    |> Map.get(:generation_id)
  end

  @doc """
  Update the current offset for a given worker with respect to messages consumed
  from its topic/partition.
  """
  @spec update_offset(map(), String.t(), integer(), integer()) :: map() | no_return()
  def update_offset(workers, topic, partition, offset) do
    Map.update!(workers, {topic, partition}, fn worker -> %{worker | latest_offset: offset + 1} end)
  end

  @doc """
  Iterate over all workers managed by the group manager and issue the unsubscribe call
  to disengage from the topic/partition and shut down gracefully.
  """
  @spec stop_all_workers(map()) :: map()
  def stop_all_workers(workers) do
    workers
    |> Map.values()
    |> Enum.each(fn worker ->
      Process.demonitor(worker.ref)
      Elsa.Group.Worker.unsubscribe(worker.pid)
    end)

    %{}
  end

  @doc """
  Restart the specified worker from the manager state. Retrieve the latest recorded
  offset and pass it to the new worker to pick up where the previous left off if it
  has been recorded.
  """
  @spec restart_worker(map(), reference(), struct()) :: map()
  def restart_worker(workers, ref, %Elsa.Group.Manager.State{} = state) do
    worker = get_by_ref(workers, ref)

    assignment =
      brod_received_assignment(topic: worker.topic, partition: worker.partition, begin_offset: worker.latest_offset)

    start_worker(workers, worker.generation_id, assignment, state)
  end

  @doc """
  Construct an argument payload for instantiating a worker process, generate a
  topic/partition assignment and instantiate the worker process with both under
  the dynamic supervisor. Record the manager-relevant information and store in the
  manager state map tracking active worker processes.
  """
  @spec start_worker(map(), integer(), tuple(), struct()) :: map()
  def start_worker(workers, generation_id, assignment, %Elsa.Group.Manager.State{} = state) do
    assignment = Enum.into(brod_received_assignment(assignment), %{})

    init_args = [
      topic: assignment.topic,
      partition: assignment.partition,
      generation_id: generation_id,
      begin_offset: assignment.begin_offset,
      handler: state.handler,
      handler_init_args: state.handler_init_args,
      name: state.name,
      config: state.config
    ]

    supervisor = {:via, Registry, {registry(state.name), :worker_supervisor}}
    {:ok, worker_pid} = DynamicSupervisor.start_child(supervisor, {Elsa.Group.Worker, init_args})
    ref = Process.monitor(worker_pid)

    new_worker = %WorkerState{
      pid: worker_pid,
      ref: ref,
      generation_id: generation_id,
      topic: assignment.topic,
      partition: assignment.partition,
      latest_offset: assignment.begin_offset
    }

    Map.put(workers, {assignment.topic, assignment.partition}, new_worker)
  end

  defp get_by_ref(workers, ref) do
    workers
    |> Map.values()
    |> Enum.find(fn worker -> worker.ref == ref end)
  end
end

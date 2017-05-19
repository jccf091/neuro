defmodule Neuro.Layers.FullyConnectedTest do
  use ExUnit.Case
  require Logger
  alias Neuro.Layers.FullyConnected
  import Neuro.Test.NodesHelpers

  defmodule Wrapper do
    use Cuda.Graph

    def __graph__(graph) do
      graph |> chain(:fully, FullyConnected, graph.assigns.options) |> close()
    end

    def __assigns__(opts, env) do
      m = FullyConnected.__assigns__(opts, env)
      Map.drop(m, [:shared])
    end

    defdelegate __pins__(assings), to: FullyConnected
  end

  describe "fully connected layer" do
    setup do
      {:ok, shared} = Cuda.Shared.start_link()
      log_level = Logger.level()
      Logger.configure(level: :error)
      on_exit(fn -> Logger.configure(level: log_level) end)
      [shared: shared]
    end

    test "simple fully connected", ctx do
      i = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
      b = [1.0, 0.0]
      w = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0,
           1.5, 0.7, 6.4, 3.2, 2.1, 1.1, 0.1, 9.0]

      opts = [network: Wrapper,
              shared_pid: ctx[:shared],
              shared: %{weights: %{fully: w}, biases: %{fully: b}},
              network_options: [size: 8, out_size: 2]]
      {:ok, worker} = Cuda.Worker.start_link(opts)
      {:ok, o} = Cuda.Worker.run(worker, %{input: i})

      assert o.output |> round!() == [21.4, 12.5]
    end
  end
end

defmodule MinutemodemMobile.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Audio backend — must be running before any RxFSM tries to subscribe.
      MinutemodemMobile.Audio.LoopbackBackend
    ]

    opts = [strategy: :one_for_one, name: MinutemodemMobile.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

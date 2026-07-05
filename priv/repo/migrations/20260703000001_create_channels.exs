defmodule MinutemodemMobile.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    create table(:channels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :network_id, references(:networks, type: :binary_id, on_delete: :delete_all), null: false
      add :freq_hz, :integer, null: false
      add :name, :string
      add :mode, :string, null: false, default: "usb"
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:channels, [:network_id])
    create index(:channels, [:network_id, :position])
  end
end

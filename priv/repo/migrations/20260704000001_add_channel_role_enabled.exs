defmodule MinutemodemMobile.Repo.Migrations.AddChannelRoleEnabled do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      # "hailing" (calling/scan set) | "traffic" (data after link) | "none"
      add :role, :string, null: false, default: "none"
      # Independent on/off so a channel can be parked out of scan/use.
      add :enabled, :boolean, null: false, default: true
    end

    create index(:channels, [:network_id, :role])
  end
end

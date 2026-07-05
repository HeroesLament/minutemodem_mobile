defmodule MinutemodemMobile.Repo.Migrations.CreateRigConfigs do
  use Ecto.Migration

  def change do
    create table(:rig_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :model, :integer, null: false, default: 3010
      add :transport, :string, null: false, default: "usb"
      add :pathname, :string, null: false, default: "android-usb:0:0"
      add :serial_speed, :string, null: false, default: "19200"
      add :civaddr, :string
      add :ptt_type, :string, null: false, default: "RTS"

      timestamps(type: :utc_datetime_usec)
    end
  end
end

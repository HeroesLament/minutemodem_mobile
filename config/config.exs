import Config

# Minutewave protocol stack delegates DSP calls to this NIF module,
# which links against milwave-rs via the local native/phy_modem crate.
config :minutewave, phy_modem_nif: MinutemodemMobile.Nifs.PhyModem

# Minutewave audio backend: loopback for development/testing.
config :minutewave, audio_backend: MinutemodemMobile.Audio.LoopbackBackend

config :minutewave, rig_control: MinutemodemMobile.Rig.StubControl

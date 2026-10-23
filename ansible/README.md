## Local configuration

```bash
ansible-playbook \
  -i localhost, \
  -c local \
  -K \
  ansible/silverblue.yml
```
## Windows instance for WinApps

WinApps needs a Windows machine to connect to. To build one on the laptop,
set `enable_winapps_instance: true` and supply `winapps_revision` and
`winapps_instance_password` (from Vault), then run:

```bash
ansible-playbook \
  -i localhost, \
  -c local \
  -K \
  ansible/winapps-instance.yml
```

Windows installs itself unattended; watch it at <http://127.0.0.1:8006>.
It then runs as the `winapps.service` Quadlet, listening for RDP on
`127.0.0.1:3389`. Afterwards run `winapps-setup --user` to create the
application launchers.

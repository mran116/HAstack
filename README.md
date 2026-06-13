# homeassistant

The **Home Assistant / IoT domain** — separate from `home` because it's a
different runtime (a dedicated HAOS VM, not docker-compose), a
different config style (YAML packages/automations), and tied to physical
hardware (Zigbee/MQTT).

## Intended contents

| Path | What |
|---|---|
| `config/packages/` | HA packages (`household.yaml`, `alerts.yaml`, `media.yaml`, `firetv_remote.yaml`, …) — exported from the VM |
| `config/automations/` | automations + scripts |
| `lovelace/` | dashboard configs (`home-panel`, …) |
| `mqtt/` *(optional)* | Mosquitto broker compose, if run as a container |
| `zigbee/` *(optional)* | Zigbee2MQTT, if run as a container |

## Status

**Skeleton only.** HA config currently lives on the HAOS VM and is edited there
(via the token-auth API / Studio Code Server add-on). Populating this repo means
exporting `/config/packages`, automations, and lovelace from the VM — a
deliberate, separate task. **No secrets** (`secrets.yaml`, tokens, `.storage/`)
ever get committed; see `.gitignore`.

# Proxmox Helper: Synology SMB Share in LXC einbinden

Dieses Repository enthält ein Bash-Script, das auf einem Proxmox-Host ein Synology-NAS-Share per SMB/CIFS mountet und es anschließend per LXC-Bind-Mount in einen Container einbindet.

Das Standardverhalten ist bewusst **read-only**:

- Der SMB-Mount nutzt `ro`, `file_mode=0444` und `dir_mode=0555`.
- Der LXC-Bind-Mount nutzt `ro=1`.
- Damit hat der Container auf jeden Fall Leserechte, kann aber nicht versehentlich Dateien auf dem NAS verändern.

## Voraussetzungen

Führe das Script direkt auf dem Proxmox-Host als `root` aus. Das Script installiert `cifs-utils`, falls `mount.cifs` noch nicht vorhanden ist.

Der LXC-Container muss bereits existieren. Die Container-ID findest du zum Beispiel mit:

```bash
pct list
```

## Schnellstart

```bash
sudo ./proxmox-synology-lxc-smb.sh \
  --ctid 101 \
  --server 192.168.1.20 \
  --share daten \
  --username synology-user
```

Wenn kein Passwort übergeben wird, fragt das Script es verdeckt ab.

Nach erfolgreicher Ausführung ist das Share standardmäßig an diesen Orten verfügbar:

- Auf dem Proxmox-Host: `/mnt/synology-<share>`
- Im LXC-Container: `/mnt/synology-<share>`

## Optionen

```text
--ctid <ID>               LXC Container-ID auf dem Proxmox-Host
--server <HOST/IP>        Synology NAS Hostname oder IP-Adresse
--share <NAME>            SMB Share-Name
--username <USER>         SMB Benutzername
--password <PASSWORD>     SMB Passwort; wenn möglich lieber interaktiv eingeben
--domain <DOMAIN>         SMB Domain/Workgroup, Standard: WORKGROUP
--host-mount <PATH>       Mount-Pfad auf dem Proxmox-Host
--container-mount <PATH>  Mount-Pfad im LXC-Container
--credentials <PATH>      Pfad zur Credentials-Datei
--smb-version <VERSION>   SMB-Version, Standard: 3.0
--access-mode <MODE>      Rechte-Modus: read-only oder read-write, Standard: read-only
--read-only               Kurzform für --access-mode read-only
--read-write              Kurzform für --access-mode read-write
--no-start                Container nach der Konfiguration nicht starten
```

## Beispiel mit eigenem Pfad im Container

```bash
sudo ./proxmox-synology-lxc-smb.sh \
  --ctid 101 \
  --server nas.local \
  --share media \
  --username media-reader \
  --container-mount /srv/media \
  --access-mode read-only
```

## Rechte-Modus wählen

Standardmäßig wird `--access-mode read-only` verwendet. Das ist die sichere Variante, wenn der Container Dateien vom NAS nur lesen soll:

```bash
sudo ./proxmox-synology-lxc-smb.sh \
  --ctid 101 \
  --server nas.local \
  --share media \
  --username media-reader \
  --access-mode read-only
```

Wenn der Container Dateien auf dem NAS erstellen oder ändern soll, verwende `--access-mode read-write`:

```bash
sudo ./proxmox-synology-lxc-smb.sh \
  --ctid 101 \
  --server nas.local \
  --share media \
  --username media-writer \
  --access-mode read-write
```

Wichtig: Schreibzugriff funktioniert nur, wenn auch der verwendete Synology-Benutzer auf dem NAS Schreibrechte für das Share hat.

## Hinweise zu Rechten

Für unprivilegierte LXC-Container setzt der Host-Mount standardmäßig `uid=100000` und `gid=100000`, damit die Dateien im Container dem dortigen `root`-Mapping entsprechen. Die Leserechte werden zusätzlich über `file_mode=0444`, `dir_mode=0555` und den read-only Bind-Mount abgesichert.

Mit `--access-mode read-only` bleibt der Container lesend eingebunden. Mit `--access-mode read-write` erhält der Container Schreibzugriff, sofern der Synology-Benutzer auf dem NAS ebenfalls Schreibrechte besitzt. Alternativ kannst du die Kurzformen `--read-only` und `--read-write` verwenden.

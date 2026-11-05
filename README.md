# storc-agent

The zone9 executor (`zone9-agent`) that runs inside your Proxmox cluster, plus the
operator scripts that go with it. This repository was `z9cloud/zone9-agent`; GitHub
redirects the old address.

The agent connects **outbound only** (panel API, 443): no inbound port is opened, and
your Proxmox token stays on that machine — the panel never sees it.

This repository is distribution, not source. The zone9 source lives elsewhere; what is
published here is what an operator downloads and runs.

## Install the agent

```sh
curl -fsSL https://zone9.cloud/install.sh | sudo sh
```

Then edit `/etc/zone9/regions.yaml` and pair it with the registration token from the
panel:

```sh
zone9-agent register --token z9r_...
systemctl enable --now zone9-agent
```

Latest binaries: [releases/latest](https://github.com/storccloud/storc-agent/releases/latest)
(`zone9-agent-linux-amd64`, `zone9-agent-linux-arm64`).

### Updater

`storc-agent-update` keeps an agent (or an appliance daemon) on the latest release: it
downloads the binary, checks it against `SHA256SUMS` and `--version`, swaps it in and rolls
back if the service does not come up. Its old name was `zone9-agent-update`. Releases ship
both while machines with the old name exist; `storc-agent-update --migrate` moves one over
(old timer off, `/etc/default/zone9-agent-update` → `/etc/default/storc-agent-update`, new
timer on). The load balancer and object storage appliances do this themselves at boot, see
below.

## Guest image templates — `guest/`

The scripts here are named `storc-*`. Inside images and VMs they keep their `zone9-*` names
(`/usr/local/sbin/zone9-guest-net`, `/usr/local/sbin/zone9-lb-bootstrap`, `/etc/zone9/`),
because existing VMs cannot be renamed in place. `guest/zone9-ztn-gateway-bootstrap.sh`
keeps its old name: it exists only for old references to that name.

`guest/build-template.sh` builds a cloud image into a Proxmox template. It writes into
the image **without ever booting it**, which is what makes it reliable: the two failure
modes we hit building templates by hand — a systemd unit that was enabled and never
fired, and `cloud-init clean` deleting a freshly installed hook — cannot occur when the
image is never started.

It runs in **two phases**, split along their dependencies:

| Phase | Needs | Where | Output |
|---|---|---|---|
| `build` | libguestfs (~100 packages) | any x86_64 Linux box | a qcow2 file |
| `import` | `qm`, `qemu-img` (already present) | a Proxmox node | the template |

The split exists so that libguestfs — which pulls in ghostscript, x11-common, syslinux
and fonts — never has to be installed on a hypervisor.

```sh
curl -fsSLO https://raw.githubusercontent.com/storccloud/storc-agent/main/guest/build-template.sh
chmod +x build-template.sh

# on the build host (once: apt install libguestfs-tools)
./build-template.sh build debian-12
scp /var/tmp/zone9-templates/z9-debian-12.qcow2 root@<node>:/var/tmp/

# on the Proxmox node
./build-template.sh import 9031 /var/tmp/z9-debian-12.qcow2
```

Supported: `ubuntu-24.04`, `ubuntu-22.04`, `debian-12`, `rocky-9`. Add `--k3s` to bake in
the k3s binary without starting it, so one template serves both control-plane and worker
roles and a node does not wait on a download while booting.

If the template's disk lands on shared storage (Ceph, NFS), it is built once on one node
and can be cloned from every node in the cluster.

**Verify every new template.** Create a server from it, attach a public IP, and inside
the guest run `ip -4 route`. There must be exactly one `default` line, on the public
interface. Two `default` lines mean the template is incomplete — see below.

### Appliances: `gateway`, `lb`, `s3`

`./build-template.sh build lb` (or `gateway`, `s3`) builds a locked zone9 appliance: no
sshd, no login, no users. It enrols itself with the panel at first boot through
`guest/storc-<kind>-bootstrap.sh`, installed as `/usr/local/sbin/zone9-<kind>-bootstrap`,
which runs on every boot.

On the load balancer and object storage appliances the bootstrap also refreshes
`storc-agent-update` from the latest release (checked against `SHA256SUMS`) on every boot.
If the VM still has `zone9-agent-update` (or the new timer is not enabled), it then runs
`storc-agent-update --migrate`, so the VM moves itself over and nobody has to log in.

The bootstrap is baked into the template and every VM keeps the copy it was cloned with,
so a changed bootstrap reaches only VMs created after the template is rebuilt. Appliances
created earlier keep refreshing `zone9-agent-update` from the old repository address at
every boot, which is why releases keep shipping it.

### `guest/storc-guest-net.sh`

The routing policy that `build-template.sh` bakes into every image, as
`/usr/local/sbin/zone9-guest-net`. `guest/storc-guest-net.ps1` is the Windows counterpart,
put into Windows templates by `guest/storc-windows-prep.ps1`. Proxmox cloud-init
can only express "address + gateway" per interface, never a static route, so a VM with
both a public and a private interface receives **two default routes**. Traffic arrives on
the public interface but replies leave by whichever default the kernel picks; when that is
the private one they are dropped.

The symptom is distinctive and worth recognising: **50–70% packet loss and TCP connections
that never complete.** The script runs at every boot, keeps the default route on the public
leg and routes RFC1918 destinations through the private gateway. It is idempotent, and
`build-template.sh` fetches it automatically if it is not sitting next to the script.

The long-term fix is DHCP classless static routes (option 121), which moves the policy out
of the image and back into the platform.

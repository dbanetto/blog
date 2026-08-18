+++
title = "Exposing rootless containers"
description = "Using Podman, Quadlet and iptables to expose services"
date = 2025-10-11
updated = 2025-10-11

[taxonomies]
categories = ["tech"]
tags = ["podman", "quadlet", "iptables", "networking"]
+++

# Problem

This all started because I wanted to run some services on a VPS and expose them
in an easy way. To do this I wanted them to be:

 1. Easy to manage, with no overhead (a.k.a not using Kubernetes)
 1. Secure enough for my small scale, using rootless containers
 1. Stable enough to survive restarts & neglect
 1. (Bonus) Dual-stack IPv4 & v6.

Throughout this post I'll have the running example of setting up [Caddy reverse-proxy](https://caddyserver.com/) and [FreshRSS](https://freshrss.github.io/FreshRSS/).

# Managing containers

Recently I had a home Kubernetes cluster for this type of thing but that proved to be a large amount
of effort. So this time I'm aiming for low-tech containerisation solutions like Podman!

I happened to come across [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html), which
in short is a Systemd configuration layer on-top of Podman commands.
It generates `.service`'s from `.container`, `.network` and `.volume` and can understand the interlinks between them.

The development flow for them are basically:

 1. Look at some [examples](https://wiki.archlinux.org/title/Podman#Quadlet) or the [docs](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) for a starting point.
 1. Modify them to match a `docker-compose.yaml` you've found online
 1. Put them in the right location, lets say `~/.config/containers/systemd`
 1. Run `systemctl --user daemon-reload`
 1. Run `systemctl --user start container.server`
 1. Use `journalctl` to figure what you did wrong & repeat.


# Setting up a simple service

Will start this example with setting up FreshRSS. It only requires three things:

 1. A container to the service
 1. A volume to store its data
 1. A port to expose the service

For the container you can define it with Quadlet as:

```conf
# freshrss.container
[Unit]
Description=Fresh RSS container

[Container]
ContainerName=freshrss
Image=index.docker.io/freshrss/freshrss:1
AutoUpdate=registry # Auto-updating!
Network=example.network # We'll get to this soon
HostName=freshrss

Volume=freshrss-data.volume:/var/www/FreshRSS/data # <- Refrence to the volume
Environment=TZ=Etc/UTC
Environment=CRON_MIN=1,31
Environment=LISTEN=:8080

[Service]
Restart=on-failure

# Extend Timeout to allow time to pull the image
TimeoutStartSec=300

[Install]
WantedBy=default.target
```

For the volume, as we are not defining any option it can just be an empty file:

```conf
# freshrss-data.volume
```

One of the neat parts of this are:
 * No **YAML**! 🎉
 * `AutoUpdate=registry`, I get automatic updates from a built-in timer! Now it will update the `:1`-label to be the latest version daily.
 * The `.container` file references the `.volume` and it just works!

You'll note that we hadn't actually exposed a port here.
Which is correct, the container is in a podman network named `example.network`.


# Getting a bit more complicated with Caddy

With `podman` one of the first things you want to setup is a Network, cause the default network does not have DNS resolution
for other containers.

You can create a network via Quadlet with:

```conf
# example.network
[Network]
IPv6=true # <- This makes it a Dualstack network
Internal=false # <- Allows the network to publish ports to the host
```

To define the `Caddy` container:

```conf
# caddy.container
[Unit]
Description=Caddy Reverse Proxy container

[Container]
ContainerName=caddy
Image=caddy.build # <- Links to a locally built image
Network=example.network # <- Links to our network

Volume=caddy-config.volume:/config # <- Links volumes
Volume=caddy-data.volume:/data # <- Links volumes
Volume=caddy-etc.volume:/etc/caddy # <- Links volumes

Secret=caddy-cf-api,type=env,target=CF_API_TOKEN # <- Links secrets
Environment=DOMAIN=example.com

HostName=caddy
PublishPort=8080:80/tcp
PublishPort=8443:443/tcp
PublishPort=8443:443/udp

[Service]
Restart=on-failure

# Extend Timeout to allow time to build the image
TimeoutStartSec=900

[Install]
WantedBy=default.target
```

> Note: all of the `*.volume` files are just empty files -- I mean, an exercise left to the reader.

You will note a couple different things to the FreshRSS file, here we have:

 * The image is referencing a `.build` file
 * Reading a `podman secret` and injecting it as a environment variable
 * Publishing ports

### Making Quadlet build container image for you

For the `caddy.build` are instructing Quadlet to schedule a `systemd` job to build our image.
Which is super handy with Caddy where extra features like using Cloudflare for Lets Encrypt's DNS ACME challenge 
requires an addon.

You can do with this with

```conf
# caddy.build
[Unit]
Description=Building the caddy container
Requires=network-online.target

[Build]
File=/home/usr/caddy.Containerfile
ImageTag=localhost/caddy-cf-dns
Pull=newer

SetWorkingDirectory=unit
```

Then having a Containerfile like so:

```dockerfile
# caddy.Containerfile
ARG CADDY_VERSION=2.9.1

FROM docker.io/library/caddy:${CADDY_VERSION}-builder-alpine AS builder

# Pinned dependencies to handle the change of libdns v1.0 APIs
RUN xcaddy build "${CADDY_VERSION}" \
    --with github.com/caddyserver/certmagic@b9399eadfbe7ac3092f4e65d45284b3aabe514f8 \
    --with github.com/caddy-dns/cloudflare@bbf79111721a977fbd13dfe1f5b7aacaf7871a75

FROM docker.io/library/caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

> Note: I've had some issues with this due to `systemd` running this job before
> the internet connectivity is up.

### Sssh, keep this secret

Using `podman secret`'s with Quadlet is quite simple.
You just need to make them by hand, like so:

```bash
printf "secretdata" | podman secret create caddy-cf-api -
```

# Getting access

So far we've got Caddy and FreshRSS running as Rootless containers, so they cannot bind to any 
privileged port like `:80` or `:443`. So we need to figure out how to talk to them on those
port so we can have a good UX.

This could either solve this at the router with some port-mapping, or we could do that on the host
with `iptables`!

Setting these up by hand are a bit annoying so I'll be using Ansible here (sorry for the yaml):

{% raw %}
```yaml
- name: Allow Ingress
  ansible.builtin.iptables:
    table: filter
    chain: INPUT
    protocol: "{{ item.proto }}"
    ip_version: "{{ item.version }}"
    destination_port: "{{ item.port }}"
    action: insert
    jump: ACCEPT
  loop:
    # External
    - {port: 80, version: 'ipv4', proto: 'tcp'}
    - {port: 80, version: 'ipv6', proto: 'tcp'}
    - {port: 443, version: 'ipv4', proto: 'tcp'}
    - {port: 443, version: 'ipv6', proto: 'tcp'}
    - {port: 443, version: 'ipv4', proto: 'udp'}
    - {port: 443, version: 'ipv6', proto: 'udp'}

- name: Port Forwarding
  ansible.builtin.iptables:
    table: nat
    chain: OUTPUT
    out_interface: lo
    protocol: "{{ item.proto }}"
    match: "{{ item.proto }}"
    ip_version: "{{ item.version }}"
    destination_port: "{{ item.from }}"
    jump: REDIRECT
    to_ports: "{{ item.to }}"
    comment: "Redirect web traffic to Caddy port {{ item.from }}=>{{ item.to }}"
  loop:
    - {from: 80, to: 8080, version: 'ipv4', proto: 'tcp'}
    - {from: 80, to: 8080, version: 'ipv6', proto: 'tcp'}
    - {from: 443, to: 8443, version: 'ipv4', proto: 'tcp'}
    - {from: 443, to: 8443, version: 'ipv6', proto: 'tcp'}
    - {from: 443, to: 8443, version: 'ipv4', proto: 'udp'}
    - {from: 443, to: 8443, version: 'ipv6', proto: 'udp'}
```
{% endraw %}

> Note: Saving the `iptable` changes is an exercise left to the reader. I'm too embarrassed by how I do it to post it.

With these two blocks the host is setup with an ingress path on the privileged ports and
are redirected to the unprivileged ports used by the rootless `Caddy`!


# Problem re-cap

So to re-cap what just happened here:

 1. Easy to manage, with no overhead (a.k.a not using Kubernetes)
    * Quadlet makes use of systemd to manage your containers for you
    * It does most of the supporting work too: volumes, networks, image builds, and referencing secrets!
 1. Secure enough for my small scale, using rootless containers
    * Rootless with Quadlet + Podman is an easy as `systemctl --user start`
 1. Stable enough to survive restarts & neglect
    * `systemd` handles all my restart woes
    * Podman's `AutoUpdate=registry` ensure my images are up to date
 1. (Bonus) Dual-stack IPv4 & v6.
    * It was just a flag in the `.network`, how easy.

Overall, this has been a setup & forget situation.
The only time I have had an issue is when the container builds broke
due dependencies moving between major version of `libdns`.

I'd give it a 4/5, good for home-scale 👍 

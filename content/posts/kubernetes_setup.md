+++
title = "Homelab Kubernetes setup"
description = "Learning and being frugal"
date = 2025-05-11
updated = 2025-05-11

[taxonomies]
categories = ["tech"]
tags = ["homelab", "kubernetes", "k8s", "infra"]
+++

# Intro

This post is about some of the things that I've learnt while setting
up a small scale Kubernetes cluster for my "cloudlab" to learn from.

## Settings the stage

At `$day_job` I work with a few Kubernetes clusters and in particular at the
lower layers of the stack. Messing around with that tech is often needing to
rebuild clusters and mess them up good.

I have had a mulit-node homelab Kubernetes setup that got way too complicated
and died at the hands of an operator failure that I couldn't be bothered to recover from
(TL;DR longhorn + changing CNI == not a good time).

So, I decided to branch out of the old laptops under desk to the **_THE CLOUD_**.

I set out with the goal of:
 * Use IPv6
 * Self-host a GitOps flow
 * Spending as little as a I can


## Selecting an ☁️ Infra provider

Selecting a provider is like trying to find a sticky Telco that you
know you'll be paying for until your cloudlab-phase passed away.
So to help start the selecting process I came up with some metrics of 
success:

 * At least 2 vCPUs
 * At least 2 GiB RAM
 * At least 100+ GiB of traffic
 * Have a reasonable latency (_#JustAPACThings_ ;-;)
 * Cost to be less than AUD$10-per-node a month

After going through the [cluster-autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler/cloudprovider) provider list I eventually
landed on [Hetzner (my referral link)](https://hetzner.cloud/?ref=FHajdRC5nJ8C) as it is by _far_ the cheapest provider, even with the currency conversion.


### Infra setup

The original setup was:

 * 1 control plane node
 * 1 worker node
 * 1 Loadbalancer

Using:

 * [Talos](https://www.talos.dev/) for Kubernetes distribution
 * [Cilium](https://cilium.io/) for CNI, IPAM, and Ingress
 * [hetznercloud/hcloud-cloud-controller-manager](https://github.com/hetznercloud/hcloud-cloud-controller-manager) for load balancer
 * [hetznercloud/csi-driver](https://github.com/hetznercloud/csi-driver) for dynamic volumes

# First lesson: Do I need IPv4?

I could save many cents a month if I did not use IPv4 addresses on Hetzner, so of course I tried
to not use them. They give free IPv6 addresses for the nodes so I can still get some sweet
internet!

I hit a few snags along the way... like most of the internet is still only using IPv4 🧓.
Which I did find some cool services to help get around that, namely [nat64.net](https://nat64.net/)
which provides a DNS resolver and NAT64 to plug the gap.

As a Talos patch this looked like:

```yaml
machine:
  sysctls:
    net.ipv6.conf.all.forwarding: 1
  network:
    nameservers:
      # https://nat64.net/
      - 2a01:4f9:c010:3f02::1
      - 2a01:4f8:c2c:123f::1
      - 2a00:1098:2c::1
```

After which got the Talos control plane to a `Ready` state.

Next problem... the Pod and Service IPs were not assigning correctly
and all of the connectivity tests were failing once another node was added.

Turned out that I was in a bit of a pickle cause Hetzner assigns whole `/64`'s to each
node with public IPv6 and they're a bit random and discontinuous across nodes.
Kubenretes does not yet support adding new Pod CIDR ranges and assigning them to single nodes
natively. Cilium does have `CiliumNode` which can specify a `.spec.podCIDRs` but at this point
I've been a month deep & was about to gave up on life with computers.

Take away: Keep it simple for a first cluster!

# Second lesson: Why do I need a load balancer?

I got 1 worker node, and that is the only thing that will get requests
from the load balancer thanks in part to the
`node.kubernetes.io/exclude-from-external-load-balancers` label on the control nodes.

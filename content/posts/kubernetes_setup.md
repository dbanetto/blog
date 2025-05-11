+++
title = "Cloudlab Kubernetes setup"
description = "Learning and being frugal"
date = 2025-05-11
updated = 2025-05-11

[taxonomies]
categories = ["tech"]
tags = ["cloudlab", "homelab", "kubernetes", "k8s", "infra"]
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
 * Learn more about IPv6 & use with Kubernetes
 * Strictly use the [Gateway API](https://gateway-api.sigs.k8s.io/) and be able to use [GAMMA](https://gateway-api.sigs.k8s.io/mesh/)
 * Spending as little as a I can


## Selecting an ☁️ Infra provider

Selecting a provider is like trying to find a sticky Telco that you
know you'll be paying for until your cloudlab-phase passed away.
So to help start the selecting process I came up with some metrics of 
success:

 * At least 2 vCPUs
 * At least 2 GiB RAM
 * At least 100+ GiB of traffic, just in case
 * Have a reasonable latency (_#JustAPACThings_ ;-;)
 * Cost to be less than AUD$10-per-node a month

After going through the [cluster-autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler/cloudprovider) provider list I eventually
landed on [Hetzner (my referral link)](https://hetzner.cloud/?ref=FHajdRC5nJ8C) as it is by _far_ the cheapest provider, even with the currency conversion.


### Infra setup

The original "just get it working" setup was:

 * 1 control plane node
 * 1 worker node
 * 1 Loadbalancer

Using:

 * [Talos](https://www.talos.dev/) for Kubernetes distribution
 * [Cilium](https://cilium.io/) for CNI, IPAM, and Ingress
 * [hetznercloud/hcloud-cloud-controller-manager](https://github.com/hetznercloud/hcloud-cloud-controller-manager) for load balancer
 * [hetznercloud/csi-driver](https://github.com/hetznercloud/csi-driver) for dynamic volumes
 * [external-dns](https://github.com/kubernetes-sigs/external-dns/) to plumb load balancers to DNS

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

So in the end I gave up on my dream of being IPv4-less and have dualstack on the nodes and the
Kubernetes cluster itself are using private addresses.

> 📝 **Take away**: Keep it simple for a first cluster! Come back for IPv6 later

# Second lesson: Why do I need a load balancer?

I got whole dedicated load balancer for my 1 worker node... 
That's not very cost effective is it, but it was so easy to setup and get working.
The control plane node is excluded from the pool due to its label
`node.kubernetes.io/exclude-from-external-load-balancers`.
So lets remove that overkill load balancer!

Previously I had been using [`k3s`s' svclb](https://docs.k3s.io/networking/networking-services#service-load-balancer)
which uses the node's IP as its `LoadBalancer` IPs instead of needing extenral virtual IPs.
Luckily for me Cilium has a similar concept with [Node IPAM](https://docs.cilium.io/en/stable/network/node-ipam/#node-ipam)!

Now at this point I was using Cilium's Gateway API implementation, which is... how do I put it.
[Incomplete](https://github.com/cilium/cilium/pull/39038) and a [leader](https://gateway-api.sigs.k8s.io/implementations/v1.2/) at the same time. So naturally I ran into issues in trying to use
Node IPAM with Cilium's Gateway API.

The goal is to have the `v1.Service` of `cilium-<gateway-name>` to have `spec.loadBalancerClass: io.cilium/node`.
I ended needing to move to `v1.18.0-pre-release` (note _pre-release_) to use the new object
[`CiliumGatewayClassConfig`](https://github.com/cilium/cilium/blob/v1.18.0-pre.1/pkg/k8s/apis/cilium.io/client/crds/v2alpha1/ciliumgatewayclassconfigs.yaml) object to configure the `loadBalancerClass`.

It would kinda work, but not for privileged ports (<1024), and if you set the
`gatewayAPI.hostNetwork.enabled true` then it stops working. The latter becoming a culprit
after finding this [issue comment](https://github.com/cilium/cilium/issues/38227#issuecomment-2734913950).

After that I gave up on Cilium's Gateway API and looked for another implementation that
supports setting the `spec.loadBalancerClass` which to my surprise is two! 🤯

 * [envoy-gateway](https://gateway.envoyproxy.io/docs/api/extension_types/#envoyproxy)
 * [Istio](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/#automated-deployment)

So I went with Istio in Ambient mode to complicate my setup more which removed the need
for a dedicated load balancer. Now I'm relying on DNS client behavior to balance between
my 1 node.

> 📝**Take away**: Gateway API is really new, a lot of knobs are not available yet.


# Conculsion

I've learnt a lot from this cloudlab already:

 * IPv6 takes more thought than expected and Hetzner's implementation requires some extra concepts
 * Gateway API might be GA but the implementations don't feel like it

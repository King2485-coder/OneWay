# OneWay global production deployment

This is the production rollout plan for running OneWay globally with:

- `api.oneway.is` for the Node API and signaling
- `rtc.oneway.app` for LiveKit
- `turn.oneway.app` for TURN/TLS relay
- AWS Route 53 for DNS and health checks
- AWS ElastiCache Redis for presence and multi-instance fan-out
- S3 + CloudFront for voicemail, recordings, and media delivery

## Topology

```text
Clients
  -> Route 53 latency routing
  -> Cloudflare (WAF / DDoS / TLS edge)
  -> Regional ALB
  -> ECS or EC2 API nodes
  -> ElastiCache Redis
  -> Regional LiveKit nodes
  -> Dedicated TURN nodes

Media / assets
  -> S3
  -> CloudFront
```

## Recommended AWS regions

- `us-east-1` primary control plane
- `us-west-2` secondary North America
- `eu-west-1` Europe
- `ap-southeast-1` Asia-Pacific

## DNS records

Create these public records in Route 53:

```text
api.oneway.is   A / AAAA   -> latency alias to regional ALBs
rtc.oneway.app   A / AAAA   -> latency alias to LiveKit regional NLBs
turn.oneway.app  A / AAAA   -> latency or geo records to TURN VPS / NLB
media.oneway.app CNAME      -> CloudFront distribution
```

## Regional stack

Each region should run the same logical stack:

1. API nodes
2. Redis
3. LiveKit
4. TURN
5. Monitoring agents

Suggested mapping:

- API: ECS Fargate or EC2 Auto Scaling Group behind ALB
- Redis: ElastiCache Redis with Multi-AZ
- LiveKit: EC2 Auto Scaling Group or Kubernetes worker pool
- TURN: dedicated EC2 instances with public IPs

## LiveKit

Use the sample config in [livekit.yaml.example](/Users/king/Documents/OneWay/OneWay/infra/aws/livekit.yaml.example) and set:

- `rtc.oneway.app` as the public websocket URL
- Redis for cross-node coordination
- S3 for egress / recordings

## Backend environment

For each region, set:

```text
NODE_ENV=production
TRUST_PROXY=1
JWT_AUTH_REQUIRED=true
LIVEKIT_URL=wss://rtc.oneway.app
REDIS_URL=redis://<elasticache-endpoint>:6379
TURN_HOSTNAME=turn.oneway.app
S3_PUBLIC_URL_BASE=https://media.oneway.app
```

## Security

- Cloudflare proxy enabled for `api.oneway.is`
- AWS security groups limited to required ports only
- TLS certificates via ACM for ALBs
- JWT auth enforced in production
- WAF rate limiting on auth and call setup routes
- Sentry + CloudWatch alarms for 5xx, CPU, memory, and reconnect spikes

## Rollout order

1. Deploy `us-east-1`
2. Validate iOS production build against `api.oneway.is` and `rtc.oneway.app`
3. Deploy `us-west-2`
4. Turn on latency routing for `api.oneway.is`
5. Deploy Europe and APAC
6. Enable global failover health checks

## Validation

Run these checks after each region goes live:

1. `curl https://api.oneway.is/health`
2. Verify `/api/livekit/token` returns a JWT
3. Place a call across two devices on different networks
4. Confirm TURN allocation succeeds on LTE
5. Confirm VoIP push wakes the callee when the app is closed
6. Check Redis-backed call events across two API instances

## What still requires cloud access

This repo now contains the production-ready app/backend defaults and infra templates, but these steps still require your AWS / DNS / Apple credentials:

- buying or delegating `oneway.app`
- creating Route 53 hosted zones and latency records
- provisioning ALBs, EC2/ECS, ElastiCache, and S3
- issuing ACM / Let's Encrypt certificates
- enabling APNs production push credentials

# OneWay global rollout automation

This is the first-pass rollout shape for expanding OneWay across:

- `us-east-1`
- `us-west-2`
- `eu-west-1`
- `ap-southeast-1`

## Regional responsibilities

- API: regional app nodes behind load balancers
- LiveKit: regional SFU clusters
- Redis: regional cache / presence
- CDN: `cdn.oneway.app`
- Media: S3 + CloudFront

## Deployment command shape

```bash
./infra/aws/deploy-region.sh us-east-1
./infra/aws/deploy-region.sh us-west-2
./infra/aws/deploy-region.sh eu-west-1
./infra/aws/deploy-region.sh ap-southeast-1
```

## Routing

- App clients talk to `https://api.oneway.is`
- Edge and backend routing decide the best region
- Use latency routing and health checks for failover

## Performance goals

- nearest-region request routing
- adaptive bitrate for live/video media
- failover to healthy region on outage
- CDN-backed image/video delivery through `cdn.oneway.app`

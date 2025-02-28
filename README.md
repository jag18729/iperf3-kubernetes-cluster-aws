# iPerf3 Kubernetes Benchmark Cluster on AWS

This project helps you set up a network performance benchmark environment using iPerf3 on a Kubernetes cluster deployed on AWS EKS. It automates the process of creating an EKS cluster, deploying iPerf3 servers as DaemonSets on all nodes, scheduling client jobs to run tests periodically, and storing results in a PostgreSQL database.

## Overview

The benchmark system consists of:

1. **EKS Cluster**: Created through AWS CloudFormation
2. **iPerf3 Servers**: Deployed as DaemonSets on all nodes
3. **iPerf3 Client**: Runs as a CronJob to test connections to all servers
4. **PostgreSQL Database**: Stores test results for analysis

## Prerequisites

- AWS CLI configured (`aws configure`)
- `kubectl` command-line tool
- `jq` for JSON processing
- Docker (for building client image if needed)

## Quick Start

1. Clone this repository:
   ```
   git clone https://github.com/jag18729/iperf3-kubernetes-cluster-aws
   cd iperf3-kubernetes-cluster-aws
   ```

2. Run the deployment script:
   ```
   chmod +x deploy.sh
   ./deploy.sh
   ```

3. The first run will create a `config.json` file from the template. Edit this file with your AWS settings:
   ```json
   {
     "aws": {
       "region": "us-west-2",
       "cluster_name": "iperf3-cluster",
       "vpc_id": "",  // Leave empty to create a new VPC
       "subnet_ids": [],  // Leave empty to create new subnets
       "cluster_version": "1.28",
       "node_instance_type": "t3.medium",
       "node_min_size": 2,
       "node_max_size": 4
     },
     "kubernetes": {
       "namespace": "iperf3-benchmark"
     },
     "docker": {
       "registry": "your-registry"
     },
     "postgres": {
       "version": "13",
       "db_name": "iperfdb",
       "user": "iperfuser",
       "password": "change-me-please"
     },
     "iperf3": {
       "schedule": "*/5 * * * *",
       "server_ips": []  // Leave empty to use node IPs
     }
   }
   ```

4. Run the deployment script again:
   ```
   ./deploy.sh
   ```

## Viewing Results

To view the benchmark results:

1. Forward the PostgreSQL port:
   ```
   kubectl port-forward svc/postgres -n iperf3-benchmark 5432:5432
   ```

2. Connect to the database:
   ```
   psql -h localhost -U iperfuser -d iperfdb
   ```

3. Query the results using the view:
   ```sql
   SELECT * FROM throughput_metrics ORDER BY timestamp DESC LIMIT 20;
   ```

4. Compare performance across different test profiles:
   ```sql
   SELECT 
     profile,
     server,
     AVG(received_mbps)/1000000 as avg_mbps,
     MIN(received_mbps)/1000000 as min_mbps,
     MAX(received_mbps)/1000000 as max_mbps,
     STDDEV(received_mbps)/1000000 as stddev_mbps
   FROM throughput_metrics
   GROUP BY profile, server
   ORDER BY profile, avg_mbps DESC;
   ```

5. Analyze performance over time:
   ```sql
   SELECT 
     date_trunc('hour', timestamp) as hour,
     profile,
     AVG(received_mbps)/1000000 as avg_mbps
   FROM throughput_metrics
   GROUP BY hour, profile
   ORDER BY hour DESC, profile;
   ```

## Cleanup

To delete all resources:

```
chmod +x cleanup.sh
./cleanup.sh
```

## Project Structure

- `/cloudformation` - AWS CloudFormation template for EKS cluster
- `/k8s` - Kubernetes manifest files
- `/client` - iPerf3 client Dockerfile and scripts
- `deploy.sh` - Main deployment script
- `cleanup.sh` - Cleanup script
- `config.json` - Configuration file (generated from template)

## Customization

You can customize the benchmark environment by:

1. Modifying instance types in `config.json`
2. Changing test frequency by updating the cron schedule
3. Building a custom client image with additional tools
4. Creating new test profiles in the `config.json` file

### Test Profile Configuration

The system supports multiple test profiles for comprehensive network testing. Here's a sample configuration:

```json
"test_profiles": [
  {
    "name": "tcp-default",
    "protocol": "tcp",
    "duration": 10,
    "parallel": 1,
    "interval": 1,
    "format": "JSON",
    "reverse": false,
    "zerocopy": true,
    "enabled": true
  },
  {
    "name": "udp-test",
    "protocol": "udp",
    "duration": 10,
    "parallel": 1,
    "bandwidth": "100M",
    "interval": 1,
    "format": "JSON",
    "enabled": false
  }
]
```

Available parameters:

| Parameter      | Description                                           | Default |
|----------------|-------------------------------------------------------|---------|
| name           | Unique profile name                                   | required |
| protocol       | Test protocol (`tcp` or `udp`)                        | tcp     |
| duration       | Test duration in seconds                              | 10      |
| parallel       | Number of parallel client threads                     | 1       |
| interval       | Seconds between periodic reports                      | 1       |
| format         | Output format (always JSON in this implementation)    | JSON    |
| reverse        | Reverse the direction (server sends, client receives) | false   |
| window         | TCP window size (e.g. "1M")                           | -       |
| bandwidth      | Target bandwidth for UDP tests (e.g. "100M")          | -       |
| bidirectional  | Run test in both directions simultaneously            | false   |
| zerocopy       | Use zero-copy method for sending data                 | false   |
| enabled        | Whether this profile should be run                    | false   |

## Troubleshooting

If you encounter issues:

- Check EKS cluster status: `aws eks describe-cluster --name iperf3-cluster`
- View cluster logs: `kubectl logs -n iperf3-benchmark deployment/postgres`
- Check client job status: `kubectl get jobs -n iperf3-benchmark`
- Verify server pods: `kubectl get pods -n iperf3-benchmark -l app=iperf3-server`

## License

This project is licensed under the MIT License - see the LICENSE file for details.

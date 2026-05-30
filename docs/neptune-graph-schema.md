# Neptune Graph Schema & Queries

## Graph Schema

### Vertices (Nodes)

| Label | ID Pattern | Properties | Source |
|-------|-----------|------------|--------|
| `Investigation` | `inv:{incident_id}` | incident_id, task_id, space_id, region, status, routed_to | DynamoDB Stream |
| `Workspace` | `ws:{space_id}` | space_id, region | DynamoDB Stream |
| `Resource` | `res:{name_normalized}` | name | DynamoDB Stream (from RCA) |
| `Cause` | `cause:{cause_id}` | name | DynamoDB Stream (from cascade_graph) |
| `InfraResource` | `cfg:{type}:{id}` | resource_type, resource_id, resource_name, region | AWS Config (every 5 min) |

### Edges (Relationships)

| Label | From → To | Meaning | Source |
|-------|-----------|---------|--------|
| `investigated_by` | Investigation → Workspace | Which workspace handled it | DynamoDB Stream |
| `affects` | Investigation → Resource | Blast radius (from RCA) | DynamoDB Stream |
| `root_cause` | Investigation → Cause | What caused the incident | DynamoDB Stream |
| `cascades_to` | Cause → Cause | Failure propagation chain | DynamoDB Stream |
| `linked_to` | Investigation → Investigation | Agent linked (same root cause) | DynamoDB Stream |
| `is_in` | InfraResource → InfraResource | VPC/subnet containment | AWS Config |
| `attached_to` | InfraResource → InfraResource | SG/ENI attachment | AWS Config |
| `routes_to` | InfraResource → InfraResource | Network routing | AWS Config |
| `related_to` | InfraResource → InfraResource | Generic Config relationship | AWS Config |

### Visual Schema

```
(Workspace: eu-west-1)
       ▲
       │ investigated_by
       │
(Investigation: cpu-stress-123) ──affects──► (Resource: EKS chaos-cluster)
       │                                            ▲
       │ root_cause                                 │ affects
       ▼                                            │
(Cause: no-cpu-limit) ──cascades_to──► (Cause: pod-restarts)
       ▲                                     │
       │ root_cause                          │
       │                                     ▼
(Investigation: cpu-stress-456) ◄──linked_to── (Investigation: cpu-stress-789)
```

## Example Gremlin Queries

### 1. Find all investigations affecting a specific resource

```gremlin
g.V('res:eks_cluster_chaos-cluster')
  .in('affects')
  .hasLabel('Investigation')
  .valueMap('incident_id', 'status', 'region')
```

### 2. Cross-workspace correlation (same resource, different workspaces)

```gremlin
g.V().hasLabel('Resource').as('r')
  .in('affects').hasLabel('Investigation').as('inv')
  .out('investigated_by').hasLabel('Workspace').as('ws')
  .select('r', 'inv', 'ws')
  .by('name')
  .by('incident_id')
  .by('region')
  .groupBy('r')
```

### 3. Blast radius: what's 2 hops from a failing resource?

```gremlin
g.V('res:rds_orders-db')
  .in('affects')
  .out('root_cause')
  .out('cascades_to')
  .path()
```

### 4. Most frequently affected resources (last 24h)

```gremlin
g.V().hasLabel('Resource')
  .project('resource', 'hit_count')
  .by('name')
  .by(__.in('affects').count())
  .order().by('hit_count', desc)
  .limit(10)
```

### 5. Find linked investigation chains

```gremlin
g.V().hasLabel('Investigation')
  .has('status', 'LINKED')
  .out('linked_to')
  .path()
  .by('incident_id')
```

### 6. Dependency graph for a specific incident

```gremlin
g.V('inv:fis-chaos-cpu-stress-1779338031')
  .union(
    out('affects').hasLabel('Resource'),
    out('root_cause').out('cascades_to').hasLabel('Cause')
  )
  .path()
```

### 7. Which workspaces share the same root causes?

```gremlin
g.V().hasLabel('Cause').as('c')
  .in('root_cause').hasLabel('Investigation')
  .out('investigated_by').hasLabel('Workspace').as('ws')
  .select('c', 'ws')
  .by('name')
  .by('region')
  .dedup()
```

## Visualization

### Neptune Workbench (built-in)
- Open Neptune console → Workbench → Notebook
- Run Gremlin queries with `%%gremlin` magic
- Graph visualization renders automatically

### Grafana (via Neptune plugin)
- Install Grafana Neptune data source plugin
- Point to Neptune reader endpoint
- Build dashboards with graph panels

### Export to D3.js
```gremlin
// Get all vertices and edges for a subgraph
g.V().hasLabel('Investigation', 'Resource', 'Cause')
  .project('id', 'label', 'properties')
  .by(id)
  .by(label)
  .by(valueMap())
```

## Data Flow

```
INCIDENT PATH (real-time):
  Investigation completes
      → Dispatcher writes to DynamoDB (status, task_id, space_id)
      → rca-writer adds affected_resources + cascade_graph to same DDB record
      → DynamoDB Stream fires
      → Neptune Feeder Lambda reads stream record
      → Writes Investigation + Resource + Cause vertices + edges

INFRASTRUCTURE PATH (every 5 min):
  EventBridge scheduled rule
      → Config Sync Lambda
      → Calls AWS Config: ListDiscoveredResources + SelectResourceConfig
      → Writes InfraResource vertices + relationship edges to Neptune
      → Graph now has full infra topology alongside incident data

QUERY (on demand):
  "Show me all investigations that affected resources in subnet-abc"
  → Joins Investigation.affects → Resource → InfraResource.is_in → subnet
```

## Example Queries: Joining Incidents with Infrastructure

### 8. Find all infrastructure connected to a failing resource

```gremlin
g.V().hasLabel('InfraResource')
  .has('resource_name', 'chaos-cluster')
  .both()
  .hasLabel('InfraResource')
  .valueMap('resource_type', 'resource_name', 'region')
```

### 9. Which subnets had incidents in the last hour?

```gremlin
g.V().hasLabel('Investigation')
  .out('affects').hasLabel('Resource')
  .out('related_to').hasLabel('InfraResource')
  .has('resource_type', 'AWS::EC2::Subnet')
  .dedup()
  .valueMap('resource_name', 'region')
```

### 10. Full blast radius: incident → affected resources → connected infra

```gremlin
g.V('inv:fis-chaos-cpu-stress-1779338031')
  .out('affects')
  .out('related_to')
  .repeat(both().hasLabel('InfraResource').simplePath())
  .times(2)
  .path()
  .by(valueMap('resource_type', 'resource_name'))
```

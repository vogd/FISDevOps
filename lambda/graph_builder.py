"""
Graph Builder Lambda — runs every 5 min, reads graph/*.json from S3,
assembles a static HTML visualization, writes to s3://bucket/graph/index.html.
"""
import json
import os
import boto3

s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET"]
TABLE_NAME = os.environ.get("TABLE_NAME", "fis-chaos-investigations")
PREFIX = "graph/"


def load_graph_nodes():
    """Load graph data from S3 (completed, last 30 days) + DynamoDB (live/in-progress)."""
    from datetime import datetime, timezone, timedelta
    cutoff = datetime.now(timezone.utc) - timedelta(days=30)

    # 1. Completed investigations from S3 (have full RCA data)
    nodes_by_id = {}
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=PREFIX):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".json") and obj["LastModified"].replace(tzinfo=timezone.utc) >= cutoff:
                try:
                    body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
                    node = json.loads(body)
                    nodes_by_id[node.get("incident_id", "")] = node
                except Exception:
                    pass

    # 2. Live investigations from DynamoDB (includes In Progress, Created, etc.)
    try:
        ddb = boto3.resource("dynamodb")
        table = ddb.Table(TABLE_NAME)
        resp = table.scan(ProjectionExpression="incident_id, detail_type, #s, space_id, #r, last_updated, task_id",
                          ExpressionAttributeNames={"#s": "status", "#r": "region"})
        cutoff_ts = int((datetime.now(timezone.utc) - timedelta(days=30)).timestamp())
        for item in resp.get("Items", []):
            inc_id = item.get("incident_id", "")
            if not inc_id:
                continue
            last_updated = int(item.get("last_updated", 0))
            if last_updated and last_updated < cutoff_ts:
                continue
            # Only add if not already in S3 data (S3 has richer data for completed ones)
            if inc_id not in nodes_by_id:
                status = item.get("status", item.get("detail_type", ""))
                # Normalize status from detail_type
                if "In Progress" in status:
                    status = "IN_PROGRESS"
                elif "Created" in status:
                    status = "PENDING_START"
                elif "Completed" in status:
                    status = "COMPLETED"
                elif "Failed" in status:
                    status = "FAILED"
                elif "Linked" in status:
                    status = "LINKED"
                nodes_by_id[inc_id] = {
                    "incident_id": inc_id,
                    "status": status,
                    "ts": datetime.fromtimestamp(last_updated, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if last_updated else "",
                    "affected_resources": [],
                    "cascade_graph": [],
                    "resource_arns": [],
                    "task_id": item.get("task_id", ""),
                    "space_id": item.get("space_id", ""),
                    "region": item.get("region", ""),
                }
            else:
                # Enrich existing S3 node with DDB link data
                nodes_by_id[inc_id]["task_id"] = item.get("task_id", "")
                nodes_by_id[inc_id]["space_id"] = item.get("space_id", "")
                nodes_by_id[inc_id]["region"] = item.get("region", "")
    except Exception as e:
        print(f"DynamoDB scan error (non-fatal): {e}")

    return list(nodes_by_id.values())


def build_graph_data(investigations):
    """Convert investigation nodes into D3 graph format."""
    nodes = {}
    edges = []

    for inv in investigations:
        inc_id = inv.get("incident_id", "")
        if not inc_id:
            continue
        label = inc_id.replace("fis-chaos-", "").rsplit("-", 1)[0]
        nodes[inc_id] = {"type": "Investigation", "label": label, "status": inv.get("status", ""), "ts": inv.get("ts", ""), "task_id": inv.get("task_id", ""), "space_id": inv.get("space_id", ""), "region": inv.get("region", "")}

        for res in inv.get("affected_resources", []):
            res_id = f"res:{res}"
            nodes[res_id] = {"type": "Resource", "label": res, "status": "", "ts": ""}
            edges.append((inc_id, res_id, "affects"))

        for cascade in inv.get("cascade_graph", []):
            from_node = cascade.get("from", "")
            if from_node:
                from_id = f"cause:{from_node}"
                nodes[from_id] = {"type": "Cause", "label": from_node.replace("-", " "), "status": "", "ts": ""}
                edges.append((inc_id, from_id, "root_cause"))
                for to_node in (cascade.get("to") if isinstance(cascade.get("to"), list) else [cascade.get("to", "")]):
                    if to_node:
                        to_id = f"cause:{to_node}"
                        nodes[to_id] = {"type": "Cause", "label": to_node.replace("-", " "), "status": "", "ts": ""}
                        edges.append((from_id, to_id, "cascades_to"))

        for arn in inv.get("resource_arns", []):
            arn_id = f"arn:{arn}"
            short = arn.split("/")[-1].split(":")[-1]
            nodes[arn_id] = {"type": "Resource", "label": short, "status": "", "ts": ""}
            edges.append((inc_id, arn_id, "affects"))

    edges = list(set(edges))
    d3_nodes = [{"id": k, "type": v["type"], "label": v["label"], "status": v.get("status", ""), "ts": v.get("ts", ""), "task_id": v.get("task_id", ""), "space_id": v.get("space_id", ""), "region": v.get("region", "")} for k, v in nodes.items()]
    d3_links = [{"source": e[0], "target": e[1], "label": e[2]} for e in edges]
    return {"nodes": d3_nodes, "links": d3_links}


def generate_html(graph_data):
    n = len(graph_data["nodes"])
    e = len(graph_data["links"])
    data_json = json.dumps(graph_data)

    # Use string concatenation to avoid f-string conflicts with JS braces
    html_top = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>FIS Chaos - Incident Graph</title>
<meta http-equiv="refresh" content="300">
<script src="https://d3js.org/d3.v7.min.js"></script>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{font-family:-apple-system,sans-serif;background:#1a1a2e;color:#eee;overflow:hidden}}
#controls{{position:fixed;top:10px;left:10px;z-index:10;background:rgba(0,0,0,.8);padding:12px;border-radius:8px;font-size:13px;width:210px}}
#controls select{{background:#333;border:1px solid #555;color:#eee;padding:4px 8px;border-radius:4px;width:100%;margin:4px 0;font-size:12px}}
#controls label{{display:block;margin:4px 0;cursor:pointer}}
#legend{{position:fixed;top:10px;right:10px;z-index:10;background:rgba(0,0,0,.8);padding:12px;border-radius:8px;font-size:12px}}
.li{{display:flex;align-items:center;margin:4px 0}}.ld{{width:12px;height:12px;border-radius:50%;margin-right:8px}}
#tooltip{{position:fixed;background:rgba(0,0,0,.95);border:1px solid #555;padding:8px 12px;border-radius:6px;font-size:12px;pointer-events:none;display:none;max-width:350px;z-index:100}}
#stats{{position:fixed;bottom:10px;right:10px;z-index:10;background:rgba(0,0,0,.8);padding:8px 12px;border-radius:8px;font-size:11px;color:#888}}
#search{{position:fixed;bottom:10px;left:10px;z-index:10;background:rgba(0,0,0,.8);padding:8px;border-radius:8px}}
#search input{{background:#333;border:1px solid #555;color:#eee;padding:6px 10px;border-radius:4px;width:200px;font-size:13px}}
h3{{margin-bottom:6px;font-size:13px;color:#ff9900}}
</style>
</head>
<body>
<div id="controls">
<h3>Time Range</h3>
<select id="timeFilter"><option value="0">All Time</option><option value="15">Last 15 min</option><option value="60">Last 1 hour</option><option value="360">Last 6 hours</option><option value="1440">Last 24 hours</option><option value="10080">Last 7 days</option><option value="43200">Last 30 days</option></select>
<h3 style="margin-top:8px">Status</h3>
<select id="statusFilter"><option value="ALL">All</option><option value="NOT_COMPLETED">Not Completed</option><option value="IN_PROGRESS">In Progress</option><option value="COMPLETED">Completed</option><option value="POLL_TIMEOUT">Poll Timeout</option><option value="FAILED">Failed</option></select>
<h3 style="margin-top:8px">Nodes</h3>
<label><input type="checkbox" checked data-type="Investigation"> Investigations</label>
<label><input type="checkbox" checked data-type="Resource"> Resources</label>
<label><input type="checkbox" checked data-type="Cause"> Causes</label>
<h3 style="margin-top:8px">Edges</h3>
<label><input type="checkbox" checked data-edge="affects"> affects</label>
<label><input type="checkbox" checked data-edge="root_cause"> root_cause</label>
<label><input type="checkbox" checked data-edge="cascades_to"> cascades_to</label>
</div>
<div id="legend"><h3>Legend</h3>
<div class="li"><div class="ld" style="background:#ff9900"></div>Investigation</div>
<div class="li"><div class="ld" style="background:#1f9bcf"></div>Resource</div>
<div class="li"><div class="ld" style="background:#e74c3c"></div>Cause</div>
<div style="margin-top:8px;font-size:11px;color:#888">Auto-refreshes every 5 min<br>Click node to highlight<br>Scroll to zoom</div>
</div>
<div id="tooltip"></div>
<div id="search"><input type="text" placeholder="Search..." id="searchInput"></div>
<div id="stats">{n} nodes - {e} edges</div>
<svg id="graph"></svg>
<script>
const data={data_json};
'''

    # JS code as raw string (no f-string interpolation)
    js_code = r'''
const tc={Investigation:"#ff9900",Resource:"#1f9bcf",Cause:"#e74c3c"};
const sc={IN_PROGRESS:"#f59e0b",COMPLETED:"#27ae60",POLL_TIMEOUT:"#e74c3c",FAILED:"#c0392b",TIMED_OUT:"#8e44ad",LINKED:"#065f46",PENDING_START:"#fbbf24",PENDING_TRIAGE:"#fbbf24"};
const ec={affects:"#1f9bcf55",root_cause:"#e74c3c55",cascades_to:"#ff990055"};
const sz={Investigation:7,Resource:5,Cause:5};
function nc(d){if(d.type==="Investigation"&&d.status&&sc[d.status])return sc[d.status];return tc[d.type]}
const w=innerWidth,h=innerHeight;
const svg=d3.select("#graph").attr("width",w).attr("height",h);
const g=svg.append("g");
const tooltip=d3.select("#tooltip");
svg.call(d3.zoom().scaleExtent([.1,8]).on("zoom",e=>g.attr("transform",e.transform)));
const sim=d3.forceSimulation(data.nodes).force("link",d3.forceLink(data.links).id(d=>d.id).distance(60)).force("charge",d3.forceManyBody().strength(-100)).force("center",d3.forceCenter(w/2,h/2)).force("collision",d3.forceCollide().radius(d=>sz[d.type]+2));
const link=g.append("g").selectAll("line").data(data.links).join("line").attr("stroke",d=>ec[d.label]||"#44444488").attr("stroke-width",1.2);
const node=g.append("g").selectAll("circle").data(data.nodes).join("circle").attr("r",d=>sz[d.type]).attr("fill",d=>nc(d)).attr("stroke","#fff").attr("stroke-width",.5).call(d3.drag().on("start",(e,d)=>{if(!e.active)sim.alphaTarget(.3).restart();d.fx=d.x;d.fy=d.y}).on("drag",(e,d)=>{d.fx=e.x;d.fy=e.y}).on("end",(e,d)=>{if(!e.active)sim.alphaTarget(0);d.fx=null;d.fy=null}));
const label=g.append("g").selectAll("text").data(data.nodes.filter(d=>d.type==="Investigation")).join("text").text(d=>d.label).attr("font-size","9px").attr("fill","#ccc").attr("dx",10).attr("dy",3);
sim.on("tick",()=>{link.attr("x1",d=>d.source.x).attr("y1",d=>d.source.y).attr("x2",d=>d.target.x).attr("y2",d=>d.target.y);node.attr("cx",d=>d.x).attr("cy",d=>d.y);label.attr("x",d=>d.x).attr("y",d=>d.y)});
node.on("mouseover",(e,d)=>{let x=d.status?"<br>Status: "+d.status:"";if(d.ts)x+="<br>Time: "+d.ts;if(d.task_id&&d.space_id)x+='<br><a href="https://'+d.space_id+'.aidevops.global.app.aws/investigation/'+d.task_id+'" target="_blank" style="color:#ff9900">Open in DevOps Agent</a>';tooltip.style("display","block").style("left",e.clientX+12+"px").style("top",e.clientY-10+"px").style("pointer-events","auto").html("<b>"+d.label+"</b><br>Type: "+d.type+x+"<br><small>"+d.id+"</small>")}).on("mouseout",()=>{setTimeout(()=>{if(!tooltip.node().matches(":hover"))tooltip.style("display","none").style("pointer-events","none")},300)});
let sel=null;
node.on("dblclick",(e,d)=>{if(d.task_id&&d.space_id)window.open("https://"+d.space_id+".aidevops.global.app.aws/investigation/"+d.task_id,"_blank")});
node.on("click",(e,d)=>{if(sel===d.id){sel=null;node.attr("opacity",1);link.attr("opacity",1);label.attr("opacity",1);return}sel=d.id;const c=new Set([d.id]);data.links.forEach(l=>{if(l.source.id===d.id)c.add(l.target.id);if(l.target.id===d.id)c.add(l.source.id)});data.links.forEach(l=>{if(c.has(l.source.id))c.add(l.target.id)});node.attr("opacity",n=>c.has(n.id)?1:.08);link.attr("opacity",l=>(c.has(l.source.id)&&c.has(l.target.id))?1:.03);label.attr("opacity",n=>c.has(n.id)?1:.08)});
document.getElementById("timeFilter").addEventListener("change",af);
document.getElementById("statusFilter").addEventListener("change",af);
document.querySelectorAll("[data-type]").forEach(cb=>cb.addEventListener("change",af));
document.querySelectorAll("[data-edge]").forEach(cb=>cb.addEventListener("change",af));
function af(){const tm=parseInt(document.getElementById("timeFilter").value);const sv=document.getElementById("statusFilter").value;const types=new Set([...document.querySelectorAll("[data-type]:checked")].map(c=>c.dataset.type));const et=new Set([...document.querySelectorAll("[data-edge]:checked")].map(c=>c.dataset.edge));const now=new Date();const cut=tm>0?new Date(now.getTime()-tm*60000):null;const vi=new Set();data.nodes.forEach(n=>{if(n.type==="Investigation"){let pt=true;if(cut&&n.ts)pt=new Date(n.ts)>=cut;else if(cut&&!n.ts)pt=false;let ps=sv==="ALL"||(sv==="NOT_COMPLETED"?n.status!=="COMPLETED":n.status===sv);if(pt&&ps)vi.add(n.id)}});const r=new Set(vi);data.links.forEach(l=>{const s=typeof l.source==="object"?l.source.id:l.source;const t=typeof l.target==="object"?l.target.id:l.target;if(vi.has(s))r.add(t);if(vi.has(t))r.add(s)});data.links.forEach(l=>{const s=typeof l.source==="object"?l.source.id:l.source;const t=typeof l.target==="object"?l.target.id:l.target;if(r.has(s))r.add(t)});node.attr("display",d=>{if(!types.has(d.type))return"none";if(d.type==="Investigation")return vi.has(d.id)?null:"none";return r.has(d.id)?null:"none"});label.attr("display",d=>vi.has(d.id)?null:"none");link.attr("display",d=>{const s=typeof d.source==="object"?d.source.id:d.source;const t=typeof d.target==="object"?d.target.id:d.target;if(!et.has(d.label))return"none";if(!r.has(s)||!r.has(t))return"none";return null});const vc=data.nodes.filter(n=>{if(n.type==="Investigation")return vi.has(n.id);return r.has(n.id)&&types.has(n.type)}).length;document.getElementById("stats").textContent=vc+" nodes visible"}
document.getElementById("searchInput").addEventListener("input",e=>{const q=e.target.value.toLowerCase();if(!q){node.attr("opacity",1);link.attr("opacity",1);label.attr("opacity",1);return}const m=new Set(data.nodes.filter(n=>n.label.toLowerCase().includes(q)||n.id.toLowerCase().includes(q)).map(n=>n.id));node.attr("opacity",n=>m.has(n.id)?1:.15);link.attr("opacity",.05);label.attr("opacity",n=>m.has(n.id)?1:.1)});
</script>
</body>
</html>'''

    return html_top + js_code


def handler(event, context):
    investigations = load_graph_nodes()
    if not investigations:
        print("No graph data found")
        return {"status": "empty"}

    graph_data = build_graph_data(investigations)
    html = generate_html(graph_data)

    s3.put_object(
        Bucket=BUCKET,
        Key="graph/index.html",
        Body=html,
        ContentType="text/html",
    )

    print(f"Graph built: {len(graph_data['nodes'])} nodes, {len(graph_data['links'])} edges from {len(investigations)} investigations")
    return {"status": "built", "nodes": len(graph_data["nodes"]), "edges": len(graph_data["links"])}

# API-Based Multi-Workspace Template

## Overview

This template uses the **coder-login module** + **Coder REST API** to dynamically create additional workspaces from within the startup script.

### How It Works

1. User creates a workspace with `additional_workspaces=N` parameter
2. The primary workspace starts normally with full K8s resources
3. The startup script uses `coder-login` module to authenticate
4. Once authenticated, it uses the Coder CLI to create N additional workspaces
5. Child workspaces are created with `additional_workspaces=0` to prevent infinite loops

### Key Features

✅ **Pure Terraform** - No external scripts needed  
✅ **Single Template** - Reuses the same template for children  
✅ **Automatic Loop Prevention** - Detects child workspaces by naming pattern  
✅ **Authenticated** - Uses coder-login module for secure API access  
✅ **Idempotent** - Won't recreate existing workspaces  

## Parameters

- **additional_workspaces**: Number of extra workspaces to create (0-9)
- **cpu**: CPU cores per workspace (2-8)
- **memory**: Memory in GB per workspace (2-8)
- **home_disk_size**: Persistent storage in GB (1-99999)

## Usage

### 1. Push Template

```bash
cd api-based-template
coder templates push kubernetes-multi \
  --variable namespace=coder \
  --variable use_kubeconfig=false
```

### 2. Create Workspace with Children

```bash
# Create primary workspace that spawns 3 children
coder create my-team \
  --template kubernetes-multi \
  --parameter additional_workspaces=3 \
  --parameter cpu=4 \
  --parameter memory=8
```

This creates:
- `my-team` (primary workspace with full resources)
- `my-team-1` (child workspace)
- `my-team-2` (child workspace)
- `my-team-3` (child workspace)

### 3. View Workspaces

```bash
coder list
# Shows: my-team, my-team-1, my-team-2, my-team-3

coder ssh my-team-1
coder open my-team-2 --app code-server
```

## How Child Creation Works

The startup script contains this logic:

```bash
# 1. Authenticate using coder-login module
${module.coder_login.init_script}

# 2. Get current workspace name and template
WORKSPACE_NAME="${data.coder_workspace.me.name}"
TEMPLATE_NAME="${data.coder_workspace_build_info.me.template_name}"

# 3. Prevent infinite loop - skip if this is already a child
if echo "$WORKSPACE_NAME" | grep -qE '\-[0-9]+$'; then
  echo "This is a child workspace, skipping"
else
  # 4. Create N children using Coder CLI
  for i in $(seq 1 "$ADDITIONAL_COUNT"); do
    CHILD_NAME="$${WORKSPACE_NAME}-$${i}"
    
    coder create "$CHILD_NAME" \
      --template "$TEMPLATE_NAME" \
      --parameter additional_workspaces=0 \  # Prevent recursion
      --parameter cpu=${cpu} \
      --parameter memory=${memory} \
      --yes
  done
fi
```

## Loop Prevention

The template has TWO mechanisms to prevent infinite workspace creation:

1. **Naming Pattern Detection**: If workspace name ends with `-<number>`, it's a child and skips creation
2. **Parameter Override**: Child workspaces are created with `additional_workspaces=0`

## Architecture

```
User Creates: my-team (additional_workspaces=3)
    │
    ├─ Primary Workspace: my-team
    │   ├─ Kubernetes Deployment
    │   ├─ PVC
    │   ├─ Agent with coder-login
    │   └─ Startup Script:
    │       ├─ Authenticates via coder-login
    │       └─ Creates children via API
    │
    └─ Creates via API:
        ├─ my-team-1 (additional_workspaces=0)
        ├─ my-team-2 (additional_workspaces=0)
        └─ my-team-3 (additional_workspaces=0)
```

## Advantages

| Feature | This Approach | CLI Scripts | coderd Provider |
|---------|---------------|-------------|-----------------|
| **Terraform Native** | ✅ Yes | ❌ No | ✅ Yes |
| **Single Template** | ✅ Yes | ✅ Yes | ❌ No (needs 2) |
| **Works Today** | ✅ Yes | ✅ Yes | ❌ No |
| **Declarative** | ⚠️ Partial | ❌ No | ✅ Yes |
| **Loop Prevention** | ✅ Built-in | N/A | N/A |
| **External Deps** | ✅ None | ❌ Scripts | ✅ None |

## Limitations

1. **Sequential Creation**: Children are created one-by-one in startup script (not parallel)
2. **Startup Time**: Primary workspace takes longer to become "ready" while creating children
3. **Max 9 Children**: Limited to 0-9 for simplicity (can be increased)
4. **Naming Convention**: Must follow `name-N` pattern for loop detection
5. **Same Template**: All children use the same template as parent
6. **Manual Cleanup**: Deleting primary doesn't auto-delete children

## Cleanup

Deleting the primary workspace does NOT delete children:

```bash
# Manual cleanup required
coder delete my-team-1 --yes
coder delete my-team-2 --yes
coder delete my-team-3 --yes
coder delete my-team --yes
```

Or use the CLI script:
```bash
# From parent directory
./coder-multi-delete.sh my-team 3
```

## Troubleshooting

### Issue: Children not being created

Check the primary workspace agent logs:
```bash
coder ssh my-team
cat /tmp/coder-agent.log | grep -A 20 "Creating additional"
```

### Issue: "coder: command not found"

The coder-login module should handle this, but verify:
```bash
coder ssh my-team
which coder
coder version
```

### Issue: Authentication failure

The coder-login module authentication might have failed:
```bash
coder ssh my-team
coder login --check
```

### Issue: Infinite loop (children creating children)

Check workspace names - children should end with `-<number>`:
```bash
coder list
# Good: my-team, my-team-1, my-team-2
# Bad:  my-team, my-team-child, my-team-child-1 (would loop)
```

## Advanced Usage

### Custom Naming Pattern

Modify the loop detection in `coder.tf`:

```bash
# Instead of checking for -N suffix, use a tag
if [ -f /home/coder/.is-child-workspace ]; then
  echo "This is a child workspace, skipping"
else
  # Create children and tag them
  for i in $(seq 1 "$ADDITIONAL_COUNT"); do
    coder create "$CHILD_NAME" ...
    coder ssh "$CHILD_NAME" -- "touch /home/coder/.is-child-workspace"
  done
fi
```

### Different Parameters per Child

```bash
# Modify the creation loop to pass different params
for i in $(seq 1 "$ADDITIONAL_COUNT"); do
  CPU=$((2 * i))  # Double CPU for each child
  MEMORY=$((4 * i))  # More memory
  
  coder create "$CHILD_NAME" \
    --parameter cpu=$CPU \
    --parameter memory=$MEMORY \
    ...
done
```

### Using REST API Directly

Instead of Coder CLI, use curl with the API:

```bash
# Get template version ID
TEMPLATE_VERSION_ID=$(curl -H "Coder-Session-Token: $CODER_SESSION_TOKEN" \
  "$CODER_URL/api/v2/templates/$TEMPLATE_ID/versions/latest" | jq -r .id)

# Create workspace via API
curl -X POST "$CODER_URL/api/v2/organizations/$ORG_ID/workspaces" \
  -H "Coder-Session-Token: $CODER_SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-team-1",
    "template_id": "'$TEMPLATE_ID'",
    "rich_parameter_values": [
      {"name": "additional_workspaces", "value": "0"},
      {"name": "cpu", "value": "4"}
    ]
  }'
```

## Monitoring

Add metadata to track child creation status:

```hcl
metadata {
  display_name = "Child Creation Status"
  key          = "child_status"
  script       = <<EOT
    if [ -f /tmp/child-creation-complete ]; then
      echo "✅ Complete"
    elif [ -f /tmp/child-creation-inprogress ]; then
      echo "⏳ In Progress"
    else
      echo "⏸️ Not Started"
    fi
  EOT
  interval = 30
  timeout  = 1
}
```

## Files

- `main.tf` - Kubernetes resources (deployment, PVC)
- `coder.tf` - Agent, parameters, apps, child creation logic
- `providers.tf` - Provider configuration
- `variables.tf` - Template variables
- `README.md` - This file

## Next Steps

1. Review the startup script in `coder.tf`
2. Customize loop detection if needed
3. Test with small numbers first (`additional_workspaces=1`)
4. Push template and create workspace
5. Monitor logs during child creation

## Comparison to Other Solutions

### vs. CLI Scripts (coder-multi-create.sh)
- **Pro**: Terraform-native, no external scripts
- **Con**: Sequential creation (slower), harder to customize per-child

### vs. coderd Provider
- **Pro**: Actually works (provider doesn't support workspaces)
- **Con**: N/A (provider approach isn't viable)

### vs. Manual UI Clicking
- **Pro**: Automated, consistent, repeatable
- **Con**: Slightly longer startup time for primary workspace

## References

- [Coder Login Module](https://registry.coder.com/modules/coder-login)
- [Coder REST API](https://coder.com/docs/reference/api/workspaces)
- [Coder Agent Startup Scripts](https://coder.com/docs/templates/agent-startup)

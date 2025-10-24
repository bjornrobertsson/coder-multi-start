provider "coder" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

module "coder-login" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/coder-login/coder"
  version  = "1.1.0"
  agent_id = coder_agent.main.id
}


# Parameter for number of additional workspaces to create
data "coder_parameter" "additional_workspaces" {
  name         = "additional_workspaces"
  display_name = "Additional Workspaces"
  description  = "Number of additional workspaces to create via API (0-9). Creates workspace-name-1, workspace-name-2, etc."
  default      = "0"
  type         = "number"
  icon         = "/icon/memory.svg"
  mutable      = false
  validation {
    min = 0
    max = 9
  }
}

data "coder_parameter" "auto_update_children" {
  name         = "auto_update_children"
  display_name = "Auto-update Child Workspaces"
  description  = "Automatically update child workspaces when template changes"
  default      = "true"
  type         = "bool"
  icon         = "/icon/reload.svg"
  mutable      = true
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "The number of CPU cores"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  dynamic "option" {
    for_each = range(2, 10, 2)
    content {
      name  = "${option.value} Cores"
      value = "${option.value}"
    }
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "The amount of memory in GB"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  dynamic "option" {
    for_each = range(2, 10, 2)
    content {
      name  = "${option.value} GB"
      value = "${option.value}"
    }
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk size"
  description  = "The size of the home disk in GB"
  default      = "10"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 1
    max = 99999
  }
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  
  env = {
    TEMPLATE_NAME = var.template_name
  }
  
  # Startup script that uses coder login and creates additional workspaces
  startup_script = <<-EOT
    set -e

    # Install the latest code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server

    # Start code-server in the background
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &

    # Create additional workspaces if requested
    ADDITIONAL_COUNT="${data.coder_parameter.additional_workspaces.value}"
    AUTO_UPDATE="${data.coder_parameter.auto_update_children.value}"
    
    # Check for marker file to prevent infinite loops
    # Child workspaces will have this file created
    MARKER_FILE="$HOME/.coder-child-workspace"
    
    # Create marker file if additional_workspaces is 0 (this is a child)
    if [ "$ADDITIONAL_COUNT" -eq 0 ]; then
      touch "$MARKER_FILE"
      echo "Marker file created - this is a child workspace"
    fi
    
    if [ -f "$MARKER_FILE" ]; then
      echo "This is a child workspace (marker file exists), skipping child creation"
    elif [ "$ADDITIONAL_COUNT" -gt 0 ]; then
      echo "Creating $ADDITIONAL_COUNT additional workspace(s)..."
      
      # Install jq if not present (needed for status checks)
      if ! command -v jq >/dev/null 2>&1; then
        echo "Installing jq..."
        sudo apt-get update -qq && sudo apt-get install -y -qq jq >/dev/null 2>&1 || echo "Warning: Failed to install jq, using fallback status detection"
      fi
      
      # Wait for coder-login module to authenticate
      echo "Waiting for Coder authentication..."
      MAX_WAIT=60
      WAIT_COUNT=0
      
      while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if command -v coder >/dev/null 2>&1 && coder list >/dev/null 2>&1; then
          echo "✅ Coder CLI authenticated successfully"
          break
        fi
        
        if [ $WAIT_COUNT -eq 0 ]; then
          echo "Waiting for coder-login module to complete..."
        elif [ $((WAIT_COUNT % 10)) -eq 0 ]; then
          echo "Still waiting... ($WAIT_COUNT seconds elapsed)"
        fi
        
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
      done
      
      if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "❌ ERROR: Timed out waiting for Coder authentication after $MAX_WAIT seconds"
        echo "The coder-login module may have failed. Check agent logs."
        exit 1
      fi
      
      # Get current workspace details
      WORKSPACE_NAME="${data.coder_workspace.me.name}"
      TEMPLATE_NAME="$TEMPLATE_NAME"
      
      # Create additional workspaces using Coder CLI
      for i in $(seq 1 "$ADDITIONAL_COUNT"); do
        CHILD_NAME="$${WORKSPACE_NAME}-$${i}"
        
        echo "Checking workspace: $CHILD_NAME"
        
        # Check if workspace exists using coder show (more reliable)
        if coder show "$CHILD_NAME" >/dev/null 2>&1; then
          echo "  ✅ Workspace $CHILD_NAME exists"
          
          # Get workspace status and version info
          WORKSPACE_INFO=$(coder list --output json 2>/dev/null)
          if [ -n "$WORKSPACE_INFO" ] && command -v jq >/dev/null 2>&1; then
            WORKSPACE_STATUS=$(echo "$WORKSPACE_INFO" | jq -r ".[] | select(.name==\"$CHILD_NAME\") | .latest_build.status" 2>/dev/null)
            WORKSPACE_OUTDATED=$(echo "$WORKSPACE_INFO" | jq -r ".[] | select(.name==\"$CHILD_NAME\") | .outdated" 2>/dev/null)
          fi
          
          # Fallback if jq fails or returns empty
          if [ -z "$WORKSPACE_STATUS" ] || [ "$WORKSPACE_STATUS" = "null" ]; then
            WORKSPACE_STATUS=$(coder show "$CHILD_NAME" 2>/dev/null | grep -oP '(?<=Status:\s{1,10})\w+' | head -1 || echo "unknown")
          fi
          
          echo "  Status: $WORKSPACE_STATUS"
          if [ "$WORKSPACE_OUTDATED" = "true" ]; then
            echo "  🔄 Template: outdated"
          fi
          
          # Auto-update if enabled and workspace is outdated
          if [ "$AUTO_UPDATE" = "true" ] && [ "$WORKSPACE_OUTDATED" = "true" ]; then
            echo "  🔄 Updating workspace $CHILD_NAME to latest template..."
            echo y | coder update "$CHILD_NAME" || echo "  ⚠️  Failed to update $CHILD_NAME"
          # Start workspace if it's stopped (and update if outdated)
          elif [ "$WORKSPACE_STATUS" = "stopped" ]; then
            if [ "$AUTO_UPDATE" = "true" ] && [ "$WORKSPACE_OUTDATED" = "true" ]; then
              echo "  🔄 Updating and starting workspace $CHILD_NAME..."
              echo y | coder update "$CHILD_NAME" || echo "  ⚠️  Failed to update $CHILD_NAME"
            else
              echo "  🚀 Starting workspace $CHILD_NAME..."
              coder start "$CHILD_NAME" --yes || echo "  ⚠️  Failed to start $CHILD_NAME"
            fi
          # Warn if outdated but auto-update is disabled
          elif [ "$WORKSPACE_OUTDATED" = "true" ]; then
            echo "  ⚠️  Workspace is outdated (auto-update disabled)"
          else
            echo "  ✅ Workspace is $WORKSPACE_STATUS and up-to-date"
          fi
        else
          echo "  🆕 Creating workspace: $CHILD_NAME"
          
          # Create workspace with additional_workspaces=0 to prevent infinite recursion
          coder create "$CHILD_NAME" \
            --template "$TEMPLATE_NAME" \
            --parameter additional_workspaces=0 \
            --parameter cpu=${data.coder_parameter.cpu.value} \
            --parameter memory=${data.coder_parameter.memory.value} \
            --parameter home_disk_size=${data.coder_parameter.home_disk_size.value} \
            --yes \
            && echo "  ✅ Created $CHILD_NAME" \
            || echo "  ❌ Failed to create $CHILD_NAME"
        fi
        
        echo ""
      done
      
      echo "Finished creating additional workspaces"
    fi
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    script       = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval     = 60
    timeout      = 1
  }
  
  metadata {
    display_name = "Additional Workspaces"
    key          = "additional_workspaces"
    script       = "echo '${data.coder_parameter.additional_workspaces.value}'"
    interval     = 300
    timeout      = 1
  }
}

# code-server for primary workspace
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server (Primary)"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

# App to show child workspace links  
resource "coder_app" "child_workspace_links" {
  agent_id     = coder_agent.main.id
  slug         = "child-links"
  display_name = "📂 Child Workspace Links"
  icon         = "/icon/folder.svg"
  command      = <<-EOT
    #!/bin/bash
    set -e
    
    ADDITIONAL_COUNT="${data.coder_parameter.additional_workspaces.value}"
    WORKSPACE_NAME="${data.coder_workspace.me.name}"
    CODER_URL="${data.coder_workspace.me.access_url}"
    
    if [ "$ADDITIONAL_COUNT" -eq 0 ]; then
      echo "No child workspaces configured"
      exit 0
    fi
    
    echo "=== Child Workspace Quick Links ==="
    echo ""
    echo "Open terminals and apps in child workspaces:"
    echo ""
    
    for i in $(seq 1 "$ADDITIONAL_COUNT"); do
      CHILD_NAME="$${WORKSPACE_NAME}-$${i}"
      echo "Child Workspace $i: $CHILD_NAME"
      echo "  Terminal:    $CODER_URL/@me/$CHILD_NAME/terminal"
      echo "  code-server: $CODER_URL/@me/$CHILD_NAME/apps/code-server"
      echo "  SSH:         coder ssh $CHILD_NAME"
      echo ""
    done
    
    echo "Tip: Copy the URLs above to open child workspaces"
  EOT
  subdomain = false
  share     = "owner"
}

#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export SCRIPT_ROOT="$(mktemp -d)"
  mkdir -p "$SCRIPT_ROOT/scripts" "$SCRIPT_ROOT/docker"
  cp "$REPO_DIR/scripts/lib-tools.sh" "$SCRIPT_ROOT/scripts/lib-tools.sh"
}

teardown() {
  rm -rf "$SCRIPT_ROOT"
}

@test "tools_conf_ensure creates an all-off file when missing" {
  run bash -c "source '$SCRIPT_ROOT/scripts/lib-tools.sh'; tools_conf_ensure; grep -c '=off' \"\$TOOLS_CONF\"; grep -c '=on' \"\$TOOLS_CONF\" || true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"20"* ]]
}

@test "tools_parse_strict accepts a valid file with comments and blank lines" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    printf '# comment\n\nTOOL_PYTHON=on\nTOOL_GO=off\n' > \"\$TOOLS_CONF\"
    tools_parse_strict \"\$TOOLS_CONF\"
  "
  [ "$status" -eq 0 ]
}

@test "tools_parse_strict rejects an unknown key" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    echo 'TOOL_BOGUS=on' > \"\$TOOLS_CONF\"
    tools_parse_strict \"\$TOOLS_CONF\"
  "
  [ "$status" -eq 1 ]
}

@test "tools_parse_strict rejects a non-on/off value" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    echo 'TOOL_PYTHON=maybe' > \"\$TOOLS_CONF\"
    tools_parse_strict \"\$TOOLS_CONF\"
  "
  [ "$status" -eq 1 ]
}

@test "tools_parse_strict rejects a lowercase key" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    echo 'tool_python=on' > \"\$TOOLS_CONF\"
    tools_parse_strict \"\$TOOLS_CONF\"
  "
  [ "$status" -eq 1 ]
}

@test "tools_get falls back to off and warns on an invalid file" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    echo 'TOOL_PYTHON=maybe' > \"\$TOOLS_CONF\"
    tools_get PYTHON
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"off"* ]]
  [[ "$output" == *"WARNING"* ]]
}

@test "tools_set writes a new value and tools_enabled reflects it" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    tools_conf_ensure
    tools_set PYTHON on
    tools_enabled PYTHON && echo yes || echo no
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"yes"* ]]
}

@test "tools_check_deps auto-selects Python when uv is turned on" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    tools_conf_ensure
    tools_check_deps UV on
    tools_enabled PYTHON && echo python_on || echo python_off
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Python has been auto-selected because uv requires it."* ]]
  [[ "$output" == *"python_on"* ]]
}

@test "tools_check_deps blocks deselecting Python while uv is on" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    tools_conf_ensure
    tools_set PYTHON on
    tools_set UV on
    tools_check_deps PYTHON off
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"Deselect uv first"* ]]
}

@test "tools_export_build_args exports one TOOL_<NAME> var per installable slug, excluding DOCKER_SOCKET and XCODE" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    tools_conf_ensure
    tools_set GO on
    tools_export_build_args
    echo \"TOOL_GO=\$TOOL_GO\"
    echo \"TOOL_PYTHON=\$TOOL_PYTHON\"
    echo \"XCODE_SET=\${TOOL_XCODE:-unset}\"
    echo \"SOCKET_SET=\${TOOL_DOCKER_SOCKET:-unset}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOOL_GO=1"* ]]
  [[ "$output" == *"TOOL_PYTHON=0"* ]]
  [[ "$output" == *"XCODE_SET=unset"* ]]
  [[ "$output" == *"SOCKET_SET=unset"* ]]
}

@test "tools_generate_docker_socket_override writes the override only when the toggle is on" {
  run bash -c "
    source '$SCRIPT_ROOT/scripts/lib-tools.sh'
    tools_conf_ensure
    tools_generate_docker_socket_override
    [ -f \"\$TOOLS_DOCKER_SOCKET_OVERRIDE\" ] && echo present_when_off || echo absent_when_off
    tools_set DOCKER_SOCKET on
    tools_generate_docker_socket_override
    [ -f \"\$TOOLS_DOCKER_SOCKET_OVERRIDE\" ] && echo present_when_on || echo absent_when_on
    grep -q '/var/run/docker.sock:/var/run/docker.sock' \"\$TOOLS_DOCKER_SOCKET_OVERRIDE\" && echo bind_mount_ok
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"absent_when_off"* ]]
  [[ "$output" == *"present_when_on"* ]]
  [[ "$output" == *"bind_mount_ok"* ]]
}

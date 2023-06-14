minion_start_apply_state:
  local.state.sls:
    - tgt: "{{ data['id'] }} and G@os:Windows"
    - arg:
      - Windows.create-Win-txt-file

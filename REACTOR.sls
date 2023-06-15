# salt://srv/salt/REACTOR.sls
minion_start_apply_state:
  local.state.sls:
    - tgt: {{ data['id'] }}
    - arg:
      - Windows.create-Win-txt-file

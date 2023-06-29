# salt://reactor/fire_minion_startup.sls
fire_minion_startup:
  runner.state.orch:
    - args:
      - mods: reactor.run_once_orch
      - pillar:
          event_tag: {{ tag }}
          event_data: {{ data | json }}

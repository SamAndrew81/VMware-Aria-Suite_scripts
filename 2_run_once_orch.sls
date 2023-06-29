# salt://reactor/run_once_orch.sls
{% set event_data = salt["pillar.get"]("event_data") %}
{% set event_tag = salt["pillar.get"]("event_tag") %}
{% do salt["log.debug"]("logging tag from reactor: " ~ event_tag)%}
{% set minion_id = event_data["id"] %}
{% set minion_grains = salt['saltutil.runner']("cache.grains", arg=[minion_id])[minion_id] %}
{% if not minion_grains.get("run_once_grain", False) %}
run_first_run_stuff:
  salt.state:
    - tgt: {{minion_id}}
    - sls: 
      - Windows.create-Win-txt-file
      
create_run_once:
  salt.function:
    - tgt: {{minion_id}}
    - name: grains.setval
    - kwarg:
        key: run_once_grain
        val: True
{%endif%}

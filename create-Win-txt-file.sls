create_temp_file:
  file.managed:
    - name: C:\Temp\join-state-success.txt
    - contents: "Initial state successfully ran"
    - makedirs: True

# Architecture Diagram Source

```text
                Internet / Grader
                       |
                  TLS 443/80
                       |
                    Nginx
                       |
        +--------------+--------------+
        |              |              |
   StrongBox 1    StrongBox 2    StrongBox 3
   node1:8200     node2:8200     node3:8200
        |              |              |
        +------ consensus HTTP -------+
        |              |              |
  local secrets   local secrets   local secrets
  audit log       audit log       audit log
        |
        +--------- PostgreSQL
                  dynamic roles
```

The PNG at `docs/architecture.png` is generated from this structure for the
submission README.

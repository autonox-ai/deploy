# Mock HR import scenario

This scenario runs one mocked HR source, represented by PostgreSQL tables,
through the real Collector, Warehouse, and Reconciliation containers via
`import.sh`.

## Run it

```bash
./testkit/init.sh mock-hr
./testkit/run.sh e2e mock-hr
```

`e2e` resets PostgreSQL, provisions the workspace, sets the test-role
passwords, seeds `source/mock_hr.sql`, migrates, imports, and asserts
`expect.sql`. Nothing else needs to be exported.

## What the scenario supplies

| Path | Purpose |
| --- | --- |
| `scenario.env` | Identity and run shape — workspace, system instance, target ref, completion policy. Read by both `init.sh` and `run.sh`. |
| `config/` | The documents `import.sh` consumes: collector, connections, flow, banding, reconcile, and the two warehouse wiring files. |
| `source/mock_hr.sql` | The mocked HR tables, loaded into the test database. |
| `expect.sql` | Outcome assertions, run against `autonox` after the import. |

The harness supplies everything else: image resolution from
`images/manifest.txt`, container mounts and run args, artifact and receipt
directories, and the PostgreSQL DSNs.

## Notes

The source lives inside PostgreSQL, so the collector reaches it over the
`autonox-local` network and no source volume mount is required.

`WORKSPACE_ID` in `scenario.env` must match `spec.workspace_id` in
`config/warehouse-wiring.yaml`; `init.sh` fails the run if they drift.

# Seed SQL

`wordpress-seed.sql` is a `wp db export` of the lab install, produced by
`export_sql.sh`. It is not hand-written: WordPress serialises option values,
and a hand-rolled schema drifts in ways that look like exploit bugs.

| | |
|---|---|
| site url | http://127.0.0.1:18120 |
| size | 107311 bytes |
| tables | 12 |

## How it is used

`lab_wordpress.sh` does **not** mount this by default - the entrypoint runs
`wp core install` on first boot, which is idempotent and always matches the
image's WordPress version.

To start from the seed instead (faster, pinned content), mount it into
mariadb's init hook on a fresh volume:

```bash
docker run -d --name p2s-wp-db --network p2s-wp-net \
  -e MARIADB_DATABASE=wordpress -e MARIADB_USER=wpuser \
  -e MARIADB_PASSWORD=wppass123 -e MARIADB_ROOT_PASSWORD=rootpass123 \
  -v p2s-wp-db-vol:/var/lib/mysql \
  -v "$PWD/sql:/docker-entrypoint-initdb.d:ro" \
  mariadb:11
```

mariadb only runs `/docker-entrypoint-initdb.d/*.sql` when the data directory
is empty, so this applies to a fresh volume only.

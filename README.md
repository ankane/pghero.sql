# PgHero.sql

Postgres insights made easy

![Screenshot](https://pghero.herokuapp.com/assets/console-75e99c4a6e049943da6eba66b3d758e7.png)

Supports PostgreSQL 9.2+

For Ruby, check out the [pghero gem](https://github.com/ankane/pghero)

Initial queries by [Heroku](https://blog.heroku.com/archives/2013/5/10/more_insight_into_your_database_with_pgextras) :clap:

## Features

#### Queries

View all running queries with:

```sql
SELECT * FROM pghero_running_queries;
```

Queries running for longer than five minutes

```sql
SELECT * FROM pghero_long_running_queries;
```

Queries can be killed by `pid` with:

```sql
SELECT pghero_kill(123);
```

Kill all running queries with:

```sql
SELECT pghero_kill_all();
```

#### Index Usage

All usage

```sql
SELECT * FROM pghero_index_usage;
```

Missing indexes

```sql
SELECT * FROM pghero_missing_indexes;
```

Unused Indexes

```sql
SELECT * FROM pghero_unused_indexes;
```

#### Space

Largest tables and indexes

```sql
SELECT * FROM pghero_relation_sizes;
```

#### Cache Hit Ratio

```sql
SELECT pghero_index_hit_rate();
```

and

```sql
SELECT pghero_table_hit_rate();
```

Both should be above 99%.

## Install

Run this command from your shell:

```sh
curl https://raw.githubusercontent.com/ankane/pghero.sql/master/install.sql | psql db_name
```

or [copy its contents](https://raw.githubusercontent.com/ankane/pghero.sql/master/install.sql) into a SQL console.

## Uninstall

```sh
curl https://raw.githubusercontent.com/ankane/pghero.sql/master/uninstall.sql | psql db_name
```

## Contributing

Everyone is encouraged to help improve this project. Here are a few ways you can help:

- [Report bugs](https://github.com/ankane/pghero.sql/issues)
- Fix bugs and [submit pull requests](https://github.com/ankane/pghero.sql/pulls)
- Write, clarify, or fix documentation
- Suggest or add new features

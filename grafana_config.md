# Grafana Dashboard Config & Queries Reference

This file documents the **complete** Grafana dashboard configuration for **TransitPulse** — including datasource settings, all template variables, panel SQL queries, recommended refresh cadences, and the cron schedule that drives the data pipeline behind each chart.

---

## Dashboard Metadata

| Field         | Value                                                                 |
|---------------|-----------------------------------------------------------------------|
| Title         | `VTA Network Pulse & Observability`                                   |
| UID           | `adzp884`                                                             |
| Datasource    | PostgreSQL (`grafana-postgresql-datasource` / UID: `dfnhqkmye6gowd`) |
| DB Host       | `aws-1-us-west-2.pooler.supabase.com:6543`                           |
| Timezone      | `America/Los_Angeles` (Pacific — matches VTA service timezone)        |

---

## Pipeline ↔ Dashboard Refresh Cadence

Understanding *when* data moves through the system tells you how to set dashboard auto-refresh and time-range defaults.

```
511.org GTFS-RT API
        │
        │  every 2 min  (cron: */2 * * * *)
        ▼
raw_gtfs_realtime_pings  ← rolling 48-hour window
        │
        │  every hour at :05  (cron: 5 * * * *)
        ▼
dbt run  →  stg_vta_realtime (view)
         →  int_vta_arrival_performance (view)
         →  int_vta_congestion_analysis (view)
         →  fct_transit_otp_hourly (table, REBUILT each hour)
         →  dim_corridor_performance (table, REBUILT each hour)
         →  fct_pipeline_health (table, REBUILT each hour)
        │
        │  Grafana reads marts directly
        ▼
Grafana Dashboard  ←  auto-refresh: 2 min

Static GTFS:  511.org → raw_gtfs_static_* tables
              Refresh: every Sunday 03:00 AM (cron: 0 3 * * 0)
              dbt re-run follows at 03:30 AM (cron: 30 3 * * 0)
```

**Recommended Grafana dashboard settings:**
- **Auto-refresh:** `2m` (matches realtime ingestion heartbeat)
- **Default time range:** `Last 6 hours` (captures a full AM or PM peak window)
- **Max data points:** `500` (prevents over-querying the timeseries panel)

---

## Template Variables

Template variables let analysts slice every panel simultaneously. Configure all of these under **Dashboard Settings → Variables**.

---

### Variable 1: `route`

| Setting         | Value                                  |
|-----------------|----------------------------------------|
| Name            | `route`                                |
| Label           | `Select Route`                         |
| Type            | Query                                  |
| Multi-value     | ✅ Yes                                 |
| Include All     | ✅ Yes (value: `.*` for regex OR mode) |
| Refresh         | On Dashboard Load                      |
| Sort            | Alphabetical (asc)                     |

```sql
SELECT
  DISTINCT route_short_name AS __text,
  route_id                  AS __value
FROM stg_vta_routes
ORDER BY route_short_name ASC
```

> **Why:** Every operational panel (OTP, stop performance) filters by route.
> Multi-select + All lets dispatchers compare a single route or the whole system in one click.

---

### Variable 2: `direction`

| Setting         | Value                                  |
|-----------------|----------------------------------------|
| Name            | `direction`                            |
| Label           | `Direction`                            |
| Type            | Custom                                 |
| Values          | `0 : Outbound, 1 : Inbound`            |
| Multi-value     | ✅ Yes                                 |
| Include All     | ✅ Yes                                 |

> **Why:** GTFS `direction_id` (0 = outbound, 1 = inbound) is captured in `int_vta_congestion_analysis`. Filtering by direction reveals asymmetric congestion — e.g., inbound slow during AM peak.

---

### Variable 3: `service_date`

| Setting         | Value                                  |
|-----------------|----------------------------------------|
| Name            | `service_date`                         |
| Label           | `Service Date`                         |
| Type            | Query                                  |
| Multi-value     | ❌ No (single date for OTP comparison) |
| Include All     | ❌ No                                  |
| Refresh         | Every 1 hour                           |
| Default         | `$__timeFrom()` (resolves to today)    |

```sql
SELECT DISTINCT
  service_date::text AS __text,
  service_date::text AS __value
FROM int_vta_arrival_performance
ORDER BY service_date DESC
LIMIT 14
```

> **Why:** Enables day-over-day OTP comparisons. Limiting to 14 days keeps the dropdown lean while covering a full rolling fortnight.

---

### Variable 4: `otp_threshold`

| Setting         | Value                               |
|-----------------|-------------------------------------|
| Name            | `otp_threshold`                     |
| Label           | `OTP Alert Threshold (%)`           |
| Type            | Custom                              |
| Values          | `70, 75, 80, 85, 90`                |
| Default         | `80`                                |
| Multi-value     | ❌ No                               |

> **Why:** Lets managers adjust the "red line" for OTP alerting without touching SQL. Reference as `${otp_threshold}` in threshold overrides on the OTP timeseries panel.

---

### Variable 5: `speed_unit`

| Setting         | Value                               |
|-----------------|-------------------------------------|
| Name            | `speed_unit`                        |
| Label           | `Speed Unit`                        |
| Type            | Custom                              |
| Values          | `mph : MPH, mps : m/s`              |
| Default         | `mph`                               |
| Multi-value     | ❌ No                               |

> **Why:** Drives a conditional expression in the corridor speed panel — analysts can toggle between MPH (operational) and m/s (raw GTFS unit).

---

## Panel Configuration & SQL Queries

### Panel 1 — **Pipeline Snapshot** *(Stat panel)*

- **Description:** Last realtime ingestion timestamp. Turns red if data is stale > 5 minutes.
- **Recommended refresh:** Every 2 min (matches cron)
- **Thresholds:** Green < 300 s, Yellow 300–600 s, Red > 600 s (use `data_freshness_seconds`)

```sql
SELECT
  MAX(ping_timestamp)                                      AS "Last Ingested At",
  ROUND(EXTRACT(epoch FROM (NOW() - MAX(ping_timestamp)))) AS "Data Age (seconds)",
  COUNT(DISTINCT vehicle_id)                               AS "Active Vehicles"
FROM public.stg_vta_realtime
```

> **Enhanced from original:** Added `Data Age (seconds)` for threshold colouring and active vehicle count so dispatchers can see fleet visibility at a glance.

---

### Panel 2 — **Current Transit Window Performance** *(Stat panel)*

- **Description:** Headline KPIs — System OTP % and anomalous delay count for the selected time window and routes.
- **Variables used:** `$route`, `$__timeFrom()`, `$__timeTo()`

```sql
SELECT
  ROUND(AVG(otp_percentage)::numeric, 1)  AS "System OTP %",
  SUM(anomalous_delay_count)              AS "Anomalous Delays Flagged",
  SUM(total_arrivals)                     AS "Total Arrivals Tracked",
  ROUND(AVG(avg_delay_minutes)::numeric, 2) AS "Avg Delay (Min)"
FROM fct_transit_otp_hourly
WHERE performance_hour >= $__timeFrom()
  AND performance_hour <= $__timeTo()
  AND route_id IN (${route:singlequote})
```

> **Note:** Use `${route:singlequote}` — NOT `:csv` — because `route_id` is `character varying` in all dbt models. The `:singlequote` formatter wraps each value in single quotes (`'1','2','3'`), giving PostgreSQL a proper string comparison. Using `:csv` emits bare integers and causes `operator does not exist: character varying = integer`.

---

### Panel 3 — **Stop-Level Performance & IQR Delay Hotspots** *(Table panel)*

- **Description:** Ranked stop list by average delay. IQR baseline column exposes stops that are consistently chaotic vs. one-off incidents.
- **Variables used:** `$route`, `$service_date`

```sql
SELECT
  h.route_id                                      AS "Route",
  h.stop_id                                       AS "Stop ID",
  COUNT(*)                                        AS "Total Arrivals",
  ROUND(AVG(h.delay_minutes)::numeric, 1)         AS "Avg Delay (Min)",
  ROUND(MAX(h.delay_minutes)::numeric, 1)         AS "Max Peak Delay",
  ROUND(AVG(h.actual_headway_minutes)::numeric, 1) AS "Avg Headway (Min)",
  ROUND(AVG(h.stop_delay_iqr)::numeric, 1)        AS "Stop Baseline IQR",
  -- Classify stop health
  CASE
    WHEN AVG(h.delay_minutes) > 5              THEN '🔴 Critical'
    WHEN AVG(h.delay_minutes) BETWEEN 2 AND 5  THEN '🟡 At Risk'
    ELSE                                            '🟢 On Time'
  END AS "Status"
FROM int_vta_arrival_performance h
WHERE h.route_id IN (${route:singlequote})
  AND h.service_date = '${service_date}'
GROUP BY h.route_id, h.stop_id
ORDER BY "Avg Delay (Min)" DESC
LIMIT 100
```

---

### Panel 4 — **Corridor Speed & Bottleneck Leaderboard** *(Table panel)*

- **Description:** Route corridor ranking by bottleneck incidents and average speed.
- **Variables used:** `$route`, `$speed_unit`, `$direction`

```sql
SELECT
  c.route_short_name                                       AS "Route",
  c.route_long_name                                        AS "Corridor",
  c.shape_id                                               AS "Shape ID",
  c.total_tracked_pings                                    AS "Pings",
  c.bottleneck_incidents                                   AS "Bottlenecks",
  -- Honour the speed_unit variable
  CASE '${speed_unit}'
    WHEN 'mph' THEN ROUND((c.average_speed_mps * 2.23694)::numeric, 1)
    ELSE            ROUND(c.average_speed_mps::numeric, 2)
  END                                                      AS "Avg Speed",
  ROUND(
    (c.bottleneck_incidents::numeric / NULLIF(c.total_tracked_pings, 0)) * 100,
    1
  )                                                        AS "Bottleneck Rate %"
FROM dim_corridor_performance c
WHERE c.route_id IN (${route:singlequote})
ORDER BY c.bottleneck_incidents DESC
LIMIT 50
```

---

### Panel 5 — **Hourly OTP vs. Extreme Delay Spikes** *(Time series panel)*

- **Description:** Dual-axis timeseries. Left axis = OTP %, Right axis = anomalous delay count. Threshold line drawn at `${otp_threshold}`.
- **Variables used:** `$route`, `$otp_threshold`

```sql
SELECT
  performance_hour                AS time,
  otp_percentage                  AS "OTP %",
  anomalous_delay_count           AS "Anomalous Delays"
FROM fct_transit_otp_hourly
WHERE performance_hour >= $__timeFrom()
  AND performance_hour <= $__timeTo()
  AND route_id IN (${route:singlequote})
ORDER BY performance_hour ASC
```

**Panel override to add threshold line:**
- Field override → `OTP %` → Threshold → Value: `${otp_threshold}`, Color: Red

---

### Panel 6 (NEW) — **Pipeline Health Monitor** *(Time series panel)*

- **Description:** Tracks ingestion volume per minute and active vehicle count. Detects pipeline gaps — flat lines mean the cron job failed.
- **Recommended position:** Top row, next to Panel 1 Snapshot.

```sql
SELECT
  ingestion_minute                AS time,
  records_ingested                AS "Records / Min",
  active_reporting_vehicles       AS "Active Vehicles",
  ROUND(data_freshness_seconds)   AS "Data Freshness (s)"
FROM fct_pipeline_health
WHERE ingestion_minute >= $__timeFrom()
  AND ingestion_minute <= $__timeTo()
ORDER BY ingestion_minute ASC
```

---

### Panel 7 (NEW) — **Route OTP Heatmap — Hour × Day** *(Heatmap panel)*

- **Description:** Shows which hour of day is worst for OTP, broken down by service date. Reveals AM/PM peak patterns.
- **Variables used:** `$route`

```sql
SELECT
  EXTRACT(hour FROM performance_hour)::int  AS "Hour of Day",
  service_date::text                        AS "metric",
  ROUND(AVG(otp_percentage)::numeric, 1)    AS "value"
FROM fct_transit_otp_hourly f
WHERE route_id IN (${route:singlequote})
  AND performance_hour >= NOW() - INTERVAL '14 days'
GROUP BY 1, 2
ORDER BY 1, 2
```

> **Panel type:** Grafana Heatmap. Set X = `Hour of Day`, Y = `service_date`, Cell value = `OTP %`.

---

### Panel 8 (NEW) — **Vehicle Fleet Live Count** *(Gauge panel)*

- **Description:** How many vehicles are actively reporting right now vs. last hour.
- **Refresh:** Every 2 min

```sql
SELECT
  COUNT(DISTINCT vehicle_id) FILTER (
    WHERE ping_timestamp >= NOW() - INTERVAL '5 minutes'
  ) AS "Vehicles (Last 5 min)",
  COUNT(DISTINCT vehicle_id) FILTER (
    WHERE ping_timestamp >= NOW() - INTERVAL '1 hour'
  ) AS "Vehicles (Last Hour)"
FROM stg_vta_realtime
```

---

## Cron Schedule Summary

| Job                     | Cron Expression    | Script Command                          | Latency Impact              |
|-------------------------|--------------------|-----------------------------------------|-----------------------------|
| Realtime GTFS ingest    | `*/2 * * * *`      | `./pipeline_scheduler.sh realtime`      | Raw table updated every 2 min |
| dbt hourly run          | `5 * * * *`        | `./pipeline_scheduler.sh dbt`           | Mart tables rebuilt at :05  |
| Static GTFS refresh     | `0 3 * * 0`        | `./pipeline_scheduler.sh static`        | Weekly Sunday 3 AM          |
| Full pipeline (weekly)  | `30 3 * * 0`       | `./pipeline_scheduler.sh full`          | Runs after static completes |

**Install cron jobs (copy-paste into terminal):**

```bash
# Open crontab editor
crontab -e

# Paste these lines:
*/2 * * * * /Users/skush/CodeX/transitpulse/pipeline_scheduler.sh realtime >> /Users/skush/CodeX/transitpulse/logs/cron.log 2>&1
5 * * * * /Users/skush/CodeX/transitpulse/pipeline_scheduler.sh dbt >> /Users/skush/CodeX/transitpulse/logs/cron.log 2>&1
0 3 * * 0 /Users/skush/CodeX/transitpulse/pipeline_scheduler.sh static >> /Users/skush/CodeBox/transitpulse/logs/cron.log 2>&1
30 3 * * 0 /Users/skush/CodeX/transitpulse/pipeline_scheduler.sh full >> /Users/skush/CodeX/transitpulse/logs/cron.log 2>&1
```

> ⚠️ **macOS cron note:** Grant Full Disk Access to `/usr/sbin/cron` in **System Settings → Privacy & Security → Full Disk Access** so cron can read `.env` files.

---

## Grafana Alerting Rules (Recommended)

Configure these under **Alerting → Alert Rules** in the Grafana UI.

| Alert Name                | Condition                                              | Severity | Notify          |
|---------------------------|--------------------------------------------------------|----------|-----------------|
| Pipeline Stale            | `Data Age (seconds)` > 600 for 5 min                  | Critical | Email / Slack   |
| System OTP Critical       | `System OTP %` < `${otp_threshold}` for 30 min        | High     | Email           |
| Bottleneck Surge          | `Bottleneck Rate %` > 10% on any route for 15 min     | Medium   | Slack           |
| Low Fleet Visibility      | `Vehicles (Last 5 min)` < 10                          | High     | Email / PagerDuty |
| dbt Run Gap Detected      | No new rows in `fct_transit_otp_hourly` for > 90 min  | Critical | Email           |

---

## Best Analytical Workflow

1. **Start with Panel 1 (Snapshot)** — confirm data is fresh (green).  
2. **Set `$route` = All, time range = Last 6h** → Panel 2 gives system-wide OTP pulse.  
3. **Narrow `$route` to a specific route** → Panel 5 timeseries shows exactly which hours degraded.  
4. **Drop to Panel 3 (Stop Hotspots)** with that route → identify the worst stop.  
5. **Cross-reference Panel 4 (Corridors)** → check if the same route has high bottleneck rate (speed issue vs. schedule issue).  
6. **Panel 7 Heatmap** → zoom out to see if today's pattern matches the weekly pattern (recurring vs. incident).  
7. **Panel 6 (Pipeline Health)** → if everything looks clean in data but anomalies are spiking, check whether an ingestion gap caused stale OTP scores.

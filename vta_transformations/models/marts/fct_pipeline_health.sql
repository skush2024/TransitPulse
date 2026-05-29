{{ config(materialized='table') }}

with realtime as (
    select * from {{ ref('stg_vta_realtime') }}
)

select
    date_trunc('minute', ping_timestamp) as ingestion_minute,
    count(*) as records_ingested,
    count(distinct vehicle_id) as active_reporting_vehicles,
    extract(epoch from (now() - max(ping_timestamp))) as data_freshness_seconds
from realtime
group by 1
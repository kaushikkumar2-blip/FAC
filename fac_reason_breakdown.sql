-- Hive SQL against bigfoot_external_neo.* tables
-- QaaS: teamId=core-logistics-t | queue=sun (or fulfillment_adhoc)
-- In QaaS UI pick the engine that runs Hive tables (labeled SPARK in QaaS; there is no separate HIVE option)
-- Do NOT use BigQuery for this query
-- Paste from WITH geo AS ( ... ) — skip these comment lines

WITH geo AS (
    SELECT
        logistics_geo_hive_dim_key,
        state
    FROM bigfoot_external_neo.scp_ekl__logistics_geo_hive_dim
),

vti_geo AS (
    SELECT DISTINCT
        ext.vendor_tracking_id,
        geo.state AS destination_state,
        ext.first_undel_unpick_status,
        ext.first_undelivery_status
    FROM bigfoot_external_neo.scp_fsgde_ns__externalisation_l1_scala_fact ext
    LEFT JOIN geo
        ON ext.destination_pincode_key = geo.logistics_geo_hive_dim_key
),

base AS (
    SELECT
        task.tasklist_created_date_key AS reporting_date,
        task.seller_type,
        vti_geo.destination_state,
        task.attempt_no,
        concat(task.vendor_tracking_id, cast(task.tasklist_id as string)) AS attempt_key,
        task.shipment_actioned_flag,
        CASE
            WHEN coalesce(task.shipment_actioned_flag, 0) = 1 THEN NULL
            ELSE coalesce(
                nullif(trim(task.undel_unpick_status), ''),
                nullif(trim(vti_geo.first_undel_unpick_status), ''),
                nullif(trim(vti_geo.first_undelivery_status), '')
            )
        END AS reason
    FROM bigfoot_external_neo.scp_fsgde_ns__lastmile_tasklist_base_fact task
    LEFT JOIN vti_geo
        ON task.vendor_tracking_id = vti_geo.vendor_tracking_id
    WHERE task.seller_type NOT IN (
            'Non-FA', 'FA', 'WSR', 'MYN', 'MYS', 'FKW', 'FKH', 'MYE',
            'MP_FBF_SELLER', 'MP_NON_FBF_SELLER', 'SF2', 'SF3', 'SF4', 'SF6', 'SF7', 'FMP', 'FKMP'
        )
        AND lower(task.facility_type) NOT IN ('large')
        AND lower(task.tasklist_type) = 'runsheet'
        AND lower(task.attempt_type) = 'customer'
        AND task.vendor_tracking_id NOT LIKE 'FMP%'
        AND task.tasklist_created_date_key BETWEEN 20220101 AND 20260915
),

first_attempts AS (
    SELECT
        reporting_date,
        seller_type,
        destination_state,
        attempt_key,
        shipment_actioned_flag,
        CASE
            WHEN coalesce(shipment_actioned_flag, 0) = 1 THEN NULL
            WHEN reason IS NULL OR trim(reason) = '' THEN 'no_status_captured'
            WHEN lower(reason) LIKE '%order%reject%' THEN 'orc'
            WHEN lower(reason) LIKE '%customer%not%available%'
                 OR lower(reason) LIKE '%heavy%rain%'
                 OR lower(reason) LIKE '%security%instability%' THEN 'not_available'
            WHEN lower(reason) LIKE '%cod%not%ready%' THEN 'cod_not_ready'
            WHEN lower(reason) LIKE '%incomplete%address%' THEN 'ica'
            WHEN lower(reason) LIKE '%other%state%misroute%' THEN 'osm'
            WHEN lower(reason) LIKE '%untraceable%hub%' THEN 'untraceable'
            WHEN lower(reason) LIKE '%shipment%damage%' THEN 'damage'
            WHEN lower(reason) LIKE '%nonserviceable%pincode%'
                 OR lower(reason) LIKE '%non%serviceable%pincode%' THEN 'nss'
            WHEN lower(reason) LIKE '%same%state%misroute%' THEN 'ssm'
            WHEN lower(reason) LIKE '%heavy%load%' THEN 'heavy_load'
            WHEN lower(reason) LIKE '%request%reschedule%' THEN 'rfr'
            WHEN lower(reason) LIKE '%no%response%' THEN 'cnr'
            ELSE 'other_reasons'
        END AS reason_bucket
    FROM base
    WHERE attempt_no = 1
),

all_attempts AS (
    SELECT
        reporting_date,
        seller_type,
        destination_state,
        count(DISTINCT attempt_key) AS total_attempts,
        count(DISTINCT CASE WHEN coalesce(shipment_actioned_flag, 0) = 1 THEN attempt_key END) AS total_delivered_attempts
    FROM base
    GROUP BY reporting_date, seller_type, destination_state
),

reason_agg AS (
    SELECT
        reporting_date,
        seller_type,
        destination_state,
        count(DISTINCT CASE WHEN coalesce(shipment_actioned_flag, 0) = 1 THEN attempt_key END) AS first_attempt_delivered,
        count(DISTINCT attempt_key) AS fac_deno,
        count(DISTINCT CASE WHEN reason_bucket = 'orc' THEN attempt_key END) AS orc,
        count(DISTINCT CASE WHEN reason_bucket = 'not_available' THEN attempt_key END) AS not_available,
        count(DISTINCT CASE WHEN reason_bucket = 'cod_not_ready' THEN attempt_key END) AS cod_not_ready,
        count(DISTINCT CASE WHEN reason_bucket = 'ica' THEN attempt_key END) AS ica,
        count(DISTINCT CASE WHEN reason_bucket = 'osm' THEN attempt_key END) AS osm,
        count(DISTINCT CASE WHEN reason_bucket = 'untraceable' THEN attempt_key END) AS untraceable,
        count(DISTINCT CASE WHEN reason_bucket = 'damage' THEN attempt_key END) AS damage,
        count(DISTINCT CASE WHEN reason_bucket = 'nss' THEN attempt_key END) AS nss,
        count(DISTINCT CASE WHEN reason_bucket = 'ssm' THEN attempt_key END) AS ssm,
        count(DISTINCT CASE WHEN reason_bucket = 'heavy_load' THEN attempt_key END) AS heavy_load,
        count(DISTINCT CASE WHEN reason_bucket = 'cnr' THEN attempt_key END) AS cnr,
        count(DISTINCT CASE WHEN reason_bucket = 'rfr' THEN attempt_key END) AS rfr,
        count(DISTINCT CASE WHEN reason_bucket = 'other_reasons' THEN attempt_key END) AS other_reasons,
        count(DISTINCT CASE WHEN reason_bucket = 'no_status_captured' THEN attempt_key END) AS no_status_captured
    FROM first_attempts
    GROUP BY reporting_date, seller_type, destination_state
)

SELECT
    r.reporting_date,
    r.seller_type,
    r.destination_state,
    r.first_attempt_delivered,
    r.fac_deno,
    coalesce(a.total_delivered_attempts, 0) AS total_delivered_attempts,
    coalesce(a.total_attempts, 0) AS total_attempts,
    r.orc,
    r.not_available,
    r.cod_not_ready,
    r.ica,
    r.osm,
    r.untraceable,
    r.damage,
    r.nss,
    r.ssm,
    r.heavy_load,
    r.cnr,
    r.rfr,
    r.other_reasons,
    0 AS no_first_attempt_record,
    r.no_status_captured
FROM reason_agg r
LEFT JOIN all_attempts a
    ON r.reporting_date = a.reporting_date
    AND r.seller_type = a.seller_type
    AND r.destination_state = a.destination_state
ORDER BY r.reporting_date, r.seller_type, r.destination_state

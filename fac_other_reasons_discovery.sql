WITH vti_geo AS (
    SELECT DISTINCT
        ext.vendor_tracking_id,
        ext.first_undel_unpick_status,
        ext.first_undelivery_status
    FROM bigfoot_external_neo.scp_fsgde_ns__externalisation_l1_scala_fact ext
),
base AS (
    SELECT
        concat(task.vendor_tracking_id, cast(task.tasklist_id as string)) AS attempt_key,
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
        AND task.attempt_no = 1
        AND coalesce(task.shipment_actioned_flag, 0) != 1
        AND task.vendor_tracking_id NOT LIKE 'FMP%'
        AND task.tasklist_created_date_key BETWEEN 20260901 AND 20260915
),
tagged AS (
    SELECT
        attempt_key,
        reason,
        CASE
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
)
SELECT
    coalesce(reason, '(null)') AS raw_reason,
    count(distinct attempt_key) AS failed_first_attempts
FROM tagged
WHERE reason_bucket = 'other_reasons'
GROUP BY coalesce(reason, '(null)')
ORDER BY count(distinct attempt_key) DESC

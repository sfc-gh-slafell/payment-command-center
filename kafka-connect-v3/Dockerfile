# Kafka Connect worker with Snowflake V3 (Snowpipe Streaming Classic) connector
# Used for Issue #59 benchmark: V3 Classic vs V4 HP side-by-side throughput comparison
#
# V3 uses SnowflakeSinkConnector with snowflake.ingestion.method=SNOWPIPE_STREAMING
# Available on Confluent Hub (unlike V4 RC which requires Maven Central)
FROM confluentinc/cp-kafka-connect:7.6.0

RUN confluent-hub install --no-prompt snowflakeinc/snowflake-kafka-connector:3.5.3

# Kafka Connect worker with Snowflake HP (Snowpipe Streaming) connector
# Spec reference: Section 3.3 (HP connector — primary ingest path)
FROM confluentinc/cp-kafka-connect:7.6.0

# Install the Snowflake Kafka Connector (Snowpipe Streaming / HP mode)
# Requires v2.0.0+ for SnowflakeStreamingSinkConnector class
RUN confluent-hub install --no-prompt snowflakeinc/snowflake-kafka-connector:latest

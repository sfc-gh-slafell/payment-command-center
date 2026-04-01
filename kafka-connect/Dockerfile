# Kafka Connect worker with Snowflake HP (Snowpipe Streaming) connector
# Spec reference: Section 3.3 (HP connector — primary ingest path)
FROM confluentinc/cp-kafka-connect:7.6.0

# Install Snowflake Kafka Connector v4.0.0-rc9 from Maven Central
# v4.x provides SnowflakeStreamingSinkConnector class
# RC versions not available on Confluent Hub, so download directly from Maven Central
# Requires Bouncy Castle FIPS cryptography libraries (not regular BC)
RUN mkdir -p /usr/share/confluent-hub-components/snowflakeinc-snowflake-kafka-connector && \
    cd /usr/share/confluent-hub-components/snowflakeinc-snowflake-kafka-connector && \
    curl -sLO https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/4.0.0-rc9/snowflake-kafka-connector-4.0.0-rc9.jar && \
    curl -sLO https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.2.5/bc-fips-1.0.2.5.jar && \
    curl -sLO https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.7/bcpkix-fips-1.0.7.jar

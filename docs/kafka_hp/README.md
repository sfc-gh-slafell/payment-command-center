# Snowflake HP Kafka Connector Documentation

This directory contains documentation for the Snowflake High Performance (HP) Kafka Connector v4.x with Snowpipe Streaming.

## Getting Started

**→ [GETTING_STARTED.md](GETTING_STARTED.md)** - Complete guide from setup to production

The getting started guide walks you through:

- Setting up Snowflake (database, table, pipe, grants)
- Installing Kafka Connect with HP connector v4.x
- Configuring the connector with metadata extraction
- End-to-end verification and troubleshooting
- Performance tuning and production hardening

**Time to complete:** 45-60 minutes for full setup

## Quick Links

- **Section 2: Common Mistakes** - Read this first to avoid the top 5 failure modes
- **Section 8: End-to-End Verification** - Prove data is flowing correctly
- **Section 9: Troubleshooting** - Symptom-based diagnostic guide

## Prerequisites

Before starting, ensure you have:

- Kafka cluster (1+ brokers)
- Snowflake account with ACCOUNTADMIN access
- Docker and docker-compose installed
- Basic familiarity with Kafka Connect and Snowflake

## Additional Resources

- **Project Skills:**
  - `/.claude/skills/kafka-connect-snowflake/` - Connector reference patterns
  - `/.claude/skills/kafka-producer-python/` - Producer implementation patterns
- **Troubleshooting:**
  - `/docs/DEPLOY_TROUBLESHOOTING.md` - Complete deployment log with Issues 19-25

## Support

For issues with this connector setup:

1. Check Section 9 (Troubleshooting) in the getting started guide
2. Review relevant skill documentation
3. Consult the deployment troubleshooting log for similar issues


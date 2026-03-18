spring:
  application:
    name: hugegraph-pd

management:
  metrics:
    export:
      prometheus:
        enabled: true
  endpoints:
    web:
      exposure:
        include: "*"

logging:
  config: file:./conf/log4j2.xml

license:
  verify-path: ./conf/verify-license.json
  license-path: ./conf/hugegraph.license

grpc:
  port: 8686
  host: 0.0.0.0

server:
  port: 8620

pd:
  data-path: /data/pd_data
  patrol-interval: 1800
  initial-store-count: 3
  initial-store-list: __STORE_LIST__

raft:
  address: __SELF_DNS__:8610
  peers-list: __RAFT_PEERS__

store:
  max-down-time: 172800
  monitor_data_enabled: true
  monitor_data_interval: 1 minute
  monitor_data_retention: 1 day
  initial-store-count: 1

partition:
  default-shard-count: 1
  store-max-shard-count: 12

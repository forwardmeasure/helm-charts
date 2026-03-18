pdserver:
  address: __PD_ADDRS__

management:
  metrics:
    export:
      prometheus:
        enabled: true
  endpoints:
    web:
      exposure:
        include: "*"

grpc:
  host: __SELF_DNS__
  port: 8500
  netty-server:
    max-inbound-message-size: 1000MB

raft:
  disruptorBufferSize: 1024
  address: __RAFT_ADDRESS__
  max-log-file-size: 600000000000
  snapshotInterval: 1800

server:
  port: 8520

app:
  data-path: /data/storage

spring:
  application:
    name: store-node-grpc-server
  profiles:
    active: default
    include: pd

logging:
  config: file:./conf/log4j2.xml
  level:
    root: info

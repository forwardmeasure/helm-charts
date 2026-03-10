host: 0.0.0.0
port: __GREMLIN_PORT__
graphs:
  hugegraph: conf/graphs/hugegraph.properties
scriptEngines:
  gremlin-groovy:
    plugins:
      org.apache.tinkerpop.gremlin.server.jsr223.GremlinServerGremlinPlugin: {}
      org.apache.hugegraph.plugin.HugeGraphGremlinPlugin: {}
serializers:
  - { className: org.apache.tinkerpop.gremlin.util.ser.GraphBinaryMessageSerializerV1 }
  - { className: org.apache.tinkerpop.gremlin.util.ser.GraphSONMessageSerializerV3 }
maxInitialLineLength: 4096
maxHeaderSize: 8192
maxChunkSize: 8192
maxContentLength: 65536
resultIterationBatchSize: 64
writeBufferHighWaterMark: 65536
writeBufferLowWaterMark: 32768
channelizer: org.apache.tinkerpop.gremlin.server.channel.WebSocketChannelizer
gremlinPool: 8
threadPoolBoss: 1
threadPoolWorker: 1
rpcServerPort: __RPC_PORT__
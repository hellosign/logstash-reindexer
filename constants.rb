## The ElasticSearch host to hit for Elastic operations.
ES_HOST  = '192.0.2.199'

## The name of the snapshot repository you will be performing snapshot
## operations on.
ES_REPO = 'logstash-repository'

## The name of the Redis host used for Resque. It's safe to use your
## logstash redis host, if one is used.
RED_HOST = 'redis-queue'

## The regex to use to identify which snapshots in the repo we wish to process.
## The default looks for snapshots named like: "logstash-20190801"
SNAP_REGEX = /^logstash-\d{8}/

## The target maximum shard-size in bytes. Used to reduce shard-counts
## of indexes from the "default to 5 shards" days. Will also expand
## shard-counts for indexes that blew past this size. Elastic recommends
## keeping this value below 50GB for performance, but you need to test your
## reindexing to know how much reduction you naturally get.
SHARD_TARGET = 50*1024*1024*1024


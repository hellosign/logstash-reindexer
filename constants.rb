## The ElasticSearch host to hit for Elastic operations.
ES_HOST  = '127.0.0.1'

## The name of the snapshot repository you will be performing snapshot
## operations on.
ES_REPO  = 'reindexing_repo'

## The name of the Redis host used for Resque. It's safe to use your
## logstash redis host, if one is used.
RED_HOST = 'logstash.example.com'

## The regex to use to identify which snapshots in the repo we wish to process.
## The default looks for snapshots named like: "logstash-20190801"
SNAP_REGEX = /^logstash-\d{8}/

## How big the bulk-updates should be to ES. Larger is not always faster,
## you will probably want to try tuning this.
ES_BULK_SIZE = 750


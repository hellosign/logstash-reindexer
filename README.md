# LogStash Snapshot Reindexer
This ruby framework is intended to assist in upgrading an ElasticSearch backend
for LogStash from ES 1.x to ES 2.x, and perhaps also the ES 2.x to ES 5.x
upgrade as well. In legacy deployments, you may have the requirement to restore
ElasticSearch snapshots for up to N years to support regulatory or compliance 
objectives. When doing an ElasticSearch upgrade, you also need to be sure
your snapshots will restore on the new ElasticSearch codebase.

Because of this, chances are good you'll have to reindex all of your snapshots.
Depending on the nature of the upgrade, you may have to do some schema
adjustments as you do so to deal with changes in the ElasticSearch features.
This framework assists in managing this reindexing workflow.

The tools available in ElasticSearch 5.x and newer make this framework somewhat
less useful when you get to that level. This is intended to help you _get_
to that level.

## Requirements and Cautions
* This framework is written in Ruby, and works best with version 2.1.0 or newer.
* For operational reasons, it's better to perform your reindexing on a separate cluster from your production load.
* You will need a Redis server to act as a work-queue. This uses [`resque`](https://github.com/resque/resque).
  * If you are already using a redis server for your logstash work, this is safe to reuse.
* This framework doesn't tolerate ephemeral servers without human intervention.
  * If you need to patch these, there is a method to pause reindexing operations.
  * If you need to replace these, you will need to pause reindexing, reinstall this framework on the new server, and restart reindexing.
* This isn't set up to handle SSL or authentication to ElasticSearch.
* Reindexing is incredibly write heavy. Plan for this.

## Installing

1. Clone this repo somewhere you can make changes.
1. Update `tasks/reindexer.rb`, in the `def self.mutate_mapping` function.
1. In `reindexer.rb`, write code for any mapping changes you need to make. There are examples to show how it can look.
1. Update `constants.rb` for your Redis server.
1. Package your updated repo up and ship it to your reindexing cluster.
1. Deploy the updated repo to the nodes you plan on running workers from.
1. If needed, [set up the snapshot repo on your cluster](https://www.elastic.co/guide/en/elasticsearch/reference/1.7/modules-snapshots.html#_repositories).
    * Running `http://localhost:9200/_snapshot?pretty` on your prod cluster will give you hints as to what you want in this step.
1. [By hand, restore an index from your archive](https://www.elastic.co/guide/en/elasticsearch/reference/1.7/modules-snapshots.html#_restore).
1. On one server, update `constants.rb` for the `ES_HOST` value to describe the ES host the scripts will be talking to.
1. On one server, Run `test_reindex` on the index.
    * `bin/test_reindex logstash-2014.10.22 logstash-reindex` to reindex the `logstash-2014.10.22` index into `logstash-reindex`
    * The intent is to test your reindexing code, make sure it looks right, and allow you to profile performance.
        * `ES_BULK_SIZE` in `constants.rb` is something you should look at in this step.
1. Once you are confident you have everything how you need it, zero the queues through `bin/zero_queues`
1. Go to the `Running` procedure to start the reindexing.

## Running
There are two workers here. The `snapper` worker that performs snapshot
operations, and `reindexer` workers that do reindexing. Due to limits with
ElasticSearch, _one and only one `snapper` should run_, as only one snapshot
operation at a time may be performed on a cluster. If you're running this
framework in your production environment, your existing snapshot infrastructure
will likely conflict with this one. Yet another reason to not try to run this
on your production cluster.

1. Localize your `constants.rb` file for each node that will be doing work.
    * The `ES_HOST` constant is the most likely one to need updates.
    * The `RED_HOST` constant should have been updated during the install procedure.
1. On one node, run `gen_snaplist.rb` to populate your snapshot list.
1. On one node, run `bin/list_queues` to show the size of the snapshot list.
1. On one node, run `bin/zero_queues` to purge any `snapper` jobs that built up during testing and profiling.
1. On one node, run `bin/spawn_snapper` to launch the `snapper` worker.
1. On one node, run `bin/pop_snapshot` to inject the first restore.
    * Run once for each reindexer worker you plan to run in parallel.
1. On each node where a reindexer will run, run `bin/spawn_reindexer` to launch a `reindexer` worker.
    * Don't run more than one of these on a data-node.
    * Run this on a client-only node if possible. Those can run more than one, if you have CPU room.
1. Logs will be output to a 'resque.log' file in the same directory as the Rakefile.

## Pipeline

Initalization:

1. `gen_snaplist` is run to populate the `snaplist` list in Redis.
1. The `pop_snapshot` script is run to trigger a snapshot restore.

Reindexing an index:

1. The `snapper` worker pops a restore-snapshot job off of the `snapper` queue and restores a snapshot.
1. The `snapper` worker pushes a job onto the `reindexer` queue.
1. A `reindexer` worker pops a job off of the `reindexer` queue and begins reindexing.
1. The `reindexer` worker pushes a take-snapshot job onto the `snapper` queue.
1. The `reindexer` worker pops a record off of the `snaplist` list, and pushes a restore-snapshot job onto the `snapper` queue.
1. The `snapper` worker pops off a take-snapshot job, and performs a snapshot, cleaning up the snapshot index and the one restored in step 1.


## Notes on performance
Reindexing is incredibly write-heavy. As a result: 

* It will use more write I/O than your production environment. Possibly a *lot* more.
* It will use more CPU than your production environment.
    * The bulk-queries it runs to feed the reindexing will produce high reads.
    * The bulk-inserts it runs to feed the reindexing will drive CPU loads through analysis and index-creation.
* It will likely require less RAM than your production environment, as you (probably) won't have as many indexes loaded in parallel.
* Once you've reached the maximum documents-per-second rate your cluster can support, adding more reindexing workers won't make it go faster.

Don't plan on using old hardware for this. If you have a year of snapshots to
reindex, you will be reindexing data that took a year to index on your
production environment. If it takes a month to reindex that year, that's a 12x
speed increase versus production. Can your old hardware run 12x faster than
prod? If yes, then go ahead. If no, then plan to budget for more resources for
this effort.

This is the point when you can go to the budetary powers that be and show them
what 'keep everything' costs. You may be allowed to do fewer snapshots!

There are still some things you can do to make it go faster:

* If you have the resources, run enough data-nodes that each index never shares a shard with another shard of the same index.
    * For the default setting of 5 shards with 1 replica, this means 10 data-nodes.
* If not, ensure you have enough data-nodes that no more than 2 primary-shards exist for an index on a node.
    * For the default setting of 5 shards with 1 replica, this means 5 data-nodes.
* Don't run it on your production environment. The competing I/O will slow it down, and slow prod down.
* Run the `reindexer` workers on client-only nodes, to ensure the ruby-script doesn't steal CPU from data-node reindexing.
* This will run long enough it's worth your time to attempt to profile where your bottlenecks are and resolve them.

## Utility Scripts
There are a few scripts to help you keep track of what is going on, and deal
with a few edge-cases.

### `bin/list_queues`
This will show how many jobs are queued and snapshots are left in your list.

```
Reindexer           : 0
Snapper             : 1
Snapshots Remaining : 298
```

### `bin/pause_workers`
This will issue a SIG_USR2 to your Resque workers. This tells them to stop
taking new jobs once it is done working on the current one. Any reindexing jobs
that are running will run to completion, and then not take any new jobs.

Use this if you need to stop reindexing politely to reduce load. You can resume
through the `bin/unpause_workers` command.

### `bin/pop_snapshot`
As described in the `Running` procedure, will pop a snapshot off of the
snapshot list, and submit it to the `snapper` worker for restore.

### `bin/spawn_reindexer`
As described above, will launch a `reindexer` worker on the node.

### `bin/spawn_snapper`
As described above, will launch a `snapper` worker on the node. Only one of
these should ever be running!

### `bin/stop_workers`
This will issue a SIG_QUIT to your Resque workers. This tells them to stop
taking new jobs once it is done working on the current one, then fully exit.
As with `pause`, any running workers will run to completion before exiting.

You will need to `respawn` to start them working again.

### `bin/unpause_workers`
This will issue a SIG_CONT to your Resque workers. If they were paused with
`pause_workers`, this will get them running again.

### `bin/zero_queues`
If you really need to, this will zero the `snapper` and `reindexer` queues. It
won't touch the `reindex_snaplist` queue.
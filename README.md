# Logstash Snapshot Reindexer
This Ruby framework is intended to assist in upgrading an Elasticsearch backend
for Logstash ES 5.x to 6.x, and perhaps ES 6.x to 7.x as well. In legacy deployments,
you may have the requirement to restore Elasticsearch snapshots for up to N years
to support regulatory or compliance objectives. When doing an Elasticsearch upgrade,
you also need to be sure your snapshots will restore on the new Elasticsearch codebase.

Because of this, chances are good you'll have to reindex all of your snapshots.
Depending on the nature of the upgrade, you may have to do some schema
adjustments as you do so to deal with changes in the Elasticsearch features.
This framework assists in managing this reindexing workflow.

* ES 1.x --> 2.x: All fields named the same must be the same type between mappings.
* ES 5.x --> 6.x: You only get a single mapping type, so unify your mappings.
* ES 6.x --> 7.x: You don't get a mapping type anymore.

The Reindexing API available in Elasticsearch 5.x and newer make this framework
somewhat less gnarly when you get to that level. This is intended to help you _get_
to that level.

Reindexing is a great time to perform any redactions to your long-term snapshots,
such as removing privacy or health-related information that otherwise shouldn't
be there. This is best done as part of the `mutate_mapping` function, which runs
before reindexing starts. This ensures your reprocessed index has no deleted or
altered documents.

This will also reshard your indexes to stay below a configured maximum shard-size
(see constants.rb).

* [Requirements and Cautions](#requirements-and-cautions)
* [Installing](#installing)
* [Running](#running)
* [Pipeline](#pipeline)
* [Notes on Performance](#notes-on-performance)
* [Utility Scripts](#utility-scripts)
* [Operational Runbooks](#operational-runbooks)
    * [Patching](#patching)
    * [Moving a Worker](#moving-a-worker)
    * [Pause Reindexing](#pause-reindexing)
    * [Restarting from an unsafe stop](#restarting-from-an-unsafe-stop)

## Requirements and Cautions
* This framework is written in Ruby, and works best with version 2.5.0 or newer.
    * This requirement comes from the `redis` gem, needed as part of `resque`. If your redis version is not 4.x, you can use an earlier version of the redis gem that works with Ruby 2.1.0.
* For operational reasons, it's better to perform your reindexing on a separate cluster from your production load.
* You will need a Redis server to act as a work-queue. This uses [`resque`](https://github.com/resque/resque).
    * If you are already using a redis server for your logstash work, this is safe to reuse.
* This framework doesn't tolerate ephemeral servers without human intervention.
    * [If you need to patch these](#patching), there is a method to pause reindexing operations.
    * [If you need to replace these](#patching), you will need to pause reindexing, reinstall this framework on the new server, and restart reindexing.
* This isn't set up to handle SSL or authentication to Elasticsearch.
* Reindexing is incredibly write heavy. Plan for this.
* Reindexing uses far more CPU than regular operations. Plan for this.
* This uses the [Reindexing API](https://www.elastic.co/guide/en/elasticsearch/reference/6.8/docs-reindex.html), which uses tasks. The node that receives a Reindexing API call will manage the effort and consume more CPU than nodes just processing the reindexing. Plan to spread out your reindexer workers.

## Installing

1. Clone this repo somewhere you can make changes.
1. Edit `Gemfile` to use the correct Elasticsearch gems for your ES version.
1. Update `tasks/reindexer.rb`, in the `def self.mutate_mapping` function.
1. In the `mutate_mapping` function in `tasks/reindexer.rb`, write code for any mapping changes you need to make. There are examples to show how it can look.
    * This is very important. Out of the box, it does no transformations and simply copies.
1. Update `RED_HOST` in `constants.rb` for your Redis server.
1. Update `SNAP_REGEX` with a [ruby regex](http://rubular.com/r/aaduXGIKcm) that will match the snapshots you want to reindex. This defaults to snapshots named in this style: `logstash-20190801`.
1. Package your updated repo up and ship it to your reindexing cluster.
1. Deploy the updated repo to the nodes you plan on running workers from.
1. If needed, [set up the snapshot repo on your cluster](https://www.elastic.co/guide/en/elasticsearch/reference/6.8/modules-snapshots.html#_repositories).
    * Running `http://localhost:9200/_snapshot?pretty` on your prod cluster will give you hints as to what you want in this step.
1. [By hand, restore an index from your archive](https://www.elastic.co/guide/en/elasticsearch/reference/6.8/modules-snapshots.html#_restore).
1. On one server, update `constants.rb` for the `ES_HOST` value to describe the ES host the framework will be talking to.
1. On one server, Run `test_reindex` on the index.
    * `bin/test_reindex logstash-2014.10.22 logstash-reindex` to reindex the `logstash-2014.10.22` index into `logstash-reindex`
    * The intent is to test your reindexing code, make sure it looks right, ensure your redactions are being performed correctly (if any) and allow you to profile performance.
1. Update `SHARD_TARGET` in `constants.rb` to set the maximum shard-size for your indexes, which defaults to 60GB. Keep in mind that in most environments, your reprocessed index will be significantly smaller than it started. The math behind shard-selection is based on the _source index size_, which will be larger than your _target index size_. Benchmarking will let you know what a safe value is for your particular data.
1. Once you are confident you have everything how you need it, zero the queues through `bin/zero_queues`
1. Go to the `Running` procedure to start the reindexing.

## Running
There are two workers here. The `snapper` worker that performs snapshot
operations, and `reindexer` workers that do reindexing. Due to limits with
Elasticsearch, _one and only one `snapper` should run_, as only one snapshot
operation at a time may be performed on a cluster. If you're running this
framework in your production environment, your existing snapshot infrastructure
will likely conflict with this one. Yet another reason to not try to run this
on your production cluster.

1. Localize your `constants.rb` file for each node that will be doing work.
    * The `ES_HOST` constant is the most likely one to need updates.
    * The `RED_HOST` constant should have been updated during the install procedure.
    * The `SNAP_REGEX` contant should have been updated during the install procedure.
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


## Notes on Performance
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
* The node the `reindexer` workers hit to submit Reindexing API calls will consume more CPU than other nodes, as it has to coordinate the reindexing effort (in the ES2 version of this framework, the reindexing worker itself handled this task in a long-running Ruby process).
* This will run long enough it's worth your time to attempt to profile where your bottlenecks are and resolve them.

## Utility Scripts
There are a few scripts to help you keep track of what is going on, and deal
with a few edge-cases.

### `bin/inject_reindexer`
For use if a reindexing job is terminated suddenly, leaving a source index and
an incomplete target index. This will restart reindexing on that index from the
start, and perform the appropriate snapshot work.

```
bin/inject_reindexer logstash-20190801 logstash-2019.08.01
```

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

## Operational Runbooks
Because this is likely to run a very long time, this will need to be
integrated into your existing environment's regular maintenance cycle. Here
are some template runbooks to help you through some common tasks.

### Patching
This should be valid for both *patch-and-reboot* and *migrate-and-replace*
methods of patching an infrastructure.

1. Set up your cluster so that the `snapper` worker does not share a node with any `reindexer` workers.
1. Stop your reindexing workers through `bin/stop_workers`.
1. Wait for all reindexing workers to stop processing.
1. Allow the `snapper` worker to do its thing, which is a snapshot then restore of new.
1. Once the `snapper` worker has no more work, stop it through `bin/stop_workers`
1. Follow your normal patching runbook.
1. If needed, reinstall the reindexing framework to the instances that will be running workers.
1. Start your `reindexer` workers, through `bin/spawn_reindexer`. This should pick up the reindex jobs left behind by the `snapper` before the reboots.
1. Start your single `snapper` worker.

If you have enough nodes in your cluster that there are some ES nodes that
do not host a worker, those can be patched normally without stopping reindexing.
Once those are done, then you can use this runbook. This should reduce the
reindexing-outage time.

### Moving a worker
If you need to move a worker from one node to another for some reason.

1. On the source instance, run `bin/stop_workers`.
1. Wait for any reindexing or snapshot jobs to complete on their own.
1. Install and localize the reindexing framework on the new instance.
1. Run the `bin/spawn_snapper` or `bin/spawn_reindexer` command as needed.

### Pause Reindexing
If you're running this on your production environment for resource-reasons, and
only want to run reindexing during off hours, there is a way.

1. Create a cronjob to run the `bin/pause_workers` script before prod-load starts.
1. Create a cronjob to run the `bin/unpause_workers` script after prod-load has slackened.

This will take a lot longer than doing it on its own cluster, but it can be done.

### Restarting from an unsafe stop
If you couldn't safely stop reindexing and things terminated suddenly, any
reindexing going on at the time of the event has left useless indexes. Use
this procedure to get reindexing back underway.

1. Identify the indexes that are left behind.
    * These will be pairs of indexes following the `basename` + `basename-base` format
1. For each pair, run `bin/inject_reindexer #{snapshot_name} #{index_name}`
    * You will have to know what name these will be snapshot into
    * Example: `bin/inject_reindexer logstash-20190801 logstash-2019.08.01`
    * This will remove the old reindexed index and begin indexing on a new one.

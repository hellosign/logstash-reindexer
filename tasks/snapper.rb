require 'resque'
require 'elasticsearch'

# The Snapper worker-class. Called by Resque in response to jobs submitted
# to the `snapper` queue.
#
# This class is entered through the {Snapper.perform perform} method.
#
# @author Jamie Riedesel <jamie.riedesel@hellosign.com>
class Snapper
  @queue = :snapper

  # Snapper worker perform class, called from `Resque`.
  #
  # This method is invoked by Resque when a job enters the `snapper` queue.
  # This worker is responsible for performing snapshot operations on the
  # ElasticSearch cluster, and only one of these should be running at a time.
  # This worker performs both `snapshot` and `restore` operations.
  #
  # @example Restore job
  #   Snapper.perform( "restore", "prod-logstash-20170922", "logstash-2017.09.22" )
  #
  # @example Snapshot job
  #   Snapper.perform( "snapshot", "prod-logstash-20170922", "logstash-2017.09.22" )
  #
  # A `restore` job will restore the named index in the given snapshot, and
  # rename it a predictable way. Then queue a job for the `reindexer` worker 
  # to perform reindexing on the newly restored index.
  #
  # A `snapshot` job will snapshot the specified index into a snapshot of the
  # given name, clean up both indexes after the snapshot, and exit without 
  # further work.
  #
  # @see Reindexer.perform
  #
  # @param action [String] The snapshot action to perform. May be either `snapshot` or `restore`.
  # @param snapshot [String] The snapshot to perform the action on
  # @param index [String] The index involved in snapshotting
  def self.perform(action, snapshot, index)
    if action == 'snapshot'
      snapshot(snapshot, index)
    elsif action == 'restore'
      restore(snapshot, index)
    end
  end

  private

  # Performs the restore-snapshot action. Only exists after the cluster is in
  # The 'green' state, meaning all replicas have caught up. Done to reduce load
  # on the cluster as a whole.
  #
  # @param snapshot [String] The snapshot to restore
  def self.restore(snapshot, index)
    esclient = Elasticsearch::Client.new host: ES_HOST
    restore_results = esclient.snapshot.restore repository: ES_REPO,
                                                snapshot: snapshot,
                                                body: {
                                                  rename_pattern: "^(.*)$",
                                                  rename_replacement: "$1-base",
                                                  include_global_state: false
                                                }
    snap_wait(esclient, snapshot)
    cluster_wait(esclient)
    Resque.enqueue(Reindexer, "#{snapshot}", "#{index}")
  end

  # Performs the take-snapshot action.
  #
  # @param snapshot [String] The name of the snapshot to take.
  # @param index [String] The index to put into the named snapshot.
  def self.snapshot(snapshot, index)
    esclient = Elasticsearch::Client.new host: ES_HOST
    begin
      rmsmap = esclient.snapshot.delete repository: ES_REPO, snapshot: snapshot
    rescue Elasticsearch::Transport => e
      puts "Removal of existing snapshot failed for some reason. This isn't fatal."
      puts e
    end
    resnap = esclient.snapshot.create repository: ES_REPO,
                                      snapshot: snapshot,
                                      body: { indices: index, ignore_unavailable: true }
    snap_wait(esclient, snapshot)
    esclient.indices.delete index: "#{index}"
    esclient.indices.delete index: "#{index}-base"
  end

  # Waits until the specified snapshot is completed.
  #
  # @param esclient [Elasticsearch::Client] An inited object of type Elasticsearch::Client
  # @param snapshot [String] The name of the snapshot to track.
  def self.snap_wait(esclient, snapshot)
    loop do
      snapstat = esclient.snapshot.status repository: ES_REPO, snapshot: snapshot
      break if snapstat['snapshots'][0]['state'] == 'SUCCESS'
      sleep 5
    end
  end

  # Waits until the cluster is in the 'green' state. It will be in 'red' during
  # initial snapshot restore as the primaries are populated, then 'yellow'
  # during replica-instatiation. Returns after it is 'green'.
  #
  # @param esclient [Elasticsearch::Client] An inited object of type Elasticsearch::Client
  def self.cluster_wait(esclient)
    loop do
      health = esclient.cluster.health
      break if health['status'] == 'green'
      sleep 5
    end
  end
end

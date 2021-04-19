require './constants.rb'
require 'redis'
require 'elasticsearch'
require 'json'

esclient = Elasticsearch::Client.new host: ES_HOST

raw_snaps  = esclient.snapshot.get repository: ES_REPO, snapshot: '_all'
red_client = Redis.new(:host => RED_HOST)
our_snaps  = {}
raw_snaps['snapshots'].each do |snap|
  if snap['snapshot'] =~ SNAP_REGEX &&
     snap['state'] == 'SUCCESS' &&
     snap['indices'].size == 1
    our_snaps[snap['snapshot']] = snap['indices']
  end
end

# Get our list of snapshots, and reverse it since it will be popped out
# stack-style. Should ensure the oldest gets popped first.
our_snaps.keys.sort.reverse.each do |sn|
  snap_data = JSON.dump({ 'snapshot' => sn, 'index' => our_snaps[sn][0] })
  red_client.lpush('reindex_snaplist', snap_data)
end

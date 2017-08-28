require 'resque'
require 'elasticsearch'
require 'redis'

# The Reindexer worker-class. Called by Resque in response to jobs fetched from
# the `reindexer` queue.
#
# The class is entered through the {Reindexer.perform perform} method.
#
# ## Note
# The {Reindexer.mutate_mapping mutate_mapping} method will need localization
# for each environment doing reindexing. Out of the box all it does is copy
# events without change. If you are doing an ES 1.x to ES 2.x upgrade, this is
# likely **not** what you want.
#
# @author Jamie Riedesel <jamie.riedesel@hellosign.com>
class Reindexer
  
  # The JSON to define a field of type string
  TYPE_STRING  = {"type"=>"string", "norms"=>{"enabled"=>false}, "fields"=>{"raw"=>{"type"=>"string", "index"=>"not_analyzed", "ignore_above"=>256}}}

  # The JSON to define a field of type long
  TYPE_LONG    = {"type"=>"long"}

  # The JSON to define a field of type boolean
  TYPE_BOOLEAN = {"type"=>"boolean"}

  # The JSON to define a field of type float
  TYPE_FLOAT   = {"type"=>"float"}

  @queue = :reindexer

  # The perform class for Reindexer.
  #
  # The `snapper` worker restores indexes from the `snapshot`, renamed with
  # `-base` at the end. It then submits a job for this worker, giving the
  # name of the snapshot being worked on, and the index-name it just restored.
  # This worker then reindexes the `index` index into an index named `snapshot`.
  #
  # @example
  #   Reindexer.perform("logstash-20170922", "logstash-2017.09.22")
  #
  # Once reindexing is completed, will submit a job to `snapper` to snapshot
  # the reindexed index.
  #
  # @see Snapper.perform
  #
  # @param snapshot [String] The name of the snapshot being worked on.
  # @param index [String] The index being reindexed.
  def self.perform(snapshot, index)
    Resque::Logging.info("Picked up reindexing job, #{snapshot}")
    esclient = Elasticsearch::Client.new host: ES_HOST, request_timeout: 360
    mutate_mapping(esclient, index)
    reindex(esclient, snapshot, index)
    push_new()
  end

  private

  # Mutates the index mapping to make it ES2.x friendly, and create the
  # index we're reindexing into; should be edited.
  #
  # This is the method that performs the mapping mutation. If you are doing an
  # ES 1.x to ES 2.x upgrade, you will likely need to make changes to the
  # logic here.
  #
  # @note This function should be edited.
  #
  # @param esclient [Elasticsearch::Client] An inited object of type Elasticsearch::Client
  # @param index [String] The name of the index getting reindexed.
  def self.mutate_mapping(esclient, index)
    mapping      = esclient.indices.get_mapping index: "#{index}-base"
    base_mapping = mapping["#{index}-base"]

    # This is where you put your schema conversions. Here are some examples:
    #
    ### Coerce all 'value' fields in all types to LONG.
    ## base_mapping['mappings'].each_key do |tc|
    ##   base_mapping['mappings']["#{tc}"]['properties']['value'] = TYPE_LONG
    ## end
    ##
    ### Coerce the 'timestamp' field in the 'cheese_callback' type to STRING.
    ## if base_mapping['mappings']['cheese_callback'] != nil
    ##   base_mapping['mappings']['cheese_callback']['properties']['timestamp'] = TYPE_STRING
    ## end
    
    # Create the index using the revised mapping.
    index_create = esclient.indices.create index: index, body: base_mapping
    Resque::Logging.info("Created target index, #{index}.")
  end

  # Performs the reindexing function for reindexing.
  #
  # @param esclient [Elasticsearch::Client] An inited object of type Elasticsearch::Client
  # @param snapshot [String] The name of the snapshot this index belongs to.
  # @param index [String] The name of the index that is getting reindexed.
  def self.reindex(esclient, snapshot, index)
    Resque::Logging.info("Beginning reindex of #{index}-base to #{index}")
    rs = esclient.search index: "#{index}-base",
                         search_type: 'scan',
                         scroll: '2m',
                         size: ES_BULK_SIZE
    loop do
      us = []
      rs = esclient.scroll(scroll_id: rs['_scroll_id'], scroll: '2m')
      break if rs['hits']['hits'].empty?
      rs['hits']['hits'].each do |doc|
        us.push( index: { _index: index, _type: doc['_type'], _id: doc['_id'],
                           data: doc['_source'] } )
      end
      esclient.bulk body: us
    end
    Resque::Logging.info("Finished reindexing of #{index}.")
    Resque.enqueue( Snapper, "snapshot", "#{snapshot}", "#{index}" )
  end

  # Pops off the next snapshot from the redis-list and submits it for restore.
  def self.push_new()
    redball   = Redis.new( :host => "#{RED_HOST}" )
    snap_data = JSON.parse( redball.lpop( 'reindex_snaplist' ) )
    Resque.enqueue( Snapper, "restore", "#{snap_data['snapshot']}", "#{snap_data['index']}" ) 
  end

end

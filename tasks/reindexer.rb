require 'resque'
require 'elasticsearch'
require 'redis'

# The Reindexer worker-class. Called by Resque in response to jobs fetched from
# the `reindexer` queue.
#
# The class is entered through the {Reindexer.perform perform} method.
#
# The {Reindexer.test_reindex test_reindex} method is used to test the reindexing
# logic, without triggering any snapshot operations.
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
  TYPE_STRING  = {"type"=>"text", "norms"=>false, "fields"=>{"raw"=>{"type"=>"keyword", "ignore_above"=>256}}, "fielddata"=>false}

  # The JSON to define a field of type long
  TYPE_LONG    = {"type"=>"long"}

  # The JSON to define a field of type boolean
  TYPE_BOOLEAN = {"type"=>"boolean"}

  # The JSON to define a field of type float
  TYPE_FLOAT   = {"type"=>"float"}

  # The JSON to define a keyword type
  TYPE_KEYWORD = {"type"=>"keyword"}

  # The JSON to define a text type
  TYPE_TEXT    = {"type"=>"text", "norms"=>false}

  # The default mapping for ES6. Set number_of_shards and
  # total_fields.limit to values that make sense for you.
  DEF_MAPPING  = {
    "settings" => {
      "index.number_of_shards"                   => "5",
      "index.mapping.total_fields.limit"         => "1024"
    },
    "mappings" => {
      "_doc" => {
        "dynamic_templates" => [
          {
            "message_field" => {
              "match"              => "message",
              "match_mapping_type" => "string",
              "mapping"            => {
                "fielddata" => false,
                "index"     => "true",
                "norms"     => false,
                "type"      => "text"
              }
            }
          },
          {
            "string_fields" => {
              "match"              => "*",
              "match_mapping_type" => "string",
              "mapping"            => {
                "fielddata" => false,
                "fields"    => {
                  "raw" => {
                    "ignore_above" => 256,
                    "type"         => "keyword"
                  }
                },
                "index"     => "true",
                "norms"     => false,
                "type"      => "text"
              }
            }
          }
        ],
        "properties" => {
          "message" => {
            "type" => "text",
          }
        }
      }
    }
  }

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
    testmode = false
    esclient = Elasticsearch::Client.new host: ES_HOST, request_timeout: 360
    mutate_mapping(esclient, "#{index}-base", index)
    reindex(esclient, snapshot, index, testmode)
    push_new()
  end

  # Perform a test reindexing using the mutate functions
  #
  # This is intended to be a method used to test your mapping mutations, and
  # overall reindexing ability. It doesn't trigger any snapshots, it simply
  # reindexes the source into the target by way of the
  # {Reindexer.mutate_mapping mutate_mapping} method.
  #
  # @example
  #   Reindexer.test_reindex("logstash-2019.08.02", "logstash-2019.08.02-crosscheck")
  #
  # @param source [String] The name of the index to act as source.
  # @param target [String] The name of the index to reindex into.
  def self.test_reindex(source, target)
    testmode = true
    esclient = Elasticsearch::Client.new host: ES_HOST, request_timeout: 360
    mutate_mapping(esclient, source, target)
    reindex(esclient, source, target, testmode)
  end

  private

  # Mutates the index mapping to make it friendly to the next ES version, and
  # create the index we're reindexing into.
  #
  # This is the method that performs the mapping mutation.
  #
  # * If you are doing an ES 1.x to ES 2.x upgrade, this is where you merge field-types.
  # * If you are doing an ES 5.x to ES 6.x upgrade, this is where you merge mappings to a single one.
  #
  # You will likely need to make changes to the logic here.
  #
  # This method is also where you would perform any redactions to your
  # events, such as removing accidentally logged privacy or health information.
  #
  # @note This function should be edited.
  #
  # @note This will remove _default_ mapping-types, which were removed in ES7.
  #
  # @param esclient [Elasticsearch::Client] An inited object of type Elasticsearch::Client
  # @param source [String] The name of the index to pull mappings from.
  # @param target [String] The name of the index to create with the mutated mapping.
  def self.mutate_mapping(esclient, source, target)
    mapping         = esclient.indices.get_mapping index: source
    base_mapping    = mapping[source]
    target_mapping  = DEF_MAPPING
    source_settings = esclient.indices.get_settings index: source

    index_stats = esclient.indices.stats index: source
    index_repl  = source_settings[source]['settings']['index']['number_of_replicas'].to_i + 1
    index_size  = index_stats['_all']['total']['store']['size_in_bytes'].fdiv(index_repl)

    # Shard-limit, we want under SHARD_TARGET sized shards, minimum 1.
    target_mapping['settings']['index.number_of_shards'] = index_size.fdiv(SHARD_TARGET).ceil
    # Field-limit, definitely copy this
    target_mapping['settings']['index.mapping.total_fields.limit'] = source_settings[source]['settings']['index']['mapping']['total_fields']['limit']
    # target-allocation, make sure things stay on
    # wherever they're supposed to.
    if source_settings[source]['settings']['index'].keys.include?('routing')
      target_mapping['settings']['index.routing'] = source_settings[source]['settings']['index']['routing']
    end

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

    # Force everything to the '_doc' doctype. ES6 restriction. For the ES7
    # reindexing, we can likely avoid the subtype loop entirely.
    base_mapping['mappings'].each_key do |subtype|
      if subtype != '_default_'
        base_mapping['mappings'][subtype]['properties'].each_key do |type_key|
          # Due to ES2+ restrictions, there shouldn't be type-collisions between mappings.
          if not target_mapping['mappings']['_doc']['properties'].has_key?(type_key)
            target_mapping['mappings']['_doc']['properties'][type_key] = base_mapping['mappings'][subtype]['properties'][type_key]
          end
          if target_mapping['mappings']['_doc']['properties'][type_key]['type'] == "string"
            # 'string' --> 'text' conversion, not needed for ES7.
            target_mapping['mappings']['_doc']['properties'][type_key] == TYPE_STRING
          elsif target_mapping['mappings']['_doc']['properties'][type_key]['type'] == "double"
            # 'double' --> 'float' conversion, to save space.
            target_mapping['mappings']['_doc']['properties'][type_key] == TYPE_FLOAT
          end
        end
      end
    end

    # This is where you could perform redactions as part of reprocessing.
    # Perform changes on the source index before we start reindexing, to
    # ensure the target index has no trace of the removed/redacted events.

    # Example of deleting everything containing a key string, such as
    # removing privacy information. This example removes events that look like:
    #
    #   Created account hithere@example.com in zone 119291
    #
    #esclient.delete_by_query index: source, wait_for_completion: true, body: {
    #  "query": {
    #    "query_string": {
    #      "query": 'message:"Created account for" AND message:"in zone"'
    #    }
    #  }
    #}

    # Create the index using the revised mapping.
    index_create = esclient.indices.create index: target, body: target_mapping
    Resque::Logging.info("Created target index, #{target}.")
  end

  # Performs the reindexing function for reindexing.
  #
  # @overload reindex(testmode=true)
  #   Performs a reindexing in testmode, where no snapshots will be generated.
  #   @param esclient [Elasticsearch::Client] An inited object of type Elasticsearch::Client
  #   @param snapshot [String] The source index for reindexing.
  #   @param index [String] The target index for reindexing.
  #   @param testmode [Boolean]
  # @overload reindex(testmode=false)
  #   Performs a regular reindexing, where snapshots will be generated.
  #   @param esclient [Elasticsearch::Client] An inited object of type Elasticsearch::Client
  #   @param snapshot [String] The name of the snapshot this index belongs to.
  #   @param index [String] The name of the index that is getting reindexed.
  #   @param testmode [Boolean]
  def self.reindex(esclient, snapshot, index, testmode=false)
    if testmode
      puts("Beginning reindex of #{snapshot} into #{index}")
      source_index = snapshot
      target_index = index
    else
      Resque::Logging.info("Beginning reindex of #{index}-base to #{index}")
      source_index = "#{index}-base"
      target_index = index
    end
    # Force-flush to commit the translog. If we don't do this, redacted
    # documents may still be present after reindexing.
    esclient.indices.flush index: source_index
    # Get shard-count:
    target_settings = esclient.indices.get_settings index: target_index
    shard_count = target_settings[target_index]['settings']['index']['number_of_shards'].to_i
    # Uses the Reindexing API to perform the index, it's a task.
    reindex_task = esclient.reindex slices: 'auto', wait_for_completion: false, body: {
      source: {
        index: source_index
      },
      dest: {
        index: target_index
      },
      script: {
        source: 'ctx._type = params.type',
        params: {
          type: '_doc'
        },
        lang: 'painless'
      }
    }
    log_msg = "Waiting for reindex of #{source_index} into #{target_index} through #{reindex_task['task']} and #{shard_count} shards."
    if testmode
      puts(log_msg)
    else
      Resque::Logging.info(log_msg)
    end
    task_status = esclient.tasks.get task_id: reindex_task['task']
    while task_status['completed'] == false
      sleep 10
      task_status = esclient.tasks.get task_id: reindex_task['task']
    end

    if testmode
      puts('Terminating without snapshot. Go check your work.')
    else
      Resque::Logging.info("Finished reindexing of #{index}.")
      Resque.enqueue( Snapper, 'snapshot', snapshot, index )
    end
  end

  # Pops off the next snapshot from the redis-list and submits it for restore.
  def self.push_new()
    redball   = Redis.new( :host => RED_HOST )
    snap_data = JSON.parse( redball.lpop( 'reindex_snaplist' ) )
    Resque.enqueue( Snapper, 'restore', snap_data['snapshot'], snap_data['index'] )
  end

end

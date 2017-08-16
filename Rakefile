require 'resque/tasks'
require 'logger'
import 'tasks/snapper.rb'
import 'tasks/reindexer.rb'
import 'constants.rb'

namespace :resque do
  task :setup do
    require 'resque'
    require 'resque/logging'
    Resque.redis = "#{RED_HOST}:6379"
    Resque.logger = Logger.new('resque.log')
  end
end

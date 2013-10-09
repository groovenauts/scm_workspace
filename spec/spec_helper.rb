if ENV["COVERAGE"] =~ /true|yes|on/
  require 'simplecov'
  SimpleCov.start
end

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'scm_workspace'

RSpec.configure do |config|
  # config.filter_run_excluding svn: true
end

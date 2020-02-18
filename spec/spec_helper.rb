require 'rspec/expectations'
require 'fileutils'
autoload :Byebug, 'byebug'

require 'mongo_manager'

require 'support/ps'

RSpec.configure do |config|
  config.expect_with(:rspec) do |c|
    c.syntax = :should
  end
end

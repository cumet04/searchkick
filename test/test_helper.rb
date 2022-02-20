require "bundler/setup"
Bundler.require(:default)
require "minitest/autorun"
require "minitest/pride"
require "active_support/notifications"

ENV["RACK_ENV"] = "test"

# for reloadable synonyms
if ENV["CI"]
  ENV["ES_PATH"] ||= File.join(ENV["HOME"], Searchkick.opensearch? ? "opensearch" : "elasticsearch", Searchkick.server_version)
end

$logger = ActiveSupport::Logger.new(ENV["VERBOSE"] ? STDOUT : nil)

if ENV["LOG_TRANSPORT"]
  transport_logger = ActiveSupport::Logger.new(STDOUT)
  if Searchkick.client.transport.respond_to?(:transport)
    Searchkick.client.transport.transport.logger = transport_logger
  else
    Searchkick.client.transport.logger = transport_logger
  end
end
Searchkick.search_timeout = 5
Searchkick.index_suffix = ENV["TEST_ENV_NUMBER"] # for parallel tests

puts "Running against #{Searchkick.opensearch? ? "OpenSearch" : "Elasticsearch"} #{Searchkick.server_version}"

Searchkick.redis =
  if defined?(ConnectionPool)
    ConnectionPool.new { Redis.new(logger: $logger) }
  else
    Redis.new(logger: $logger)
  end

I18n.config.enforce_available_locales = true

ActiveJob::Base.logger = $logger
ActiveJob::Base.queue_adapter = :inline

ActiveSupport::LogSubscriber.logger = ActiveSupport::Logger.new(STDOUT) if ENV["NOTIFICATIONS"]

if defined?(Mongoid)
  require_relative "support/mongoid"
else
  require_relative "support/activerecord"
end

def mongoid?
  defined?(Mongoid)
end

# models
Dir["#{__dir__}/models/*"].each do |file|
  require file
end

Product.searchkick_index.delete if Product.searchkick_index.exists?
Product.reindex
Product.reindex # run twice for both index paths
Product.create!(name: "Set mapping")

Store.reindex
Animal.reindex
Speaker.reindex
Region.reindex

class Minitest::Test
  def setup
    Product.destroy_all
    Store.destroy_all
    Animal.destroy_all
    Speaker.destroy_all
  end

  protected

  def store(documents, klass = default_model, reindex: true)
    if reindex
      documents.shuffle.each do |document|
        klass.create!(document)
      end
      klass.searchkick_index.refresh
    else
      Searchkick.callbacks(false) do
        documents.shuffle.each do |document|
          klass.create!(document)
        end
      end
    end
  end

  def store_names(names, klass = default_model, reindex: true)
    store names.map { |name| {name: name} }, klass, reindex: reindex
  end

  # no order
  def assert_search(term, expected, options = {}, klass = default_model)
    assert_equal expected.sort, klass.search(term, **options).map(&:name).sort
  end

  def assert_order(term, expected, options = {}, klass = default_model)
    assert_equal expected, klass.search(term, **options).map(&:name)
  end

  def assert_equal_scores(term, options = {}, klass = default_model)
    assert_equal 1, klass.search(term, **options).hits.map { |a| a["_score"] }.uniq.size
  end

  def assert_first(term, expected, options = {}, klass = default_model)
    assert_equal expected, klass.search(term, **options).map(&:name).first
  end

  def assert_misspellings(term, expected, misspellings = {}, klass = default_model)
    options = {
      fields: [:name, :color],
      misspellings: misspellings
    }
    assert_search(term, expected, options, klass)
  end

  def assert_warns(message)
    _, stderr = capture_io do
      yield
    end
    assert_match "[searchkick] WARNING: #{message}", stderr
  end

  def with_options(options, klass = default_model)
    previous_options = klass.searchkick_options.dup
    begin
      klass.searchkick_options.merge!(options)
      klass.reindex
      yield
    ensure
      klass.searchkick_options.clear
      klass.searchkick_options.merge!(previous_options)
    end
  end

  def activerecord?
    defined?(ActiveRecord)
  end

  def default_model
    Product
  end

  def ci?
    ENV["CI"]
  end
end

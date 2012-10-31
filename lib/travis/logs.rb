require 'multi_json'

require 'travis'
require 'travis/support'
require 'timeout'
require 'sidekiq'

$stdout.sync = true

module Travis
  class Logs
    autoload :Handler, 'travis/logs/handler'

    extend Exceptions::Handling
    include Logging

    class << self
      def start
        setup
        new.subscribe
      end

      protected

        def setup
          Travis::Features.start
          Travis::Async.enabled = true
          Travis::Database.connect
          Travis::Exceptions::Reporter.start
          Travis::Notification.setup

          Travis::Amqp.config = Travis.config.amqp
          Travis::Async::Sidekiq.setup(Travis.config.redis.url, Travis.config.sidekiq)

          Travis::LogSubscriber::ActiveRecordMetrics.attach

          Travis::Memory.new(:logs).report_periodically if Travis.env == 'production'

          threads
          NewRelic.start if File.exists?('config/newrelic.yml')
        end
    end

    def self.threads
      require 'java'
      java_import 'java.lang.Thread'
      run_periodically(60) do
        Travis.logger.info("Thread count: #{java.lang.Thread.activeCount}")
      end
    end

    def subscribe
      info 'Subscribing to amqp ...'
      info "Subscribing to reporting.jobs.logs"

      Travis::Amqp::Consumer.jobs('logs').subscribe(:ack => true) do |msg, payload|
        receive(:route, msg, payload)
      end

      0.upto(Travis.config.logs.shards - 1).each do |shard|
        info "Subscribing to reporting.jobs.logs.#{shard}"
        Travis::Amqp::Consumer.jobs("logs.#{shard}").subscribe(:ack => true) do |msg, payload|
          receive(:log, msg, payload)
        end
      end
    end

    def receive(type, message, payload)
      return unless payload = decode(payload)
      Travis.uuid = payload['uuid']
      handle(type, payload)
    rescue Exception => e
      puts "!!!FAILSAFE!!! #{e.message}", e.backtrace
    ensure
      message.ack
    end

    protected

      def handle(type, payload)
        timeout do
          Travis::Logs::Handler.handle(type, payload)
        end
      end
      rescues :handle, :from => Exception unless Travis.env == 'test'

      def timeout(&block)
        Timeout::timeout(60, &block)
      end

      def decode(payload)
        MultiJson.decode(payload)
      rescue StandardError => e
        error "[#{Thread.current.object_id}] [decode error] payload could not be decoded with engine #{MultiJson.engine.to_s} (#{e.message}): #{payload.inspect}"
        nil
      end
  end
end

require 'logger'
require 'json'
require "shared_intent/version"

module SharedIntent
  def self.included(klass)
    klass.extend ClassMethods
  end

  module ClassMethods
    attr_accessor :routes

    def run!
      new.run
    end

    # Because I don't want to try and put messages on the queue until the class is
    # instantiated.
    def register_route(intents:, data_types:)
      @routes ||= []
      routes << { intents: intents, data_types: data_types }
    end

    def exchange_name
      "#{self.name}Exchange"
    end

    def queue_name
      "#{self.name}Queue"
    end
  end

  def run
    subscribe_to_queue do |delivery_info, metadata, payload|
      response = _handle_message(delivery_info, metadata, payload)
      publish response
    end
    subscribe_to_queue(&:_handle_message)
    register_routes

    loop do
      Thread.pass; sleep 1
    end
  rescue Interrupt
    puts "\nExiting"
    exit
  end

  def kill
    connection.close if @_connection
  end


  def _handle_message(delivery_info, metadata, payload)
    logger.info from_queue: payload
    fail "You must define handle_message" unless respond_to? :handle_message
    message = JSON.parse(payload) || {}
    response = handle_message(delivery_info, metadata, message)
    response = ensure_routing_maintained message, response
    logger.info to_queue: response
    response
  end

  def ensure_routing_maintained(message, response)
    assert_valid_response response
    response.merge("routing" => message.fetch("routing"))
  end

  def assert_valid_response(response)
    if response.nil?
      logger.error "No response provided"
      fail "No response provided"
    end
    response.keys.each do |key|
      response[key.to_s] = response.delete(key)
    end
    intent_keys = %w(intents data_types data)
    if not response.respond_to? :key?
      fail "Response must be a routable intent hash with: #{intent_keys}"
    end
    unless (response.keys & intent_keys).length == intent_keys.length
      fail "Response must be a routable intent hash. Missing: #{intent_keys - response.keys}"
    end
  end

  def subscribe_to_queue(&block)
    queue.subscribe do |delivery_info, metadata, payload|
      block.call(delivery_info, metadata, payload)
    end
  end

  def publish(payload)
    if payload.nil?
      logger.debug("Not publishing nil payload")
      return
    end
    string = JSON.dump(payload)
    router_exchange.publish(string)
  end

  def register_routes
    self.class.routes.each do |route|
      router_exchange.publish(JSON.dump(route.merge(exchange: self.class.exchange_name)), routing_key: "add_route")
    end
  end

  def connection
    return @_connection if @_connection
    @_connection = Bunny.new({
      host:      ENV['RABBIT_HOSTNAME'],
      port:      ENV['RABBIT_PORT'],
      ssl:       false,
      vhost:     '/',
      user:      'guest',
      pass:      'guest',
      heartbeat: :server, # will use RabbitMQ setting
      frame_max: 131072,
      auth_mechanism: 'PLAIN'
    })

    begin
      last_exception = nil
      Timeout::timeout(20) do
        begin
          @_connection.start
        rescue StandardError => e
          logger.error "RabbitMQ connection failed. Retrying."
          last_exception = e
          sleep 0.5
          retry
        end
      end
    rescue Timeout::Error => timeout
      raise(last_exception || timeout)
    end

    @_connection
  end

  def channel
    @_channel ||= connection.create_channel
  end

  def router_exchange
    @_router_exchange ||= channel.topic("router_exchange", auto_delete: false, durable: true)
  end

  def queue
    return @_queue if @_queue
    exchange = channel.topic(self.class.exchange_name, auto_delete: false, durable: true)
    @_queue = channel.queue(self.class.queue_name, auto_delete: true)
    logger.info queue: self.class.queue_name
    @_queue.bind(exchange)
    @_queue
  end

  def logger
    @logger ||= ::Logger.new(STDOUT)
  end
end

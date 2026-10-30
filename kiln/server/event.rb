require 'kiln/server/event/native'
require 'kiln/server/event/state'
require 'kiln/server/event/configuration'
require 'kiln/server/event/setup'
require 'kiln/server/event/lifecycle'
require 'kiln/server/event/pump'
require 'kiln/server/event/workers'
require 'kiln/server/event/intake'
require 'kiln/server/event/delivery'
require 'kiln/server/event/streams'
require 'kiln/server/event/outlet'

module Kiln
  class Server
    class Event
      include Setup
      include Lifecycle
      include Stopping
      include Pumping
      include Waking
      include Workers
      include Intake
      include Refusals
      include Requests
      include Delivery
      include Stalling
      include Outgoing
      include Streams

      attr_reader :port, :killed, :ports

      def initialize(handler, **options)
        config = Settings.event(options)
        init_wiring(config, handler)
        init_limits(config)
        init_settings(config)
        init_streams
        init_workers(config.handlers)
        init_wake
        init_flags
        init_counters
      end

      def sequence(index, count)
        @seq_stride = count
        @seq = index + 1 - count
        self
      end

      def stream_ready(outlet)
        @ready << outlet
        nudge_pump
      end

      def inlet_wanted(inlet)
        @wants << inlet
        nudge_pump
      end

      def draining? = @draining
      def loops = 1

      def connections = @wake_lock.synchronize { @uv.nil? ? 0 : @uv.kiln_uv_open }
      def in_flight = @inflight
      def late = 0
      def free_slots = @max_conns - connections
      def handling = @inflight
      def handshakes = @wake_lock.synchronize { @uv.nil? ? 0 : @uv.kiln_uv_handshakes }
    end

    private_constant :Event, :Outlet
  end
end

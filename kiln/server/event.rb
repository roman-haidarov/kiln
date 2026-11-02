require 'kiln/server/event/native'
require 'kiln/server/event/budget'
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

      def share(group, balance)
        @group = group
        @balance = balance
        self
      end

      def stats
        out = Array.new(STATS, 0)
        @wake_lock.synchronize { @uv&.kiln_uv_stats(out, STATS) }
        out
      end

      def loop_stats = [stats]

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
      def admission_count = @wake_lock.synchronize { @uv&.kiln_uv_admitted }
      def admitted = admission_count || 0
      def in_flight = @inflight
      def late = 0
      def free_slots = [@max_conns - admitted, 0].max
      def handling = @inflight
      def pending_requests_count = @wake_lock.synchronize { @dispatch_budget.requests }
      def pending_bytes_count = @wake_lock.synchronize { @dispatch_budget.bytes }
      def queued_requests = pending_requests_count || 0
      def queued_bytes = pending_bytes_count || 0
      def handshakes = @wake_lock.synchronize { @uv.nil? ? 0 : @uv.kiln_uv_handshakes }
    end

    private_constant :Event, :Outlet
  end
end

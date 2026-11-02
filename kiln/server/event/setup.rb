module Kiln
  class Server
    class Event
      private

      def init_wiring(config, handler)
        @handler = handler
        @log = config.log
        @listen = config.listen.map(&:copy)
        @group = 0
        @balance = 0
        @port = config.port
        @ports = []
        @owned_paths = []
        @reuse_port = config.reuse_port?
        @request_timeout = config.request_timeout
        @backlog = config.backlog
      end

      def init_limits(config)
        @max_conns = config.max_conns
        @max_streams = config.max_streams
        @max_body = config.max_body
        @buffer_body = config.buffer_body
        @read_timeout = config.read_timeout
        @write_timeout = config.write_timeout
        @keep_alive = config.keep_alive_timeout.positive?
        @handlers = config.handlers
        @max_pending_requests = config.max_pending_requests
        @max_pending_bytes = config.max_pending_bytes
      end

      def init_settings(config)
        @settings = EventConfiguration.pack(config)
      end

      def init_streams
        @stream_count = 0
        @outlets = {}
        @streams = {}
        @inlets = {}
        @thirsty = {}
        @wants = Queue.new
        @take_state = [0]
        @backlogged = {}
        @ready = Queue.new
        @liveness_at = 0.0
        @uploads = {}
        @done = Queue.new
      end

      def init_workers(count)
        @dispatch_budget = DispatchBudget.new(@max_pending_requests, @max_pending_bytes)
        @jobs = Queue.new
        @busy = {}
        @stalled = {}
        @held = {}
        @workers = []
        @worker_lock = Mutex.new
        @retired = [Thread.current].drop(1)
        @active = Array.new(count)
        @active_locks = Array.new(count) { Mutex.new }
      end

      def init_wake
        @wake_lock = Mutex.new
        @parked = false
        @wake_at = 0.0
        @inline_busy = false
        @pump_stopping = false
        @uv_closed = false
      end

      def init_flags
        @cutoff = false
        @dispatch_ready = false
        @draining = false
        @quiet = false
        @stop = false
        @stopped = false
        @pump = nil
      end

      def init_counters
        @seq = 0
        @seq_stride = 1
        @inflight = 0
        @aborted_count = 0
        @aborted_taken = 0
        @killed = 0
      end

    end
  end
end

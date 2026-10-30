def kiln_mode_server(mode, router, log, port, lane_count: Kiln::Runtime.concurrency, shard_count: Kiln::Runtime.workers)
  case mode
  when 'server'
    Kiln::Server.new(Kiln::Middleware::Rescue.new(router, log), log: log, host: '127.0.0.1', port: port,
                                                                           backend: :base, shards: shard_count)
  when 'lanes', 'lanes_half'
    Kiln::Server.new(router, log: log, host: '127.0.0.1', port: port, handlers: lane_count)
  else
    Kiln::Server.new(router, log: log, host: '127.0.0.1', port: port, handlers: 0)
  end
end

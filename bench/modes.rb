def kiln_mode_server(mode, router, log, port, lane_count: 4, shard_count: 1)
  case mode
  when 'server'
    Kiln::Server::Base.new(Kiln::Middleware::Rescue.new(router, log), nil, log: log, host: '127.0.0.1', port: port,
                                                                           shards: shard_count)
  when 'lanes'
    Kiln::Server::Event.new(router, nil, log: log, host: '127.0.0.1', port: port, handlers: 4)
  when 'lanes_half'
    Kiln::Server::Event.new(router, nil, log: log, host: '127.0.0.1', port: port, handlers: lane_count)
  else
    Kiln::Server::Event.new(router, nil, log: log, host: '127.0.0.1', port: port)
  end
end

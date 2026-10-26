require 'kiln'
require 'bench/cache_stores'

capacity = Integer(ENV.fetch('CAPACITY') { '50000' })
value_bytes = Integer(ENV.fetch('VALUE') { '1024' })
store_name = ENV.fetch('STORE') { 'native' }
copy_values = store_name == 'native' || ENV.fetch('COPY') { '0' } == '1'
requested_shards = Integer(ENV.fetch('SHARDS') { '16' })
raise ArgumentError, 'STORE must be native or hash' unless %w[native hash].include?(store_name)
unless capacity.positive? && value_bytes >= 0
  raise ArgumentError,
        'CAPACITY must be positive and VALUE must be non-negative'
end

shards = Kiln::Cache::Limits.shards(requested_shards, capacity, capacity * (value_bytes + 192) * 2)
pages = if store_name == 'hash'
          CacheHashStore.new(capacity, shards, copy: copy_values)
        else
          CacheNativeStore.new(capacity, value_bytes, shards)
        end
filler = 'x' * value_bytes
router = Kiln::Routing::Router.new
router.get('/c/:key', lambda { |ctx|
  key = ctx.req.params['key']
  body = pages.get(key)
  unless body
    body = "#{key}:#{filler}"
    pages.put(key, body)
  end
  ctx.res.text(body)
})
router.seal!
log = Kiln::Observability::Log.new($stderr)
options = { log: log, backend: ENV.fetch('BACKEND') { 'event' }.to_sym, host: '127.0.0.1',
            port: Integer(ENV.fetch('PORT') { '18200' }) }
handlers = Integer(ENV.fetch('HANDLERS') { '0' })
options[:handlers] = handlers if handlers.positive?
server = Kiln::Server.new(router, **options)
warn "cache store=#{store_name} copy=#{copy_values} shards=#{shards} capacity=#{capacity} value=#{value_bytes}"
server.start
loop { Kiln::Runtime.pause(3600) }

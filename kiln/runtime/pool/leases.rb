module Kiln
  module Runtime
    module PoolLeases
      Lease = Struct.new(:resource, :held, :thread)

      def acquire(timeout: 1.0)
        held = new_hold(timeout)
        checkout(held)
        resource = held.entry.resource
        @lock.synchronize { @leases << Lease.new(resource, held, Thread.current) }
        resource
      end

      def release(resource, error = nil)
        held = take_lease(resource).held
        held.keep = keep_entry?(held.entry, error)
        settle_checkout(held)
        flush_shutdown if @state != :open
        nil
      end

      private

      def take_lease(resource)
        @lock.synchronize do
          index = lease_index(resource)
          raise ArgumentError, 'resource was not acquired' if index.nil?

          owner = @leases[index].thread
          raise ThreadError, 'connection released from another thread' unless owner.equal?(Thread.current)

          @leases.delete_at(index)
        end
      end

      def lease_index(resource)
        index = 0
        while index < @leases.size
          return index if @leases[index].resource.equal?(resource)

          index += 1
        end
        nil
      end
    end

  end
end

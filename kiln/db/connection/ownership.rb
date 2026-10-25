module Kiln
  module DB
    class Conn
      module Ownership
        def claim!
          @owner_lock.synchronize do
            if !@owner_thread.nil? && !@owner_thread.equal?(Thread.current)
              raise OwnershipError, 'connection is owned by another thread'
            end
            raise ConnectionError, 'connection closed' if @closed

            @owner_thread = Thread.current
            @owner_count += 1
          end
          self
        end

        def release_claim!
          @owner_lock.synchronize do
            unless @owner_thread.equal?(Thread.current) && @owner_count.positive?
              raise OwnershipError, 'connection released by a non-owner'
            end

            @owner_count -= 1
            @owner_thread = nil if @owner_count.zero?
          end
          nil
        end

        def assert_owner!
          @owner_lock.synchronize do
            if !@owner_thread.nil? && !@owner_thread.equal?(Thread.current)
              raise OwnershipError, 'connection owned by another thread'
            end
          end
          nil
        end
      end
    end
  end
end

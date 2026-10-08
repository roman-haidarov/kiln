module Kiln
  class Server
    class Base
      private

      def unhandle(slot)
        heap_remove(@handling[slot.shard], slot) if slot.hidx >= 0
      end

      def heap_push(slot)
        heap = @handling[slot.shard]
        slot.hidx = heap.size
        heap << slot
        heap_up(heap, slot.hidx)
      end

      def heap_remove(heap, slot)
        idx = slot.hidx
        last = heap.pop
        slot.hidx = -1
        return if last.equal?(slot)

        heap[idx] = last
        last.hidx = idx
        heap_up(heap, idx)
        heap_down(heap, last.hidx)
      end

      def heap_up(heap, idx)
        node = heap[idx]
        while idx.positive?
          parent = (idx - 1) / 2
          up = heap[parent]
          break if up.deadline <= node.deadline

          heap[idx] = up
          up.hidx = idx
          idx = parent
        end
        heap[idx] = node
        node.hidx = idx
      end

      def heap_down(heap, idx)
        node = heap[idx]
        size = heap.size
        loop do
          child = (2 * idx) + 1
          break if child >= size

          right = child + 1
          low = heap[child]
          mark = low.deadline
          if right < size
            other = heap[right]
            other_mark = other.deadline
            if other_mark < mark
              child = right
              low = other
              mark = other_mark
            end
          end
          break if node.deadline <= mark

          heap[idx] = low
          low.hidx = idx
          idx = child
        end
        heap[idx] = node
        node.hidx = idx
      end
    end
  end
end

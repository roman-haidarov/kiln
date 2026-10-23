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
          break if heap[parent].deadline <= node.deadline

          idx = heap_move(heap, parent, idx)
        end
        heap_place(heap, idx, node)
      end

      def heap_down(heap, idx)
        node = heap[idx]
        loop do
          child = lower_child(heap, idx)
          break if child.negative? || node.deadline <= heap[child].deadline

          idx = heap_move(heap, child, idx)
        end
        heap_place(heap, idx, node)
      end

      def lower_child(heap, idx)
        child = (2 * idx) + 1
        return -1 if child >= heap.size

        right = child + 1
        right < heap.size && heap[right].deadline < heap[child].deadline ? right : child
      end

      def heap_move(heap, from, to)
        heap_place(heap, to, heap[from])
        from
      end

      def heap_place(heap, idx, node)
        heap[idx] = node
        node.hidx = idx
      end
    end
  end
end

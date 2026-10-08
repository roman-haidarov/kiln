module Kiln
  class Server
    private

    def unhandle(slot)
      heap_remove(slot) if slot.hidx >= 0
    end

    def heap_push(slot)
      slot.hidx = @handling.size
      @handling << slot
      heap_up(slot.hidx)
    end

    def heap_remove(slot)
      idx = slot.hidx
      last = @handling.pop
      slot.hidx = -1
      return if last.equal?(slot)
      @handling[idx] = last
      last.hidx = idx
      heap_up(idx)
      heap_down(last.hidx)
    end

    def heap_up(idx)
      node = @handling[idx]
      while idx > 0
        parent = (idx - 1) / 2
        up = @handling[parent]
        break if up.deadline <= node.deadline
        @handling[idx] = up
        up.hidx = idx
        idx = parent
      end
      @handling[idx] = node
      node.hidx = idx
    end

    def heap_down(idx)
      node = @handling[idx]
      size = @handling.size
      loop do
        child = 2 * idx + 1
        break if child >= size
        right = child + 1
        child = right if right < size && @handling[right].deadline < @handling[child].deadline
        low = @handling[child]
        break if node.deadline <= low.deadline
        @handling[idx] = low
        low.hidx = idx
        idx = child
      end
      @handling[idx] = node
      node.hidx = idx
    end
  end
end

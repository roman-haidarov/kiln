module Kiln
  # Контекст запроса: как r.Context() в Go — дедлайн, id, зависимости,
  # плюс структурная конкурентность для подзадач.
  class Context
    attr_reader :req, :res, :app, :id, :deadline

    def initialize(req, res, app, id, deadline)
      @req, @res, @app, @id, @deadline = req, res, app, id, deadline
    end

    def remaining = @deadline - Kiln.now

    # Все подзадачи параллельно; ждём не дольше дедлайна запроса.
    # При выходе (успех, ошибка, дедлайн) — все подзадачи отменяются.
    def all(tasks)
      threads = tasks.map { |t| Thread.new { t.call } }
      threads.map do |th|
        left = remaining
        raise DeadlineExceeded, "deadline exceeded" if left <= 0 || th.join(left).nil?
        th.value
      end
    ensure
      threads&.each(&:kill)
    end

    # Первый успешный результат из нескольких; остальные отменяются.
    def first(tasks)
      inbox = Queue.new
      threads = tasks.map { |t| Thread.new { inbox << t.call } }
      left = remaining
      r = left > 0 ? inbox.pop(timeout: left) : nil
      raise DeadlineExceeded, "deadline exceeded" unless r
      r
    ensure
      threads&.each(&:kill)
    end
  end
end

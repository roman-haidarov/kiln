require 'kiln'
require 'stringio'
require 'thread'

class ClosingLog < Kiln::Observability::Log
  def initialize(io, paused, resume)
    @paused = paused
    @resume = resume
    super(io)
  end

  private

  def quiet_line
    line = super
    if line.nil? && !@queue.closed?
      @paused << true
      @resume.pop
    end
    line
  end
end

out = StringIO.new
paused = Queue.new
resume = Queue.new
log = ClosingLog.new(out, paused, resume)
log.info('first')
raise 'logger did not reach its timed wait' unless paused.pop(timeout: 2)

log.info('accepted before close')
closer = Thread.new { log.close }
deadline = Kiln::Runtime.now + 2
until log.instance_variable_get(:@queue).closed?
  raise 'logger close did not start' if Kiln::Runtime.now >= deadline

  Thread.pass
end
resume << true
raise 'logger close did not finish' unless closer.join(2)
raise 'logger lost an accepted line' unless out.string == "INFO  first\nINFO  accepted before close\n"
raise 'logger retained queued lines' unless log.instance_variable_get(:@queue).empty?

puts 'ok   logger close drains lines queued after a timed wait'

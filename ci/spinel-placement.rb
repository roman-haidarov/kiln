require 'ffi'

module PlacementProbe
  extend FFI::Library
  ffi_lib FFI::CURRENT_PROCESS
  attach_function :kiln_ci_worker_id, [], :long
end

def check_placement(nested, workers)
  seen = Queue.new
  release = Queue.new
  children = []
  spawn_children = lambda do
    64.times do
      children << Thread.new do
        worker = PlacementProbe.kiln_ci_worker_id
        seen << worker
        release.pop
        raise 'running thread migrated' if worker != PlacementProbe.kiln_ci_worker_id
      end
    end
  end
  nested ? Thread.new { spawn_children.call }.join : spawn_children.call
  counts = Array.new(workers, 0)
  64.times do
    worker = seen.pop
    raise "unexpected worker #{worker}" unless worker.positive? && worker < workers

    counts[worker] += 1
  end
  64.times { release << true }
  children.each(&:join)
  helpers = counts[1, workers - 1]
  raise "unbalanced placement #{counts.inspect}" if helpers.min.zero? || helpers.max - helpers.min > 4

  puts "placement application_workers=#{workers - 1} nested=#{nested} counts=#{counts.inspect} ok"
end

workers = ENV.key?('KILN_WORKERS') ? ENV.fetch('KILN_WORKERS').to_i + 1 : ENV.fetch('SPINEL_WORKERS').to_i
check_placement(false, workers)
check_placement(true, workers)

module WorkerBudget
  ffi_func :sp_sched_application_workers, [], :int
end

ENV['KILN_WORKERS'] = workers == 2 ? '2' : '1'
raise 'worker budget changed after startup' unless WorkerBudget.sp_sched_application_workers == workers - 1

puts 'application worker budget stays fixed after startup'

module Kiln
  module Runtime
    module Parallelism
      ffi_lib 'pthread'
      ffi_func :sp_sched_application_workers, [], :int
    end

    class << self
      def workers = Parallelism.sp_sched_application_workers
      def concurrency = workers * 16
    end
  end
end

module Kiln
  # Как супервизор в Erlang/OTP: фоновые сервисы перезапускаются при падении.
  class Supervisor
    def initialize(log)
      @log = log
      @children = []
      @stopping = false
    end

    def child(name, &body)
      @children << Thread.new do
        until @stopping
          begin
            body.call
            break                                  # штатный выход — не рестартуем
          rescue => e
            @log.error("service #{name} crashed: #{e.message}; restarting")
            sleep 0.1
          end
        end
      end
    end

    def stop
      @stopping = true
      @children.each(&:kill)
      @children.each(&:join)
    end
  end
end

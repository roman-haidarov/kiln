module Kiln
  module HTTP
    module Date
      MONTHS = { 'Jan' => 1, 'Feb' => 2, 'Mar' => 3, 'Apr' => 4, 'May' => 5, 'Jun' => 6,
                 'Jul' => 7, 'Aug' => 8, 'Sep' => 9, 'Oct' => 10, 'Nov' => 11, 'Dec' => 12 }.freeze
      IMF = /\A[A-Z][a-z]{2}, (\d{2}) ([A-Z][a-z]{2}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/
      RFC850 = /\A[A-Z][a-z]+, (\d{2})-([A-Z][a-z]{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT\z/
      ASCTIME = /\A[A-Z][a-z]{2} ([A-Z][a-z]{2}) ([ \d]\d) (\d{2}):(\d{2}):(\d{2}) (\d{4})\z/
      FORMATS = [[IMF, 3, 2, 1, 4], [RFC850, 3, 2, 1, 4], [ASCTIME, 6, 1, 2, 3]].freeze
      FORMAT = '%a, %d %b %Y %H:%M:%S GMT'.freeze

      class << self
        def value = current.dup

        def append(out) = out << current

        def parse(text)
          return nil if text.nil?

          value = text.strip
          FORMATS.each do |pattern, year, month, day, hour|
            found = pattern.match(value)
            next unless found

            full = found[year].to_i
            full = century(full) if pattern == RFC850
            return stamp(found, full, MONTHS[found[month]], found[day].strip.to_i, hour)
          end
          nil
        end

        private

        def current
          sec = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
          cached = @cached
          return cached[1] if cached && cached[0] == sec

          text = Time.now.utc.strftime(FORMAT).b
          @cached = [sec, text]
          text
        end

        def stamp(found, year, month, day, hour)
          return nil unless month

          clock = clock_of(found, hour)
          time = Time.utc(year, month, day, clock[0], clock[1], clock[2])
          same_moment?(time, month, day, clock) ? time.to_i : nil
        rescue ArgumentError
          nil
        end

        def clock_of(found, hour)
          [found[hour].to_i, found[hour + 1].to_i, found[hour + 2].to_i]
        end

        def same_moment?(time, month, day, clock)
          time.month == month && time.day == day && time.hour == clock[0] && time.sec == clock[2]
        end

        def century(two)
          year = 2000 + two
          year > Time.now.utc.year + 50 ? year - 100 : year
        end
      end
    end
  end
end

module CityWorkers
  # Relógio monotônico do Manager (substituível nos specs).
  class Clock
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def sleep(seconds) = Kernel.sleep(seconds)
  end
end

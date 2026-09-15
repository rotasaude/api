module CityWorkers
  # Processos reais do Manager: um fork por unidade. Cada filho vira líder do
  # próprio grupo de processo (Child.prepare), e o KILL vai para o grupo inteiro —
  # sem deixar workers e dispatcher do Solid Queue órfãos. O TERM vai só para o
  # supervisor, que encerra os próprios filhos com graça.
  class Spawner
    def spawn(unit)
      Process.fork do
        Process.setproctitle("rota-city-workers #{unit.key}")
        Child.run(unit)
      end
    end

    def terminate(pid)
      signal(:TERM, pid)
    end

    def kill(pid)
      signal(:KILL, -pid)
    end

    def reap
      exits = []
      loop do
        pid, status = Process.waitpid2(-1, Process::WNOHANG)
        break unless pid

        exits << [ pid, status ]
      end
      exits
    rescue Errno::ECHILD
      exits
    end

    private

    def signal(name, pid)
      Process.kill(name, pid)
    rescue Errno::ESRCH
      nil
    end
  end
end

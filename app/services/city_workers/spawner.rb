module CityWorkers
  # Processos reais do Manager: um fork por unidade. Cada filho vira líder do
  # próprio grupo de processo (Child.prepare), e o KILL vai para o grupo inteiro —
  # sem deixar workers e dispatcher do Solid Queue órfãos. O TERM vai só para o
  # supervisor, que encerra os próprios filhos com graça.
  class Spawner
    def spawn(unit)
      manager_pid = Process.pid

      pid = Process.fork do
        # TERM/INT herdados de bin/city_workers não podem sobreviver ao fork
        # (Important 1, fix round 1): até o Solid Queue instalar os próprios traps
        # em before_boot, um TERM chegado durante o boot só marcaria a flag `stop`
        # do PAI dentro do filho — sem efeito nenhum. DEFAULT garante que o sinal
        # derruba o processo se chegar antes do boot terminar; dali em diante o
        # Solid Queue assume o trap de verdade.
        Signal.trap("TERM", "DEFAULT")
        Signal.trap("INT", "DEFAULT")
        Process.setproctitle("rota-city-workers #{unit.key}")
        Child.run(unit, manager_pid: manager_pid)
      end

      # O filho já roda Process.setpgid(0, 0) (Child.prepare); o pai tenta de novo
      # aqui do lado dele (Minor 1, fix round 1) para cobrir a corrida em que um
      # KILL chega antes do filho ter rodado o próprio setpgid — sem isto, o KILL
      # ao grupo (-pid) pode ainda não alcançar um filho que só entrou no próprio
      # grupo depois. Os dois lados fazem a MESMA chamada; o segundo a rodar é
      # no-op. ESRCH (filho já saiu) e EACCES (corrida com o próprio setpgid do
      # filho) não são erro aqui.
      begin
        Process.setpgid(pid, pid)
      rescue Errno::EACCES, Errno::ESRCH
        nil
      end

      pid
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

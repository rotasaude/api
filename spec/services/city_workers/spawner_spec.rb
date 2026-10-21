require "rails_helper"

# O Spawner só fala com o sistema operacional (fork, sinais, waitpid). Aqui tudo
# isso é dublê: o bloco do fork roda no próprio processo do teste, com os traps,
# o título do processo e o Child.run trocados por stubs.
RSpec.describe CityWorkers::Spawner do
  subject(:spawner) { described_class.new }

  let(:unit) { CityWorkers::Unit.city("curitiba") }

  describe "#spawn" do
    before do
      allow(Process).to receive(:fork) do |&block|
        block.call
        4242
      end
      allow(Signal).to receive(:trap)
      allow(Process).to receive(:setproctitle)
      allow(Process).to receive(:setpgid)
      allow(CityWorkers::Child).to receive(:run)
    end

    it "resets the inherited TERM/INT traps, names the process and runs the child with the manager's pid" do
      spawner.spawn(unit)

      expect(Signal).to have_received(:trap).with("TERM", "DEFAULT")
      expect(Signal).to have_received(:trap).with("INT", "DEFAULT")
      expect(Process).to have_received(:setproctitle).with("rota-city-workers city:curitiba")
      expect(CityWorkers::Child).to have_received(:run).with(unit, manager_pid: Process.pid)
    end

    it "makes the child the leader of its own process group and returns its pid" do
      expect(spawner.spawn(unit)).to eq(4242)
      expect(Process).to have_received(:setpgid).with(4242, 4242)
    end

    it "tolerates the child having exited or already set its own group" do
      allow(Process).to receive(:setpgid).and_raise(Errno::ESRCH)
      expect(spawner.spawn(unit)).to eq(4242)

      allow(Process).to receive(:setpgid).and_raise(Errno::EACCES)
      expect(spawner.spawn(unit)).to eq(4242)
    end
  end

  describe "#terminate" do
    it "sends TERM only to the supervisor" do
      allow(Process).to receive(:kill)
      spawner.terminate(4242)
      expect(Process).to have_received(:kill).with(:TERM, 4242)
    end

    it "ignores a process that is already gone" do
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      expect(spawner.terminate(4242)).to be_nil
    end
  end

  describe "#kill" do
    it "sends KILL to the whole process group" do
      allow(Process).to receive(:kill)
      spawner.kill(4242)
      expect(Process).to have_received(:kill).with(:KILL, -4242)
    end

    it "ignores a group that is already gone" do
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      expect(spawner.kill(4242)).to be_nil
    end
  end

  describe "#reap" do
    let(:status) { instance_double(Process::Status) }

    it "collects every child that has exited, without blocking" do
      allow(Process).to receive(:waitpid2).with(-1, Process::WNOHANG)
        .and_return([ 101, status ], [ 102, status ], nil)

      expect(spawner.reap).to eq([ [ 101, status ], [ 102, status ] ])
    end

    it "returns nothing when there are no children" do
      allow(Process).to receive(:waitpid2).and_raise(Errno::ECHILD)
      expect(spawner.reap).to eq([])
    end

    it "keeps what it collected when the last child goes away mid-loop" do
      calls = 0
      allow(Process).to receive(:waitpid2) do
        calls += 1
        raise Errno::ECHILD if calls > 1

        [ 101, status ]
      end

      expect(spawner.reap).to eq([ [ 101, status ] ])
    end
  end
end
